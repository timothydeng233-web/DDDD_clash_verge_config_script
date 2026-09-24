#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_browser_route.py — 只读校验某个进程/浏览器在 Clash Verge 里的实际走向

作用
    1. 列出最终运行配置里的全部 PROCESS-NAME 规则及其序号、目标策略组、当前出口。
    2. 校验指定进程名（或一批常见浏览器）是否会被进程规则接管。
    3. 对样本域名模拟「域名规则」匹配，给出命中规则序号、策略组链路与最终出口。

数据源（全部只读，不修改、不重载任何配置）
    <配置目录>/clash-verge.yaml   最终下发给内核的运行配置（唯一真值源）
    <配置目录>/profiles.yaml      当前订阅与各策略组的选中项
    <配置目录>/logs/service/*.log 内核日志，用于校正策略组出口

用法
    python check_browser_route.py
    python check_browser_route.py --process firefox.exe
    python check_browser_route.py --process firefox.exe --domain www.baidu.com
    python check_browser_route.py --list-domains

相关工具
    route_inspect.py   输入具体网址，生成可视化路由判定报告
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clash_config as cc  # noqa: E402

bold = cc.bold
dim = cc.dim
red = cc.red
green = cc.green
yellow = cc.yellow
cyan = cc.cyan

CANDIDATE_PROCESSES = [
    "chrome.exe",
    "msedge.exe",
    "msedgewebview2.exe",
    "firefox.exe",
    "brave.exe",
    "catsxp.exe",
    "360chrome.exe",
    "360se.exe",
    "QQBrowser.exe",
    "opera.exe",
    "vivaldi.exe",
    "slimjet.exe",
]

DEFAULT_SAMPLE_DOMAINS = [
    "www.baidu.com",
    "www.taobao.com",
    "www.bilibili.com",
    "www.gov.cn",
    "www.163.com",
    "www.google.com",
    "www.youtube.com",
    "github.com",
    "www.sciencedirect.com",
    "www.zhihu.com",
]


# ---------------------------------------------------------------- 报告


def report_summary(cfg: cc.ConfigBundle) -> None:
    counts = cc.rule_type_counts(cfg.rules)
    print()
    print(bold(f"规则概览（共 {len(cfg.rules):,} 条）"))
    print("  " + "  ".join(f"{t}:{n:,}" for t, n in counts[:10]))


def report_process_rules(cfg: cc.ConfigBundle) -> None:
    rules = cc.process_rules(cfg.rules)
    print()
    print(bold(f"进程规则（共 {len(rules)} 条，排在所有域名规则之前）"))
    print(dim("这些进程发出的连接会被直接截获，域名规则完全不参与判定。"))
    print()
    print(f"  {'序号':>5}  {'类型':<13} {'进程名':<24} {'目标策略组':<16} 最终出口")
    print(dim("  " + "-" * 92))
    for r in rules:
        outcome = cfg.resolve(r["target"])
        print(
            f"  {r['index']:>5}  {r['type']:<13} {(r['arg'] or ''):<24} "
            f"{(r['target'] or ''):<16} {cc.describe_outcome(outcome)}"
        )


def report_process_check(cfg: cc.ConfigBundle, names: list[str]) -> None:
    by_name = {(r["arg"] or "").lower(): r for r in cc.process_rules(cfg.rules)}
    print()
    print(bold("进程体检"))
    print()
    for name in names:
        rule = by_name.get(name.lower())
        if rule:
            outcome = cfg.resolve(rule["target"])
            print(
                f"  {name:<22} {red('会被接管')}  命中第 {rule['index']} 条 "
                f"→ {cc.describe_chain(outcome, rule['target'])}"
            )
        else:
            print(
                f"  {name:<22} {green('不在名单')}  会走域名规则"
                + dim("（注意：Script.js 若更新加入该进程名即失效）")
            )


def report_domain_simulation(cfg: cc.ConfigBundle, domains: list[str]) -> None:
    print()
    print(bold("域名规则推演"))
    print(dim("前提：入口进程不在进程规则名单内。IP / GEOIP 档位需真实解析，此处不做解析。"))
    print()
    print(f"  {'域名':<26} {'命中规则':<10} {'规则内容':<42} 最终出口")
    print(dim("  " + "-" * 108))
    for host in domains:
        ctx = cc.RequestContext(host=host, port=443, skip_process_rules=True)
        walk = cc.walk_rules(cfg.rules, ctx)
        first = walk.first_hit
        if first is None:
            print(f"  {host:<26} {'未命中':<10} {'—':<42} " + yellow("无法确定"))
            continue
        outcome = cfg.resolve(first["target"])
        raw = first["raw"]
        if len(raw) > 40:
            raw = raw[:39] + "…"
        tail = ""
        if walk.blockers:
            tail = dim(f"   ← 前有 {len(walk.blockers)} 条 IP/GEOIP 规则未判定")
        print(
            f"  {host:<26} {('第 ' + str(first['index']) + ' 条'):<10} {raw:<42} "
            f"{cc.describe_outcome(outcome)}{tail}"
        )


def report_group_table(cfg: cc.ConfigBundle) -> None:
    print()
    print(bold("策略组出口取值"))
    print(dim("  来源优先级：profiles.yaml 选中项 > 内核日志实测 > 组内第一项（推断）"))
    print()
    print(f"  {'策略组':<22} {'取值来源':<12} 出口")
    print(dim("  " + "-" * 74))
    for row in cc.group_outcome_table(cfg):
        src = {"profiles": "GUI 选中项", "log": "日志实测", "first": dim("推断")}[row["source"]]
        note = ""
        if row["source"] == "log":
            note = dim(f"  {row['ts']}")
        elif row["source"] == "first":
            note = dim("  从未出现在日志中")
        print(f"  {row['group']:<22} {src:<12} {row['value']}{note}")


# ---------------------------------------------------------------- 主流程


def main() -> int:
    cc.setup_stdout()
    parser = argparse.ArgumentParser(
        description="只读校验进程/浏览器在 Clash Verge 中的实际走向",
    )
    parser.add_argument("--config-dir", help="Clash Verge 配置目录")
    parser.add_argument("--process", action="append", default=[],
                        help="待校验的进程名，可重复传入")
    parser.add_argument("--domain", action="append", default=[],
                        help="待推演的域名，可重复传入")
    parser.add_argument("--list-domains", action="store_true",
                        help="只做域名推演，不输出进程体检")
    parser.add_argument("--no-log", action="store_true",
                        help="不读取内核日志，仅用 profiles.yaml 与组内首项")
    args = parser.parse_args()

    cfg = cc.load_config(args.config_dir, use_log=not args.no_log)

    print()
    print(bold("Clash Verge 走向校验（只读）"))
    print(f"  配置目录   {cfg.config_dir}")
    print(f"  运行配置   {cfg.runtime_path.name}  {dim(str(cfg.runtime_path.stat().st_size) + ' 字节')}")
    print(f"  当前订阅   {cfg.profile_name or '未知'}  {dim(cfg.profile_uid or '')}")
    print(
        f"  策略组数   {len(cfg.groups)}    "
        f"profiles 选中项 {len(cfg.selected)} 个    日志实测 {len(cfg.observed)} 组"
    )
    report_summary(cfg)

    if not args.list_domains:
        report_process_rules(cfg)
        report_process_check(cfg, args.process if args.process else CANDIDATE_PROCESSES)

    report_domain_simulation(cfg, args.domain if args.domain else DEFAULT_SAMPLE_DOMAINS)
    report_group_table(cfg)

    print()
    print(dim("说明：标注「日志实测」的出口来自内核日志中最近一次实际使用记录，可能滞后于当前选中。"))
    print(dim("      标注「推断」的出口是组内第一项，仅在该组从未出现在日志中时使用。"))
    print(dim("      需要判定具体网址时，请使用 route_inspect.py。"))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
