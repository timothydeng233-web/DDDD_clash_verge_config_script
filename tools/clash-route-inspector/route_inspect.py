#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
route_inspect.py — 输入网址，判定它会命中哪条规则、走哪条链路、落到哪个节点

用法
    python route_inspect.py https://www.google.com
    python route_inspect.py www.baidu.com github.com
    python route_inspect.py                     # 交互输入，回车结束
    python route_inspect.py https://a.com --process curl.exe
    python route_inspect.py https://a.com --no-open

输出
    终端摘要 + 自包含 HTML 报告，报告默认用 Google Chrome 打开。
    报告写入 <项目>/LocalConfig/route-report-<时间戳>.html（该目录已被 .gitignore 排除）。

判定原则
    1. 唯一真值源是 clash-verge.yaml（真正下发给内核的最终配置），不读模板。
    2. 严格按规则顺序判定，首次命中即停，因此保留规则序号。
    3. 同时给出「在 Chrome 中打开」与「换一个不在进程名单里的浏览器」两种场景。
    4. IP-CIDR / GEOIP 需要真实 DNS 解析，未接入时明确标注为不确定，不猜。

只读，不修改、不重载任何配置。
"""

from __future__ import annotations

import argparse
import html
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clash_config as cc  # noqa: E402

bold = cc.bold
dim = cc.dim
red = cc.red
green = cc.green
yellow = cc.yellow
cyan = cc.cyan

DEFAULT_PROCESS = "chrome.exe"

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
]

KIND_LABEL = {
    "direct": "直连",
    "reject": "拦截",
    "node": "代理",
    "unknown": "不确定",
}


# ---------------------------------------------------------------- 判定

def analyze(cfg: cc.ConfigBundle, target: cc.Target, process: str | None) -> dict:
    """对网址做完整判定，具体逻辑见 clash_config.analyze_target。"""
    return cc.analyze_target(cfg, target, process)


# ---------------------------------------------------------------- 终端输出

def print_analysis(cfg: cc.ConfigBundle, res: dict, process: str | None) -> None:
    print()
    print(bold("─" * 78))
    print(bold(f"网址  {res['url']}"))
    print(
        f"      主机 {cyan(res['host'] or '?')}    "
        f"端口 {res['port'] if res['port'] else '未指定'}    "
        f"协议 {res['scheme'] or '未知'}"
        + (dim("    （IP 直连输入）") if res["is_ip"] else "")
    )
    if res["error"]:
        print("      " + red(res["error"]))
        return

    scoped, anyp = res["scoped"], res["any"]

    print()
    print(bold(f"场景 A：在 {process or '指定进程'} 中打开"))
    if scoped["first"]:
        f = scoped["first"]
        print(f"      命中  第 {f['index']} 条  {f['raw']}")
        print(f"      链路  {cc.describe_chain(scoped['outcome'], f['target'])}")
        print(f"      出口  {cc.describe_outcome(scoped['outcome'])}")
    else:
        print("      " + yellow("未命中任何规则（不应发生，配置缺少 MATCH 兜底）"))

    if scoped["blocker_count"]:
        print(
            "      "
            + yellow(
                f"注意：命中规则之前有 {scoped['blocker_count']} 条 IP/GEOIP 规则无法离线判定，"
                "结论可能与实测不符"
            )
        )

    print()
    print(bold("场景 B：换一个不在进程名单里的浏览器打开"))
    if anyp["first"]:
        f = anyp["first"]
        print(f"      命中  第 {f['index']} 条  {f['raw']}")
        print(f"      链路  {cc.describe_chain(anyp['outcome'], f['target'])}")
        print(f"      出口  {cc.describe_outcome(anyp['outcome'])}")
        if res["same_outcome"]:
            print(
                "      "
                + dim(
                    "（两场景最终出口相同：进程规则虽然抢跑了，但域名规则指向同一出口）"
                )
            )
    else:
        print("      " + yellow("未命中任何规则"))

    if anyp["blocker_count"]:
        print(
            "      "
            + yellow(
                f"注意：命中规则之前有 {anyp['blocker_count']} 条 IP/GEOIP 规则无法离线判定"
            )
        )

    if anyp["shadowed"]:
        print()
        print(bold("被跳过的规则（同样会命中，但排在更靠前的规则之后）"))
        for r in anyp["shadowed"][:6]:
            print(
                f"      第 {r['index']:>5} 条  {r['raw'][:56]:<58} "
                f"{cc.describe_outcome(r['outcome'])}"
            )
        if len(anyp["shadowed"]) > 6:
            print(dim(f"      另有 {len(anyp['shadowed']) - 6} 条，详见 HTML 报告"))

    if res.get("uncertain"):
        print()
        o = res.get("observed")
        if o:
            print(bold("实测结果（静态推演无法确定，以下为内核日志真实记录）"))
            print(
                f"      {o['ts']}  {o['proto']}  {o['process']}  "
                f"match {o['rule']}({o['arg']})  →  {o['group']}[{o['node']}]"
            )
        else:
            print(
                yellow(
                    "静态推演无法确定，且日志中无该域名记录；"
                    "建议先用浏览器访问一次再重新查询"
                )
            )
    elif res.get("agreement", {}).get("has_evidence"):
        a = res["agreement"]
        if a["any"] and a["scoped"]:
            msg = "静态推演与实测一致（两个场景都吻合）"
        elif a["any"]:
            msg = "静态推演与实测一致：日志显示实际走的是域名分流（场景 B）"
        elif a["scoped"]:
            msg = "静态推演与实测一致：日志显示实际走的是进程规则（场景 A）"
        else:
            msg = (
                "静态推演与实测不一致：实测与两个场景都不吻合，"
                "可能配置已变更或存在本工具未覆盖的规则类型，建议以实测为准"
            )
        o = res["observed"]
        print()
        print(bold("一致性校验"))
        print(f"      {msg}")
        print(
            f"      实测记录  {o['ts']}  {o['process']}  "
            f"{o['group']}[{o['node']}]  近期共 {o['count']} 条"
        )

    if res["evidence"] and res["evidence"].__len__() > 1:
        print()
        print(bold(f"近期日志记录（{len(res['evidence'])} 条，按时间倒序）"))
        for e in res["evidence"][:5]:
            print(
                f"      {e['ts']}  {e['proto']:<4} {(e['process'] or ''):<22} "
                f"{e['rule']}({e['arg']})  →  {e['group']}[{e['node']}]"
            )
        if len(res["evidence"]) > 5:
            print(dim(f"      另有 {len(res['evidence']) - 5} 条，详见 HTML 报告"))
    elif res["host"] and not res.get("uncertain"):
        print()
        print(dim("日志实证：该域名在近期内核日志中没有记录"))


# ---------------------------------------------------------------- HTML 报告

CSS = """
:root{--bg:#f7f7f5;--card:#fff;--line:#e3e2dd;--line2:#cfcec8;
--tx:#26262a;--tx2:#5f5e5a;--tx3:#8a8981;
--ok:#0f6e56;--okbg:#e1f5ee;--pr:#185fa5;--prbg:#e6f1fb;
--rj:#a32d2d;--rjbg:#fcebeb;--wn:#854f0b;--wnbg:#faeeda;
--gr:#5f5e5a;--grbg:#f1efe8;}
*{box-sizing:border-box}
body{margin:0;padding:32px 24px 64px;background:var(--bg);color:var(--tx);
font:14px/1.65 -apple-system,"Segoe UI","Microsoft YaHei",system-ui,sans-serif}
.wrap{max-width:1040px;margin:0 auto}
h1{font-size:22px;font-weight:500;margin:0 0 6px}
h2{font-size:16px;font-weight:500;margin:32px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
h3{font-size:14px;font-weight:500;margin:22px 0 10px;color:var(--tx2)}
.sub{color:var(--tx2);font-size:13px;margin:0}
.meta{color:var(--tx3);font-size:12px;margin-top:10px;line-height:1.9}
.meta b{font-weight:500;color:var(--tx2)}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0 4px}
.stat{flex:1 1 150px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.stat .n{font-size:20px;font-weight:500}
.stat .k{font-size:12px;color:var(--tx2);margin-top:2px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px 22px;margin:16px 0}
.url{font:500 16px/1.4 ui-monospace,Consolas,"Courier New",monospace;word-break:break-all}
.pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;
border:1px solid transparent;white-space:nowrap}
.p-ok{background:var(--okbg);color:var(--ok);border-color:var(--ok)}
.p-pr{background:var(--prbg);color:var(--pr);border-color:var(--pr)}
.p-rj{background:var(--rjbg);color:var(--rj);border-color:var(--rj)}
.p-wn{background:var(--wnbg);color:var(--wn);border-color:var(--wn)}
.p-gr{background:var(--grbg);color:var(--gr);border-color:var(--gr)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:500;color:var(--tx2);font-size:12px;background:var(--grbg)}
tr:last-child td{border-bottom:none}
code,.mono{font:12px/1.5 ui-monospace,Consolas,"Courier New",monospace}
.rule{color:var(--tx)}
.idx{color:var(--tx3);text-align:right;white-space:nowrap}
.steps{counter-reset:s;margin:4px 0 0;padding:0;list-style:none}
.steps li{counter-increment:s;position:relative;padding:9px 0 9px 40px;border-bottom:1px dashed var(--line)}
.steps li:last-child{border-bottom:none}
.steps li::before{content:counter(s);position:absolute;left:0;top:9px;width:24px;height:24px;
border-radius:50%;background:var(--grbg);border:1px solid var(--line2);color:var(--tx2);
font-size:12px;text-align:center;line-height:22px}
.steps .lbl{font-weight:500;margin-right:10px}
.two{display:flex;gap:14px;flex-wrap:wrap}
.two>div{flex:1 1 300px;border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.two .hd{font-weight:500;margin-bottom:8px;font-size:13px}
.warn{background:var(--wnbg);border:1px solid var(--wn);color:var(--wn);
border-radius:10px;padding:11px 14px;font-size:13px;margin:12px 0}
.note{color:var(--tx2);font-size:12.5px;margin:8px 0 0}
.ev{background:var(--grbg);border-radius:10px;padding:11px 14px;font-size:12.5px;
font:12px/1.7 ui-monospace,Consolas,monospace;word-break:break-all}
footer{margin-top:40px;padding-top:16px;border-top:1px solid var(--line);
color:var(--tx3);font-size:12px;line-height:1.9}
"""


def esc(x) -> str:
    return html.escape(str(x if x is not None else ""))


def pill(kind: str) -> str:
    cls = {"direct": "p-ok", "reject": "p-rj", "node": "p-pr"}.get(kind, "p-gr")
    return f'<span class="pill {cls}">{esc(KIND_LABEL.get(kind, "未知"))}</span>'


def outcome_html(outcome: dict) -> str:
    kind = outcome["kind"]
    src = cc.SOURCE_LABEL.get(
        "first" if "first" in outcome["sources"]
        else ("log" if "log" in outcome["sources"] else "profiles"),
        "",
    )
    if kind == "node":
        body = f'代理 <b>{esc(outcome["node"])}</b>'
    elif kind == "direct":
        body = "直连 DIRECT"
    elif kind == "reject":
        body = "拦截 REJECT"
    else:
        body = "无法确定"
    src_html = f'<span class="note">（{esc(src)}）</span>' if outcome["sources"] else ""
    return f'{pill(kind)} {body}{src_html}'


def chain_html(outcome: dict, target: str | None) -> str:
    parts = list(outcome["path"])
    if outcome["kind"] == "node":
        parts.append(outcome["node"])
    elif outcome["kind"] == "direct":
        parts.append("DIRECT")
    elif outcome["kind"] == "reject":
        parts.append("REJECT")
    if not parts:
        return esc(target)
    return " → ".join(f"<b>{esc(p)}</b>" for p in parts)


def render_url_card(cfg: cc.ConfigBundle, res: dict, process: str | None) -> str:
    scoped, anyp = res["scoped"], res["any"]
    out: list[str] = ['<div class="card">']
    out.append(f'<div class="url">{esc(res["url"])}</div>')

    if res["error"]:
        out.append(f'<div class="warn">{esc(res["error"])}</div></div>')
        return "".join(out)

    out.append(
        '<div class="meta">'
        f'主机 <b>{esc(res["host"])}</b> &nbsp;·&nbsp; 端口 <b>{esc(res["port"] or "未指定")}</b>'
        f' &nbsp;·&nbsp; 协议 <b>{esc(res["scheme"] or "未知")}</b>'
        + (" &nbsp;·&nbsp; <b>IP 直连输入</b>" if res["is_ip"] else "")
        + "</div>"
    )

    # 决策流水线
    first = scoped["first"]
    out.append("<h3>决策流水线</h3><ol class='steps'>")
    out.append(
        f'<li><span class="lbl">输入归一化</span>'
        f'<span class="mono">{esc(res["host"])}:{esc(res["port"] or "?")}</span></li>'
    )
    if first and first["type"].startswith("PROCESS-"):
        out.append(
            f'<li><span class="lbl">进程维度</span>入口进程 '
            f'<span class="mono">{esc(process)}</span> 命中第 '
            f'<b>{first["index"]}</b> 条，域名规则不参与判定</li>'
        )
    else:
        out.append(
            '<li><span class="lbl">进程维度</span>入口进程不在进程规则名单内，'
            "继续按域名 / 端口 / IP 规则判定</li>"
        )
    out.append(
        f'<li><span class="lbl">规则匹配</span>第 <b>{first["index"] if first else "?"}</b> 条 '
        f'<span class="mono">{esc(first["raw"] if first else "未命中")}</span></li>'
    )
    out.append(
        f'<li><span class="lbl">策略组展开</span>'
        f'{chain_html(scoped["outcome"], first["target"] if first else None)}</li>'
    )
    out.append(
        f'<li><span class="lbl">最终出口</span>{outcome_html(scoped["outcome"])}</li>'
    )
    out.append("</ol>")

    if scoped["blocker_count"]:
        out.append(
            f'<div class="warn">命中规则之前有 <b>{scoped["blocker_count"]}</b> 条 '
            "IP-CIDR / GEOIP 规则依赖真实 DNS 解析，本工具不做解析，"
            "因此结论可能与实测存在偏差。"
            "</div>"
        )

    # 两场景对比
    out.append("<h3>两种入口场景对比</h3><div class='two'>")
    for label, pack, who in (
        (f"场景 A：在 {process or '指定进程'} 中打开", scoped, process or "—"),
        ("场景 B：不在进程名单里的浏览器", anyp, "如 firefox.exe / catsxp.exe"),
    ):
        f = pack["first"]
        out.append("<div>")
        out.append(f'<div class="hd">{esc(label)}</div>')
        out.append(f'<div class="note">入口进程：<span class="mono">{esc(who)}</span></div>')
        if f:
            out.append(
                f'<div class="note">命中第 <b>{f["index"]}</b> 条'
                f'<br><span class="mono rule">{esc(f["raw"])}</span></div>'
            )
            out.append(f'<div class="note">链路：{chain_html(pack["outcome"], f["target"])}</div>')
        else:
            out.append('<div class="note">未命中任何规则</div>')
        out.append(f'<div style="margin-top:10px">{outcome_html(pack["outcome"])}</div>')
        out.append("</div>")
    out.append("</div>")

    # 被跳过的规则
    if anyp["shadowed"]:
        out.append("<h3>被跳过的规则</h3>")
        out.append(
            '<p class="note">以下规则同样会命中该网址，但优先级低于实际命中的规则，'
            "因此不生效。这就是「换个入口进程结果就变了」的原因。</p>"
        )
        out.append(
            "<table><thead><tr><th class='idx'>序号</th><th>规则</th><th>目标出口</th>"
            "</tr></thead><tbody>"
        )
        for r in anyp["shadowed"]:
            out.append(
                f'<tr><td class="idx">{r["index"]}</td>'
                f'<td class="mono">{esc(r["raw"])}</td>'
                f'<td>{outcome_html(r["outcome"])}</td></tr>'
            )
        out.append("</tbody></table>")

    # 静态推演不确定时，用日志实测校正
    if res.get("uncertain"):
        o = res.get("observed")
        if o:
            kind_cls = {"direct": "p-ok", "reject": "p-rj", "node": "p-pr"}.get(o["kind"], "p-gr")
            kind_txt = (
                "直连 DIRECT" if o["kind"] == "direct"
                else ("拦截 REJECT" if o["kind"] == "reject" else "代理 " + (o["node"] or ""))
            )
            out.append(
                '<div class="warn" style="background:var(--okbg);border-color:var(--ok);'
                'color:var(--ok)"><b>实测结果</b> · 该域名命中过需要真实解析的规则，'
                "静态推演无法确定；以下是内核日志里的真实记录，可作为权威答案。<br>"
                f'命中 <span class="mono">{esc(o["rule"])}({esc(o["arg"])})</span> → '
                f'{esc(o["group"])} <span class="pill {kind_cls}">{esc(kind_txt)}</span><br>'
                f'<span style="font-size:12px">{esc(o["ts"])} · {esc(o["proto"])} · '
                f'{esc(o["process"])} · 近期共 {o["count"]} 条记录</span></div>'
            )
        else:
            out.append(
                '<div class="warn"><b>静态推演无法确定</b>：命中规则之前有 IP-CIDR / GEOIP '
                "规则，需要真实 DNS 解析才能判定；该域名在近期内核日志中也没有记录，"
                "没有实测数据可以校正。如需确认，可以先用浏览器访问一次该网址，"
                "再回来重新生成报告。</div>"
            )
    elif res.get("agreement", {}).get("has_evidence"):
        a = res["agreement"]
        o = res["observed"]
        if a["any"] and a["scoped"]:
            msg, style = "静态推演与实测一致（两个场景都吻合）", (
                "background:var(--okbg);border-color:var(--ok);color:var(--ok)"
            )
        elif a["any"]:
            msg, style = "静态推演与实测一致：日志显示实际走的是域名分流（场景 B）", (
                "background:var(--okbg);border-color:var(--ok);color:var(--ok)"
            )
        elif a["scoped"]:
            msg, style = "静态推演与实测一致：日志显示实际走的是进程规则（场景 A）", (
                "background:var(--okbg);border-color:var(--ok);color:var(--ok)"
            )
        else:
            msg, style = (
                "静态推演与实测不一致：实测结果与两个场景都不吻合，"
                "可能配置已变更，或存在本工具未覆盖的规则类型，建议以实测为准",
                "",
            )
        out.append(
            f'<div class="warn" style="{style}"><b>一致性校验</b> · {esc(msg)}<br>'
            f'<span style="font-size:12px">实测记录：{esc(o["ts"])} · '
            f'{esc(o["process"])} · {esc(o["group"])}[{esc(o["node"])}] · '
            f'近期共 {o["count"]} 条</span></div>'
        )

    # 近期日志记录
    if len(res["evidence"]) > 1:
        out.append("<h3>近期日志记录</h3>")
        out.append(
            "<table><thead><tr><th>时间</th><th>协议</th><th>进程</th>"
            "<th>命中规则</th><th>出口</th></tr></thead><tbody>"
        )
        for e in res["evidence"]:
            out.append(
                f'<tr><td class="mono">{esc(e["ts"])}</td>'
                f'<td class="mono">{esc(e["proto"])}</td>'
                f'<td class="mono">{esc(e["process"])}</td>'
                f'<td class="mono">{esc(e["rule"])}({esc(e["arg"])})</td>'
                f'<td>{esc(e["group"])}<br>'
                f'<span class="note">[{esc(e["node"])}]</span></td></tr>'
            )
        out.append("</tbody></table>")
    elif res["host"] and not res.get("uncertain") and not res.get("agreement", {}).get(
        "has_evidence"
    ):
        out.append(
            '<h3>日志实证</h3><p class="note">该域名在近期内核日志中没有记录，'
            "无法与实测比对。</p>"
        )

    out.append("</div>")
    return "".join(out)


def render_report(cfg: cc.ConfigBundle, results: list[dict], process: str | None) -> str:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    counts = cc.rule_type_counts(cfg.rules)
    proc_rules = cc.process_rules(cfg.rules)

    parts: list[str] = []
    parts.append("<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>")
    parts.append("<meta name='viewport' content='width=device-width,initial-scale=1'>")
    parts.append("<title>网址路由判定报告</title>")
    parts.append(f"<style>{CSS}</style></head><body><div class='wrap'>")

    parts.append("<h1>网址路由判定报告</h1>")
    parts.append(
        "<p class='sub'>基于 Clash Verge 真正下发给内核的最终运行配置，"
        "按规则优先级逐条判定。</p>"
    )
    parts.append(
        "<div class='meta'>"
        f"生成时间 <b>{esc(now)}</b><br>"
        f"配置目录 <b>{esc(cfg.config_dir)}</b><br>"
        f"运行配置 <b>{esc(cfg.runtime_path.name)}</b>"
        f"（{cfg.runtime_path.stat().st_size:,} 字节）<br>"
        f"当前订阅 <b>{esc(cfg.profile_name or '未知')}</b>"
        f" <span class='mono'>{esc(cfg.profile_uid or '')}</span><br>"
        f"TUN 模式 <b>开启</b> · 模式 <b>rule</b> · 判定入口进程 "
        f"<b>{esc(process or '未指定')}</b>"
        "</div>"
    )

    parts.append("<div class='cards'>")
    for n, k in (
        (f"{len(cfg.rules):,}", "规则总数"),
        (str(len(cfg.groups)), "策略组"),
        (str(len(proc_rules)), "进程规则"),
        (str(len(results)), "判定网址"),
    ):
        parts.append(f'<div class="stat"><div class="n">{esc(n)}</div><div class="k">{esc(k)}</div></div>')
    parts.append("</div>")

    parts.append(
        "<div class='warn'>"
        "判定为静态推演：只读取配置与日志，不发起任何网络请求，也不修改任何配置。"
        "IP-CIDR / GEOIP 规则依赖真实 DNS 解析结果，未接入解析时会被标注为不确定。"
        "</div>"
    )

    parts.append("<h2>网址判定结果</h2>")
    for res in results:
        parts.append(render_url_card(cfg, res, process))

    # 附录：策略组出口
    parts.append("<h2>附录：策略组出口取值</h2>")
    parts.append(
        "<p class='note'>取值优先级：profiles.yaml 的 GUI 选中项 &gt; 内核日志实测 "
        "&gt; 组内第一项（推断）。标为推断的组从未出现在内核日志中。</p>"
    )
    parts.append(
        "<table><thead><tr><th>策略组</th><th>类型</th><th>取值来源</th>"
        "<th>取值</th><th>最终出口</th></tr></thead><tbody>"
    )
    for row in cc.group_outcome_table(cfg):
        src = {"profiles": "GUI 选中项", "log": "日志实测", "first": "推断（组内首项）"}[row["source"]]
        src_cls = "p-ok" if row["source"] == "profiles" else (
            "p-pr" if row["source"] == "log" else "p-wn"
        )
        parts.append(
            f'<tr><td><b>{esc(row["group"])}</b></td>'
            f'<td class="mono">{esc(row["type"] or "")}</td>'
            f'<td><span class="pill {src_cls}">{esc(src)}</span></td>'
            f'<td class="mono">{esc(row["value"])}</td>'
            f'<td>{outcome_html(row["outcome"])}</td></tr>'
        )
    parts.append("</tbody></table>")

    # 附录：进程规则
    parts.append("<h2>附录：进程规则</h2>")
    parts.append(
        "<p class='note'>这些规则排在所有域名规则之前。任何来自名单内进程的连接"
        "都会被直接截获，域名规则完全不参与判定。</p>"
    )
    parts.append(
        "<table><thead><tr><th class='idx'>序号</th><th>进程名</th>"
        "<th>目标策略组</th><th>最终出口</th></tr></thead><tbody>"
    )
    for r in proc_rules:
        parts.append(
            f'<tr><td class="idx">{r["index"]}</td>'
            f'<td class="mono">{esc(r["arg"])}</td>'
            f'<td>{esc(r["target"])}</td>'
            f'<td>{outcome_html(cfg.resolve(r["target"]))}</td></tr>'
        )
    parts.append("</tbody></table>")

    # 附录：规则类型分布
    parts.append("<h2>附录：规则类型分布</h2>")
    parts.append(
        "<table><thead><tr><th>规则类型</th><th class='idx'>条数</th>"
        "</tr></thead><tbody>"
    )
    for t, n in counts:
        parts.append(f'<tr><td class="mono">{esc(t)}</td><td class="idx">{n:,}</td></tr>')
    parts.append("</tbody></table>")

    parts.append(
        "<footer>"
        "本报告由 route_inspect.py 生成，仅做只读静态推演，不修改、不重载任何 Clash Verge 配置。"
        "节点与订阅信息属于隐私数据，报告默认写入已被 .gitignore 排除的 LocalConfig 目录，"
        "请勿提交到公开仓库。<br>"
        "判定依据：clash-verge.yaml（最终运行配置）、profiles.yaml（订阅与选中项）、"
        "logs/service/*.log（内核日志实证）。"
        "</footer>"
    )
    parts.append("</div></body></html>")
    return "".join(parts)


# ---------------------------------------------------------------- 打开报告


def open_in_chrome(path: Path) -> str:
    for cand in CHROME_CANDIDATES:
        if cand and Path(cand).is_file():
            try:
                subprocess.Popen([cand, path.as_uri()])
                return f"已用 Google Chrome 打开：{cand}"
            except OSError:
                continue
    try:
        os.startfile(str(path))  # type: ignore[attr-defined]
        return "未找到 Chrome，已用系统默认浏览器打开"
    except Exception as exc:  # noqa: BLE001
        return f"未能自动打开（{exc}），请手动打开：{path}"


# ---------------------------------------------------------------- 主流程


def main() -> int:
    cc.setup_stdout()
    parser = argparse.ArgumentParser(
        description="输入网址，判定命中的规则、链路与节点，并生成可视化报告",
    )
    parser.add_argument("urls", nargs="*", help="待判定的网址，可传多个")
    parser.add_argument("--process", default=DEFAULT_PROCESS,
                        help=f"判定用的入口进程名（默认 {DEFAULT_PROCESS}）")
    parser.add_argument("--config-dir", help="Clash Verge 配置目录")
    parser.add_argument("--out", help="报告输出目录，默认 <项目>/LocalConfig")
    parser.add_argument("--no-log", action="store_true", help="不读取内核日志")
    parser.add_argument("--no-open", action="store_true", help="不自动打开报告")
    args = parser.parse_args()

    cfg = cc.load_config(args.config_dir, use_log=not args.no_log)

    urls = list(args.urls)
    if not urls:
        print(bold("请输入要判定的网址，每行一个，直接回车结束："))
        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not line:
                break
            urls.append(line)
    if not urls:
        print(yellow("没有输入任何网址，已退出。"))
        return 1

    print()
    print(bold("网址路由判定（只读）"))
    print(f"  配置目录   {cfg.config_dir}")
    print(f"  运行配置   {cfg.runtime_path.name}  规则 {len(cfg.rules):,} 条  策略组 {len(cfg.groups)} 个")
    print(f"  当前订阅   {cfg.profile_name or '未知'}")
    print(f"  入口进程   {args.process}")

    results: list[dict] = []
    for raw in urls:
        target = cc.normalize_target(raw)
        if target.error or not target.host:
            print()
            print(bold(f"网址  {raw}"))
            print("      " + red(target.error or "无法解析"))
            continue
        res = analyze(cfg, target, args.process)
        results.append(res)
        print_analysis(cfg, res, args.process)

    if not results:
        print(yellow("没有任何可判定的网址。"))
        return 1

    # 报告输出目录
    if args.out:
        out_dir = Path(args.out)
    else:
        out_dir = Path(__file__).resolve().parents[2] / "LocalConfig"
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report = out_dir / f"route-report-{stamp}.html"
    report.write_text(render_report(cfg, results, args.process), encoding="utf-8")

    print()
    print(bold("报告已生成"))
    print(f"      {report}")
    if not args.no_open:
        print("      " + open_in_chrome(report))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
