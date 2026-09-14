@echo off
:: =====================================================================
:: Clash Verge Rev Codex 本机适配只读审计入口
:: =====================================================================
chcp 65001 >nul
cd /d "%~dp0"

echo 正在启动本机只读审计（不会部署或覆盖配置）...
echo 本项目需要 Codex 根据本机安装路径、策略组和网络环境适配后再部署。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-ClashVerge.ps1" -Action Audit

echo.
pause

exit
