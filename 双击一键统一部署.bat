@echo off
:: =====================================================================
:: Clash Verge Rev 一键多端配置安全统一部署引导工具
:: =====================================================================
chcp 65001 >nul
cd /d "%~dp0"

echo 正在以管理员权限拉起自动化部署脚本...
echo 请在随后系统弹出的“用户账户控制 (UAC)”窗口中点击“是 (Yes)”以授权。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Deploy-ClashVerge.ps1\"' -Verb RunAs"

exit
