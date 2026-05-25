# =====================================================================
# Clash Verge Rev 多电脑一键极速统一部署脚本
# =====================================================================
# 作用: 自动检测安装 Clash Verge Rev, 克隆系统配置 (verge.yaml)
#       与全局覆写分流规则 (Merge.yaml), 实现免除本地系统代理、
#       强制开启 TUN 模式、锁定 MTU 1500 及加速 DNS 体验。
# 安全脱敏: 本脚本完全隔离节点订阅数据，100% 杜绝敏感订阅 URL 泄露。
# =====================================================================

$ErrorActionPreference = "Stop"

# 1. 提升管理员权限运行检测
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] 警告: 本脚本需要管理员权限来检测/安装软件以及进行网卡调整！"
    Write-Host "[*] 正在尝试以管理员身份重新拉起脚本..."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "       Clash Verge Rev 多端安全统一部署工具" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 定义目标物理路径 (动态自适应不同的电脑用户名路径)
$ClashAppData = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$BackupSource = "$PSScriptRoot\ConfigBackup"

# 2. 检测 Clash Verge Rev 是否已安装
Write-Host "[*] 正在扫描本机 Clash Verge Rev 安装状态..." -ForegroundColor Yellow

$InstallPaths = @(
    "C:\Program Files\Clash Verge\clash-verge.exe",
    "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe"
)

$IsInstalled = $false
$ExePath = ""
foreach ($path in $InstallPaths) {
    if (Test-Path $path) {
        $IsInstalled = $true
        $ExePath = $path
        break
    }
}

# 3. 未安装则通过 Winget 自动安装
if (-not $IsInstalled) {
    Write-Host "[!] 检测到本机未安装 Clash Verge Rev！" -ForegroundColor Red
    Write-Host "[*] 正在使用 Windows 原生 Winget 静默下载并安装官方最新版本..." -ForegroundColor Yellow
    
    try {
        # 允许静默同意协议并进行安装
        winget install io.github.clash-verge-rev.clash-verge-rev --silent --accept-source-agreements --accept-package-agreements
        Write-Host "[✓] Winget 安装程序已成功触发运行！" -ForegroundColor Green
        
        # 等待安装释放物理目录 (循环检测 30 秒)
        $Timeout = 30
        while ($Timeout -gt 0) {
            foreach ($path in $InstallPaths) {
                if (Test-Path $path) {
                    $ExePath = $path
                    $IsInstalled = $true
                    break
                }
            }
            if ($IsInstalled) { break }
            Start-Sleep -Seconds 2
            $Timeout -= 2
        }
        
        if (-not $IsInstalled) {
            throw "安装超时，请手动双击安装程序后再运行本脚本。"
        }
    }
    catch {
        Write-Error "[x] 错误: Winget 自动部署失败。请先手动下载并安装 Clash Verge Rev，然后再运行本脚本同步配置。"
        Read-Host "按下回车键退出脚本..."
        exit
    }
} else {
    Write-Host "[✓] 扫描到已安装 Clash Verge Rev，可执行路径: $ExePath" -ForegroundColor Green
}

# 4. 创建目标 AppData 目录结构 (若不存在)
if (-not (Test-Path $ClashAppData)) {
    New-Item -ItemType Directory -Force -Path $ClashAppData | Out-Null
}
if (-not (Test-Path "$ClashAppData\profiles")) {
    New-Item -ItemType Directory -Force -Path "$ClashAppData\profiles" | Out-Null
}

# 5. 备份本机原配置 (防意外退回)
Write-Host "[*] 正在为您备份本机原有配置..." -ForegroundColor Yellow
if (Test-Path "$ClashAppData\verge.yaml") {
    Copy-Item -Path "$ClashAppData\verge.yaml" -Destination "$ClashAppData\verge.yaml.bak" -Force
    Write-Host "[+] 已为原 verge.yaml 创建备份文件 (.bak)" -ForegroundColor Gray
}
if (Test-Path "$ClashAppData\profiles\Merge.yaml") {
    Copy-Item -Path "$ClashAppData\profiles\Merge.yaml" -Destination "$ClashAppData\profiles\Merge.yaml.bak" -Force
    Write-Host "[+] 已为原 Merge.yaml 创建备份文件 (.bak)" -ForegroundColor Gray
}

# 6. 安全统一步署核心配置文件 (零订阅，不泄露)
Write-Host "[*] 正在同步全新安全统合配置..." -ForegroundColor Yellow

if (-not (Test-Path "$BackupSource\verge.yaml") -or -not (Test-Path "$BackupSource\Merge.yaml")) {
    Write-Error "[x] 错误: 未能在备份源目录 ($BackupSource) 中找到核心配置文件 verge.yaml 或 Merge.yaml！"
    Read-Host "按下回车键退出脚本..."
    exit
}

# 物理拷贝
Copy-Item -Path "$BackupSource\verge.yaml" -Destination "$ClashAppData\verge.yaml" -Force
Copy-Item -Path "$BackupSource\Merge.yaml" -Destination "$ClashAppData\profiles\Merge.yaml" -Force

Write-Host "[✓] 核心系统运行参数配置 (verge.yaml) 已强制统一！" -ForegroundColor Green
Write-Host "[✓] 核心全局覆写分流规则 (Merge.yaml) 已强制统一！" -ForegroundColor Green

# 7. 热重启 Clash Verge Rev 以重载配置
Write-Host "[*] 正在重新启动 Clash Verge 客户端以重载配置..." -ForegroundColor Yellow

# 静默杀掉旧进程
Get-Process -Name "Clash Verge" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# 重启拉起客户端
try {
    Start-Process -FilePath $ExePath
    Write-Host "[✓] Clash Verge Rev 客户端已顺利重新拉起运行！" -ForegroundColor Green
}
catch {
    Write-Warning "[!] 提示: 配置已就绪，但未能自动拉起客户端。请您手动双击桌面快捷方式启动 Clash Verge。"
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " 🎉 恭喜！多终端 Clash Verge Rev 配置统一已圆满成功！" -ForegroundColor Green
Write-Host " 🔒 本次同步已完美实现订阅隐私防线隔离，未泄露任何订阅信息。" -ForegroundColor Green
Write-Host " 👉 下一步：请在软件中手动点击“导入”贴入您的订阅链接即可使用。" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

Read-Host "全部统一部署已完成，按下回车键即可安全关闭本窗口..."
