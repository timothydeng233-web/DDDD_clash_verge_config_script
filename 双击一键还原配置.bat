@echo off
:: =====================================================================
:: Clash Verge Rev 最近一次 Codex 部署快照恢复工具
:: =====================================================================
chcp 65001 >nul
cd /d "%~dp0"

echo 正在恢复最近一次 Codex 部署快照...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-ClashVerge.ps1" -Action Restore

echo.
pause

exit
