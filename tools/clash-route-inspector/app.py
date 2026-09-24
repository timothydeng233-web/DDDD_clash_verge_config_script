#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
app.py — Clash Verge 网址路由判定 · 可视化控制台

本地网页应用。双击「Clash网站规则匹配查询.bat」启动，自动在 Google Chrome 打开操作界面。

设计约束
    · 仅监听 127.0.0.1，不对外暴露。
    · 只读取 Clash Verge 配置与内核日志，绝不修改、不重载任何设置。
    · 仅使用 Python 标准库，无需安装任何第三方包。

接口
    GET  /                 操作界面
    GET  /api/overview     配置概览：规则数、策略组、进程规则、运行态
    POST /api/analyze      判定网址，body 为 {"urls": [...], "process": "chrome.exe"}
"""

from __future__ import annotations

import json
import socket
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clash_config as cc  # noqa: E402

HERE = Path(__file__).resolve().parent
UI_FILE = HERE / "ui.html"

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe",
]

HOST = "127.0.0.1"
PORT_CANDIDATES = list(range(8765, 8786))

CONFIG_DIR_OVERRIDE: str | None = None


# ---------------------------------------------------------------- 配置加载


def load_fresh() -> cc.ConfigBundle:
    """
    每次请求都重新读取配置。

    实测加载耗时约 23 ms，遍历约 3 ms，完全在交互可接受范围内；
    不缓存可以彻底避免订阅刷新后结论过期的风险。
    """
    return cc.load_config(CONFIG_DIR_OVERRIDE, use_log=True)


# ---------------------------------------------------------------- 处理函数


class Handler(BaseHTTPRequestHandler):
    server_version = "ClashRouteInspector/1.0"
    protocol_version = "HTTP/1.1"

    # 关闭默认的逐请求日志，保持控制台干净
    def log_message(self, fmt, *args):  # noqa: D102
        pass

    # -------------------------------------------------- 工具

    def _host_ok(self) -> bool:
        """拒绝非回环 Host，避免 DNS rebinding。"""
        host = (self.headers.get("Host") or "").split(":")[0].strip().lower()
        return host in ("127.0.0.1", "localhost", "[::1]", "::1")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, data, code: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self._send(code, body, "application/json; charset=utf-8")

    def _error(self, message: str, code: int = 400) -> None:
        self._json({"ok": False, "error": message}, code)

    # -------------------------------------------------- GET

    def do_GET(self) -> None:  # noqa: N802
        if not self._host_ok():
            self._error("仅允许本机访问", 403)
            return

        path = urlparse(self.path).path

        if path in ("/", "/index.html"):
            if not UI_FILE.is_file():
                self._error(f"找不到界面文件：{UI_FILE}", 500)
                return
            self._send(200, UI_FILE.read_bytes(), "text/html; charset=utf-8")
            return

        if path == "/favicon.ico":
            self._send(204, b"", "image/x-icon")
            return

        if path == "/api/overview":
            try:
                cfg = load_fresh()
                self._json({"ok": True, "data": cc.overview(cfg)})
            except SystemExit as exc:
                self._error(str(exc), 500)
            except Exception as exc:  # noqa: BLE001
                self._error(f"读取配置失败：{exc}", 500)
            return

        self._error("未知路径", 404)

    # -------------------------------------------------- POST

    def do_POST(self) -> None:  # noqa: N802
        if not self._host_ok():
            self._error("仅允许本机访问", 403)
            return

        path = urlparse(self.path).path
        if path != "/api/analyze":
            self._error("未知路径", 404)
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._error("请求体不是合法 JSON")
            return

        urls = payload.get("urls") or []
        if isinstance(urls, str):
            urls = [urls]
        urls = [u for u in (str(x).strip() for x in urls) if u]
        if not urls:
            self._error("没有提供任何网址")
            return
        if len(urls) > 200:
            self._error("一次最多判定 200 个网址")
            return

        process = (payload.get("process") or "").strip() or None

        try:
            cfg = load_fresh()
        except SystemExit as exc:
            self._error(str(exc), 500)
            return
        except Exception as exc:  # noqa: BLE001
            self._error(f"读取配置失败：{exc}", 500)
            return

        results = []
        for raw in urls:
            target = cc.normalize_target(raw)
            if target.error or not target.host:
                results.append(
                    {
                        "url": raw,
                        "error": target.error or "无法解析主机名",
                        "host": None,
                        "port": None,
                        "scheme": None,
                        "is_ip": False,
                        "scoped": None,
                        "any": None,
                        "same_outcome": False,
                        "evidence": [],
                        "observed": None,
                        "uncertain": False,
                        "agreement": {"scoped": False, "any": False, "has_evidence": False},
                    }
                )
                continue
            results.append(cc.analyze_target(cfg, target, process))

        meta = cc.runtime_meta(cfg)
        self._json(
            {
                "ok": True,
                "results": results,
                "meta": {
                    "profile_name": cfg.profile_name,
                    "rules_count": len(cfg.rules),
                    "process": process,
                    **meta,
                },
            }
        )


# ---------------------------------------------------------------- 启动


def pick_port() -> int:
    for port in PORT_CANDIDATES:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((HOST, port))
                return port
            except OSError:
                continue
    raise SystemExit("8765-8785 端口全部被占用，请先关闭其他实例。")


def open_chrome(url: str) -> str:
    import os
    import subprocess

    for cand in CHROME_CANDIDATES:
        path = Path(os.path.expandvars(cand))
        if path.is_file():
            try:
                subprocess.Popen([str(path), url])
                return f"已用 Google Chrome 打开：{path}"
            except OSError:
                continue
    try:
        webbrowser.open(url)
        return "未找到 Chrome，已用系统默认浏览器打开"
    except Exception as exc:  # noqa: BLE001
        return f"未能自动打开（{exc}）"


def main() -> int:
    global CONFIG_DIR_OVERRIDE

    cc.setup_stdout()

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    no_open = "--no-open" in sys.argv
    if args:
        CONFIG_DIR_OVERRIDE = args[0]

    cfg = load_fresh()
    port = pick_port()
    url = f"http://{HOST}:{port}/"

    print()
    print("=" * 66)
    print("  Clash Verge 网址路由判定 · 可视化控制台")
    print("=" * 66)
    print(f"  配置目录   {cfg.config_dir}")
    print(f"  运行配置   {cfg.runtime_path.name}   规则 {len(cfg.rules):,} 条")
    print(f"  当前订阅   {cfg.profile_name or '未知'}")
    print(f"  策略组     {len(cfg.groups)} 个   进程规则 {len(cc.process_rules(cfg.rules))} 条")
    print("-" * 66)
    print(f"  访问地址   {url}")
    print("  只读运行，不会修改或重载任何 Clash Verge 设置。")
    print("  关闭本窗口即可停止服务。")
    print("=" * 66)

    httpd = ThreadingHTTPServer((HOST, port), Handler)
    httpd.daemon_threads = True

    if not no_open:
        print("  " + open_chrome(url))
    print()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
