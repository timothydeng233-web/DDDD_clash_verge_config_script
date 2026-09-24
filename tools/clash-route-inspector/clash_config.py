#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
clash_config.py — Clash Verge 配置的只读解析与规则判定共用模块

被以下脚本复用：
    check_browser_route.py   进程/浏览器走向体检
    route_inspect.py         网址路由判定与可视化报告

设计前提
    唯一真值源是 <配置目录>/clash-verge.yaml，也就是真正下发给 Mihomo 内核的
    最终运行配置。模板文件（ConfigBackup/Merge.yaml 等）可能与实际生效结果
    不一致，一律不作为判定依据。

    所有函数只读文件，不修改、不重载任何配置。
"""

from __future__ import annotations

import ipaddress
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- 常量

CONFIG_DIR_NAME = "io.github.clash-verge-rev.clash-verge-rev"
RUNTIME_FILE = "clash-verge.yaml"
PROFILES_FILE = "profiles.yaml"
GEOIP_DB_FILE = "Country.mmdb"

DIRECT = "DIRECT"
REJECT = "REJECT"

RULE_PREFIX = "- "

# 纯域名类规则：不需要真实 IP 即可判定
DOMAIN_TYPES = {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX"}

# 依赖真实 IP 才能判定的规则
IP_TYPES = {"IP-CIDR", "IP-CIDR6", "GEOIP", "IP-ASN"}

# 本模块暂不支持判定的规则类型
UNSUPPORTED_TYPES = {
    "GEOSITE", "RULE-SET", "SRC-IP-CIDR", "SRC-IP-CIDR6", "SRC-PORT",
    "SRC-GEOIP", "SRC-IP-ASN", "PROCESS-PATH", "AND", "OR", "NOT",
    "SUB-RULE", "NETWORK", "IP-SUFFIX", "SCRIPT",
}

HIT = "hit"
MISS = "miss"
UNKNOWN = "unknown"


# ---------------------------------------------------------------- 输出编码与着色


def setup_stdout() -> None:
    """Windows 控制台下的 UTF-8 输出与 ANSI 转义支持。"""
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def _enable_vt() -> bool:
    if os.name != "nt":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        return bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
    except Exception:
        return False


_COLOR_ENABLED = _enable_vt()


def paint(text: str, code: str) -> str:
    if not _COLOR_ENABLED:
        return text
    return f"\033[{code}m{text}\033[0m"


def bold(t: str) -> str:
    return paint(t, "1")


def dim(t: str) -> str:
    return paint(t, "2")


def red(t: str) -> str:
    return paint(t, "31")


def green(t: str) -> str:
    return paint(t, "32")


def yellow(t: str) -> str:
    return paint(t, "33")


def cyan(t: str) -> str:
    return paint(t, "36")


# ---------------------------------------------------------------- 文件读取


def locate_config_dir(explicit: str | None = None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    appdata = os.environ.get("APPDATA")
    if appdata:
        candidates.append(Path(appdata) / CONFIG_DIR_NAME)
    candidates.append(Path.home() / "AppData" / "Roaming" / CONFIG_DIR_NAME)
    for cand in candidates:
        if cand.is_dir():
            return cand
    raise SystemExit(red("找不到 Clash Verge 配置目录，请用 --config-dir 显式指定。"))


def read_text(path: Path) -> str:
    for enc in ("utf-8", "utf-8-sig", "gbk"):
        try:
            return path.read_text(encoding=enc)
        except UnicodeDecodeError:
            continue
        except OSError as exc:
            raise SystemExit(red(f"读取失败：{path}（{exc}）"))
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------- 解析


def parse_rules(text: str) -> list[dict]:
    """
    解析 clash-verge.yaml 的 rules 段。

    规则行形如 '- TYPE,ARG,GROUP[,FLAGS]'，MATCH 形如 '- MATCH,GROUP'。
    返回列表顺序即规则优先级，index 为 1 起的序号。
    """
    rules: list[dict] = []
    in_rules = False
    for line in text.splitlines():
        if not in_rules:
            if line.startswith("rules:"):
                in_rules = True
            continue
        if not line.startswith(RULE_PREFIX):
            continue
        parts = [p.strip() for p in line[len(RULE_PREFIX):].split(",")]
        rtype = parts[0]
        if rtype == "MATCH":
            arg, target, flags = None, (parts[1] if len(parts) > 1 else None), []
        else:
            arg = parts[1] if len(parts) > 1 else None
            target = parts[2] if len(parts) > 2 else None
            flags = parts[3:]
        rules.append(
            {
                "index": len(rules) + 1,
                "type": rtype,
                "arg": arg,
                "target": target,
                "flags": flags,
                "raw": line[len(RULE_PREFIX):],
            }
        )
    return rules


def parse_groups(text: str) -> dict[str, dict]:
    """解析 proxy-groups 段：名称 -> {type, proxies}。"""
    groups: dict[str, dict] = {}
    in_groups = False
    current: str | None = None
    for line in text.splitlines():
        if not in_groups:
            if line.startswith("proxy-groups:"):
                in_groups = True
            continue
        if line.startswith("rules:"):
            break
        if line.startswith("- name:"):
            current = line.split(":", 1)[1].strip()
            groups[current] = {"type": None, "proxies": []}
        elif current and line.startswith("  type:"):
            groups[current]["type"] = line.split(":", 1)[1].strip()
        elif current and line.startswith("  - "):
            groups[current]["proxies"].append(line[4:].strip())
    return groups


def _item_range(lines: list[str], uid: str) -> tuple[int, int]:
    """定位 profiles.yaml 中某个 uid 对应的条目行范围 [start, end)。"""
    start = None
    for i, line in enumerate(lines):
        if line.startswith("- uid:") and line.split(":", 1)[1].strip() == uid:
            start = i
            break
    if start is None:
        return (0, 0)
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("- uid:"):
            end = j
            break
    return (start, end)


def parse_selected(text: str, uid: str | None = None) -> dict[str, str]:
    """
    解析 profiles.yaml 中 selected 块：策略组名 -> 当前选中项。

    指定 uid 时只解析该订阅的条目，避免其他订阅的同名策略组污染结果。
    """
    lines = text.splitlines()
    scoped = lines
    if uid:
        start, end = _item_range(lines, uid)
        if end > start:
            scoped = lines[start:end]

    selected: dict[str, str] = {}
    for i, line in enumerate(scoped):
        if line.strip() != "selected:":
            continue
        j = i + 1
        while j < len(scoped):
            cur = scoped[j]
            if cur.strip() == "":
                j += 1
                continue
            if not (cur.startswith("  - ") or cur.startswith("    ")):
                break
            m = re.match(r"^\s*-\s*name:\s*(.+)$", cur)
            if m:
                group = m.group(1).strip()
                now = None
                if j + 1 < len(scoped):
                    m2 = re.match(r"^\s*now:\s*(.+)$", scoped[j + 1])
                    if m2:
                        now = m2.group(1).strip()
                if now:
                    selected[group] = now
            j += 1
    return selected


def parse_current_profile(text: str) -> tuple[str | None, str | None]:
    """返回 (当前订阅 uid, 当前订阅名)。"""
    uid = None
    for line in text.splitlines():
        m = re.match(r"^current:\s*(\S+)", line)
        if m:
            uid = m.group(1)
            break
    name = None
    if uid:
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.strip() == f"- uid: {uid}":
                for k in range(i, min(i + 8, len(lines))):
                    m = re.match(r"^\s+name:\s*(.+)$", lines[k])
                    if m:
                        name = m.group(1).strip()
                        break
                break
    return uid, name


# ---------------------------------------------------------------- 日志实证

LOG_TS = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
LOG_USE = re.compile(r"using (.+?)\[([^\]]+)\]")
LOG_MATCH = re.compile(r"match ([A-Za-z]+)\(([^)]*)\)")


def parse_logs(log_dir: Path, max_files: int = 12) -> dict[str, tuple[str, str]]:
    """
    扫描内核日志，收集每个策略组最近一次实际使用的出口。

    日志行形如：... using 🔰 选择节点[🇯🇵 日本Z03 | IEPL]
    返回 {策略组名: (时间戳, 出口)}，只保留时间最新的一次观测。
    """
    observed: dict[str, tuple[str, str]] = {}
    if not log_dir.is_dir():
        return observed
    try:
        files = sorted(
            log_dir.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True
        )[:max_files]
    except OSError:
        return observed

    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = LOG_USE.search(line)
            if not m:
                continue
            group = m.group(1).strip()
            node = m.group(2).strip()
            mt = LOG_TS.match(line)
            ts = mt.group(1) if mt else ""
            prev = observed.get(group)
            if prev is None or ts >= prev[0]:
                observed[group] = (ts, node)
    return observed


def parse_log_evidence(log_dir: Path, host: str, max_files: int = 12) -> list[dict]:
    """
    在日志中查找某个域名的真实命中记录，用于校验静态推演结果。

    返回按时间倒序的记录列表，每条包含 {ts, proto, process, host, port, rule, group, node}。
    """
    evidence: list[dict] = []
    if not log_dir.is_dir() or not host:
        return evidence
    try:
        files = sorted(
            log_dir.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True
        )[:max_files]
    except OSError:
        return evidence

    line_re = re.compile(
        r"^\[(?P<ts>[\d\- :.]+)\]"          # 时间戳含毫秒小数点
        r".*?"
        r"\[(?P<proto>TCP|UDP)\]\s+"
        r"(?P<src>\S+?)(?:\((?P<proc>[^)]*)\))?"   # 源地址，进程名可能缺失
        r"\s*-->\s*"
        r"(?P<host>[^:]+):(?P<port>\d+)\s+"
        r"match\s+(?P<rule>[A-Za-z]+)\((?P<arg>[^)]*)\)\s+"
        r"using\s+(?P<group>.+?)\[(?P<node>[^\]]+)\]"
    )
    host_l = host.lower()
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = line_re.search(line)
            if not m:
                continue
            if m.group("host").lower() != host_l:
                continue
            evidence.append(
                {
                    "ts": m.group("ts").strip(),
                    "proto": m.group("proto"),
                    "process": m.group("proc"),
                    "host": m.group("host"),
                    "port": m.group("port"),
                    "rule": m.group("rule"),
                    "arg": m.group("arg"),
                    "group": m.group("group").strip(),
                    "node": m.group("node").strip(),
                }
            )
    evidence.sort(key=lambda e: e["ts"], reverse=True)
    return evidence


# ---------------------------------------------------------------- 策略组展开


def resolve_chain(
    target: str | None,
    groups: dict[str, dict],
    selected: dict[str, str],
    observed: dict[str, tuple[str, str]] | None = None,
) -> dict:
    """
    把规则的目标展开成最终出口。

    取值优先级：profiles.yaml 的 selected（GUI 权威） > 日志实测 > 组内第一项（推断）。

    返回 {kind, path, node, sources}
      kind: direct | reject | node | unknown
      path: 经过的策略组链路
      node: 最终节点名（direct/reject 时为 None）
      sources: 取值来源集合，元素为 profiles / log / first
    """
    observed = observed or {}
    path: list[str] = []
    seen: set[str] = set()
    sources: set[str] = set()
    cur = target

    while True:
        if cur is None:
            return {"kind": "unknown", "path": path, "node": None, "sources": sources}
        if cur == DIRECT:
            return {"kind": "direct", "path": path, "node": None, "sources": sources}
        if cur == REJECT:
            return {"kind": "reject", "path": path, "node": None, "sources": sources}
        if cur in seen:
            return {"kind": "unknown", "path": path + [cur], "node": None, "sources": sources}
        seen.add(cur)

        group = groups.get(cur)
        if group is None:
            return {"kind": "node", "path": path, "node": cur, "sources": sources}

        path.append(cur)
        if cur in selected:
            nxt = selected[cur]
            sources.add("profiles")
        elif cur in observed:
            nxt = observed[cur][1]
            sources.add("log")
        else:
            proxies = group.get("proxies") or []
            if not proxies:
                sources.add("first")
                return {"kind": "unknown", "path": path, "node": None, "sources": sources}
            nxt = proxies[0]
            sources.add("first")
        cur = nxt


SOURCE_LABEL = {
    "profiles": "GUI 选中项",
    "log": "内核日志实测",
    "first": "组内首项（推断）",
}


def source_marker(sources: set[str]) -> str:
    if "first" in sources:
        return dim("（推断）")
    if "log" in sources:
        return dim("（日志实证）")
    return ""


def describe_outcome(outcome: dict) -> str:
    kind = outcome["kind"]
    tail = source_marker(outcome.get("sources") or set())
    if kind == "direct":
        return green("直连 DIRECT") + tail
    if kind == "reject":
        return red("拦截 REJECT") + tail
    if kind == "node":
        return cyan("代理 ") + outcome["node"] + tail
    return yellow("无法确定") + tail


def describe_chain(outcome: dict, target: str | None) -> str:
    if not outcome["path"]:
        return str(target)
    parts = list(outcome["path"])
    if outcome["kind"] == "node":
        parts.append(outcome["node"])
    elif outcome["kind"] == "direct":
        parts.append(DIRECT)
    elif outcome["kind"] == "reject":
        parts.append(REJECT)
    return " → ".join(parts)


# ---------------------------------------------------------------- 规则求值


@dataclass
class RequestContext:
    """一次连接请求的可判定信息。字段为 None 表示该维度未知。"""

    host: str | None = None
    port: int | None = None
    process: str | None = None
    dst_ip: str | None = None
    skip_process_rules: bool = False


def evaluate_rule(rule: dict, ctx: RequestContext) -> str:
    """判断单条规则对给定请求的结果：hit / miss / unknown。"""
    rtype = rule["type"]
    arg = rule["arg"] or ""

    if rtype == "MATCH":
        return HIT

    if rtype in ("PROCESS-NAME", "PROCESS-PATH"):
        if ctx.skip_process_rules:
            return MISS
        if ctx.process is None:
            return UNKNOWN
        if rtype == "PROCESS-NAME":
            return HIT if ctx.process.lower() == arg.lower() else MISS
        return UNKNOWN

    if rtype in DOMAIN_TYPES:
        if ctx.host is None:
            return MISS
        host = ctx.host.lower().rstrip(".")
        low = arg.lower()
        if rtype == "DOMAIN":
            return HIT if host == low else MISS
        if rtype == "DOMAIN-SUFFIX":
            return HIT if host == low or host.endswith("." + low) else MISS
        if rtype == "DOMAIN-KEYWORD":
            return HIT if low and low in host else MISS
        if rtype == "DOMAIN-REGEX":
            try:
                return HIT if re.search(arg, host) else MISS
            except re.error:
                return UNKNOWN

    if rtype in ("IP-CIDR", "IP-CIDR6"):
        no_resolve = any(f.lower() == "no-resolve" for f in (rule.get("flags") or []))
        if ctx.dst_ip is None:
            # 域名连接下：带 no-resolve 的 IP 规则不解析域名，因此不会生效；
            # 不带 no-resolve 的规则会触发真实解析，本工具不做解析，标为不确定。
            return MISS if no_resolve else UNKNOWN
        try:
            net = ipaddress.ip_network(arg, strict=False)
            addr = ipaddress.ip_address(ctx.dst_ip)
        except ValueError:
            return UNKNOWN
        if addr.version != net.version:
            return MISS
        return HIT if addr in net else MISS

    if rtype == "GEOIP":
        # GEOIP 需要真实 IP 归属库，未接入 mmdb 时一律标为不确定。
        return UNKNOWN

    if rtype == "DST-PORT":
        if ctx.port is None:
            return UNKNOWN
        try:
            return HIT if int(arg) == ctx.port else MISS
        except ValueError:
            return UNKNOWN

    if rtype in UNSUPPORTED_TYPES:
        return UNKNOWN

    return UNKNOWN


@dataclass
class WalkResult:
    """一次完整规则遍历的结果。"""

    hits: list[dict] = field(default_factory=list)
    unknowns: list[dict] = field(default_factory=list)

    @property
    def first_hit(self) -> dict | None:
        return self.hits[0] if self.hits else None

    @property
    def blockers(self) -> list[dict]:
        """排在实际命中规则之前、但无法判定的规则。存在即说明结论不确定。"""
        first = self.first_hit
        if first is None:
            return list(self.unknowns)
        return [r for r in self.unknowns if r["index"] < first["index"]]

    @property
    def shadowed(self) -> list[dict]:
        """同样会命中、但被更靠前的规则抢先的规则。"""
        return self.hits[1:]


def walk_rules(rules: list[dict], ctx: RequestContext) -> WalkResult:
    """按优先级完整遍历所有规则，收集命中项与不可判定项。"""
    result = WalkResult()
    for rule in rules:
        state = evaluate_rule(rule, ctx)
        if state == HIT:
            result.hits.append(rule)
        elif state == UNKNOWN:
            result.unknowns.append(rule)
    return result


# ---------------------------------------------------------------- 配置打包


@dataclass
class ConfigBundle:
    config_dir: Path
    runtime_path: Path
    rules: list[dict]
    groups: dict[str, dict]
    selected: dict[str, str]
    observed: dict[str, tuple[str, str]]
    profile_uid: str | None
    profile_name: str | None

    @property
    def log_dir(self) -> Path:
        return self.config_dir / "logs" / "service"

    def resolve(self, target: str | None) -> dict:
        return resolve_chain(target, self.groups, self.selected, self.observed)


def load_config(
    explicit_dir: str | None = None,
    use_log: bool = True,
) -> ConfigBundle:
    """加载并解析最终运行配置。"""
    config_dir = locate_config_dir(explicit_dir)
    runtime = config_dir / RUNTIME_FILE
    if not runtime.is_file():
        raise SystemExit(red(f"未找到最终运行配置：{runtime}"))

    runtime_text = read_text(runtime)
    rules = parse_rules(runtime_text)
    groups = parse_groups(runtime_text)

    profiles = config_dir / PROFILES_FILE
    if profiles.is_file():
        profiles_text = read_text(profiles)
        uid, pname = parse_current_profile(profiles_text)
        selected = parse_selected(profiles_text, uid)
    else:
        uid, pname, selected = None, None, {}

    observed = parse_logs(config_dir / "logs" / "service") if use_log else {}

    return ConfigBundle(
        config_dir=config_dir,
        runtime_path=runtime,
        rules=rules,
        groups=groups,
        selected=selected,
        observed=observed,
        profile_uid=uid,
        profile_name=pname,
    )


# ---------------------------------------------------------------- 网址归一化


DEFAULT_PORTS = {"http": 80, "https": 443, "ftp": 21, "ws": 80, "wss": 443}


@dataclass
class Target:
    raw: str
    host: str | None
    port: int | None
    scheme: str | None
    is_ip: bool = False
    error: str | None = None


def normalize_target(raw: str) -> Target:
    """把用户输入归一化成 host / port / scheme。"""
    text = (raw or "").strip().strip('"').strip("'")
    if not text:
        return Target(raw=raw, host=None, port=None, scheme=None, error="输入为空")

    scheme = None
    rest = text
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.\-]*)://(.*)$", text)
    if m:
        scheme = m.group(1).lower()
        rest = m.group(2)

    # 去掉路径、查询串、片段
    rest = re.split(r"[/?#]", rest, maxsplit=1)[0]
    # 去掉用户信息
    if "@" in rest:
        rest = rest.rsplit("@", 1)[1]
    rest = rest.strip()

    host = rest
    port = None
    if rest.startswith("["):  # IPv6 字面量
        m6 = re.match(r"^\[([^\]]+)\](?::(\d+))?$", rest)
        if m6:
            host = m6.group(1)
            if m6.group(2):
                port = int(m6.group(2))
    elif rest.count(":") == 1:
        h, _, p = rest.partition(":")
        if p.isdigit():
            host = h
            port = int(p)

    if not host:
        return Target(raw=raw, host=None, port=None, scheme=scheme, error="无法解析主机名")

    is_ip = False
    try:
        ipaddress.ip_address(host)
        is_ip = True
    except ValueError:
        pass

    if port is None:
        port = DEFAULT_PORTS.get(scheme or "", 443 if not is_ip else None)
    if scheme is None:
        scheme = "https" if port == 443 else ("http" if port == 80 else None)

    return Target(raw=raw, host=host, port=port, scheme=scheme, is_ip=is_ip)


# ---------------------------------------------------------------- 概览


def rule_type_counts(rules: list[dict]) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for r in rules:
        counts[r["type"]] = counts.get(r["type"], 0) + 1
    return sorted(counts.items(), key=lambda kv: -kv[1])


def group_outcome_table(cfg: ConfigBundle) -> list[dict]:
    """列出每个策略组的取值来源与最终出口。"""
    rows: list[dict] = []
    for name, group in cfg.groups.items():
        if name in cfg.selected:
            rows.append(
                {
                    "group": name,
                    "type": group.get("type"),
                    "source": "profiles",
                    "value": cfg.selected[name],
                    "ts": "",
                    "outcome": cfg.resolve(name),
                }
            )
        elif name in cfg.observed:
            ts, node = cfg.observed[name]
            rows.append(
                {
                    "group": name,
                    "type": group.get("type"),
                    "source": "log",
                    "value": node,
                    "ts": ts,
                    "outcome": cfg.resolve(name),
                }
            )
        else:
            proxies = group.get("proxies") or []
            rows.append(
                {
                    "group": name,
                    "type": group.get("type"),
                    "source": "first",
                    "value": proxies[0] if proxies else "（空组）",
                    "ts": "",
                    "outcome": cfg.resolve(name),
                }
            )
    return rows


def process_rules(rules: list[dict]) -> list[dict]:
    return [r for r in rules if r["type"] in ("PROCESS-NAME", "PROCESS-PATH")]


# ---------------------------------------------------------------- 标量读取


def parse_top_scalar(text: str, key: str) -> str | None:
    """读取顶层标量，如 mode: rule。"""
    m = re.search(rf"^{re.escape(key)}:\s*(.+)$", text, re.M)
    if not m:
        return None
    return m.group(1).strip().strip("'\"")


def parse_section_scalar(text: str, section: str, key: str) -> str | None:
    """读取某个块内的标量，如 tun 块里的 enable / stack / mtu。"""
    in_section = False
    for line in text.splitlines():
        if line.startswith(section + ":"):
            in_section = True
            continue
        if in_section:
            if line and not line[0].isspace():
                break
            m = re.match(rf"^\s+{re.escape(key)}:\s*(.+)$", line)
            if m:
                return m.group(1).strip().strip("'\"")
    return None


def runtime_meta(cfg: "ConfigBundle") -> dict:
    """汇总运行态元信息：模式、端口、TUN、DNS，以及 GUI 开关。"""
    text = read_text(cfg.runtime_path)
    verge_path = cfg.config_dir / "verge.yaml"
    vtext = read_text(verge_path) if verge_path.is_file() else ""
    return {
        "mode": parse_top_scalar(text, "mode"),
        "mixed_port": parse_top_scalar(text, "mixed-port"),
        "tun_enable": parse_section_scalar(text, "tun", "enable"),
        "tun_stack": parse_section_scalar(text, "tun", "stack"),
        "tun_mtu": parse_section_scalar(text, "tun", "mtu"),
        "dns_mode": parse_section_scalar(text, "dns", "enhanced-mode"),
        "fake_ip_range": parse_section_scalar(text, "dns", "fake-ip-range"),
        "gui_tun": parse_top_scalar(vtext, "enable_tun_mode"),
        "gui_sysproxy": parse_top_scalar(vtext, "enable_system_proxy"),
    }


# ---------------------------------------------------------------- 判定结果（JSON 安全）


def outcome_json(outcome: dict) -> dict:
    """把 resolve_chain 的结果转成可直接序列化的形式。"""
    return {
        "kind": outcome["kind"],
        "path": list(outcome["path"]),
        "node": outcome["node"],
        "sources": sorted(outcome.get("sources") or []),
    }


def _rule_brief(rule: dict | None) -> dict | None:
    if rule is None:
        return None
    return {
        "index": rule["index"],
        "type": rule["type"],
        "arg": rule["arg"],
        "target": rule["target"],
        "flags": list(rule.get("flags") or []),
        "raw": rule["raw"],
    }


def _pack_walk(cfg: "ConfigBundle", walk: WalkResult) -> dict:
    first = walk.first_hit
    shadowed = []
    for r in walk.shadowed:
        item = _rule_brief(r)
        item["outcome"] = outcome_json(cfg.resolve(r["target"]))
        shadowed.append(item)
    return {
        "first": _rule_brief(first),
        "outcome": outcome_json(cfg.resolve(first["target"])) if first else None,
        "chain": (
            describe_chain_plain(cfg.resolve(first["target"]), first["target"])
            if first
            else None
        ),
        "hit_count": len(walk.hits),
        "shadowed": shadowed,
        "blocker_count": len(walk.blockers),
        "blockers": [_rule_brief(r) for r in walk.blockers[:8]],
    }


def describe_chain_plain(outcome: dict, target: str | None) -> str:
    """不带颜色的链路描述，供 JSON / HTML 使用。"""
    if not outcome["path"]:
        return str(target)
    parts = list(outcome["path"])
    if outcome["kind"] == "node":
        parts.append(outcome["node"])
    elif outcome["kind"] == "direct":
        parts.append(DIRECT)
    elif outcome["kind"] == "reject":
        parts.append(REJECT)
    return " → ".join(parts)


def observed_verdict(evidence: list[dict]) -> dict | None:
    """
    从日志实证推导该域名的实际出口。

    用途：静态推演遇到 IP-CIDR / GEOIP 档位时无法判定（需要真实解析），
    此时若该域名近期被访问过，日志里的真实命中记录就是最可靠的答案。
    """
    if not evidence:
        return None
    e = evidence[0]
    node = (e.get("node") or "").strip()
    if node.upper() == "DIRECT":
        kind = "direct"
    elif node.upper() == "REJECT":
        kind = "reject"
    else:
        kind = "node"
    return {
        "kind": kind,
        "node": None if kind in ("direct", "reject") else node,
        "group": e.get("group"),
        "rule": e.get("rule"),
        "arg": e.get("arg"),
        "ts": e.get("ts"),
        "process": e.get("process"),
        "proto": e.get("proto"),
        "count": len(evidence),
    }


def _same_outcome(a: dict | None, b: dict | None) -> bool:
    if not a or not b:
        return False
    return a.get("kind") == b.get("kind") and a.get("node") == b.get("node")


def analyze_target(cfg: "ConfigBundle", target: Target, process: str | None) -> dict:
    """
    对一个网址做完整判定，返回 JSON 安全的数据结构。

    同时给出两种入口场景：
      scoped —— 入口进程为 process（默认 Chrome 这类在名单内的进程）
      any    —— 入口进程不在进程名单内，域名规则得以生效
    """
    host = None if target.is_ip else target.host

    ctx_scoped = RequestContext(host=host, port=target.port, process=process)
    ctx_any = RequestContext(host=host, port=target.port, process=None, skip_process_rules=True)
    if target.is_ip:
        ctx_scoped.dst_ip = target.host
        ctx_any.dst_ip = target.host

    scoped = _pack_walk(cfg, walk_rules(cfg.rules, ctx_scoped))
    anyp = _pack_walk(cfg, walk_rules(cfg.rules, ctx_any))

    same = bool(
        scoped["outcome"]
        and anyp["outcome"]
        and scoped["outcome"]["kind"] == anyp["outcome"]["kind"]
        and scoped["outcome"]["node"] == anyp["outcome"]["node"]
    )

    evidence = parse_log_evidence(cfg.log_dir, target.host or "")
    observed = observed_verdict(evidence)
    obs_cmp = (
        {"kind": observed["kind"], "node": observed["node"]} if observed else None
    )

    return {
        "url": target.raw,
        "error": target.error,
        "host": target.host,
        "port": target.port,
        "scheme": target.scheme,
        "is_ip": target.is_ip,
        "scoped": scoped,
        "any": anyp,
        "same_outcome": same,
        "evidence": evidence[:10],
        "observed": observed,
        "uncertain": bool(scoped["blocker_count"] or anyp["blocker_count"]),
        # 用日志实测反向校验静态推演：命中哪个场景，或两个都不符
        "agreement": {
            "scoped": _same_outcome(obs_cmp, scoped["outcome"]),
            "any": _same_outcome(obs_cmp, anyp["outcome"]),
            "has_evidence": bool(observed),
        },
    }


def overview(cfg: "ConfigBundle") -> dict:
    """供可视化界面使用的整体概览数据。"""
    proc = process_rules(cfg.rules)
    return {
        "config_dir": str(cfg.config_dir),
        "runtime_file": cfg.runtime_path.name,
        "runtime_size": cfg.runtime_path.stat().st_size,
        "profile_name": cfg.profile_name,
        "profile_uid": cfg.profile_uid,
        "rules_count": len(cfg.rules),
        "groups_count": len(cfg.groups),
        "process_rules_count": len(proc),
        "type_counts": [{"type": t, "count": n} for t, n in rule_type_counts(cfg.rules)],
        "meta": runtime_meta(cfg),
        "process_rules": [
            {
                "index": r["index"],
                "type": r["type"],
                "arg": r["arg"],
                "target": r["target"],
                "raw": r["raw"],
                "outcome": outcome_json(cfg.resolve(r["target"])),
            }
            for r in proc
        ],
        "groups": [
            {
                "group": row["group"],
                "type": row["type"],
                "source": row["source"],
                "value": row["value"],
                "ts": row["ts"],
                "outcome": outcome_json(row["outcome"]),
            }
            for row in group_outcome_table(cfg)
        ],
    }
