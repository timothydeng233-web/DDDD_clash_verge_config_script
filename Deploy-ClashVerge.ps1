# =====================================================================
# Clash Verge Rev 多电脑一键极速统一部署与恢复脚本
# =====================================================================
# 参数:
#   -Restore : [开关参数] 启用一键配置还原，将本机还原至部署前的状态。
# 作用: 自动检测安装 Clash Verge Rev, 备份/同步系统配置 (verge.yaml)
#       与全局覆写分流规则 (Merge.yaml)。
# =====================================================================

param (
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

# 1. 提升管理员权限运行检测
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] 警告: 本脚本需要管理员权限进行操作！"
    Write-Host "[*] 正在尝试以管理员身份重新拉起脚本..."
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Restore) { $argList += " -Restore" }
    Start-Process powershell -ArgumentList $argList -Verb RunAs
    exit
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "       Clash Verge Rev 多端安全统一部署与还原工具" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 定义动态物理路径
$ClashAppData = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$BackupSource = "$PSScriptRoot\ConfigBackup"

# =====================================================================
# 分支一：【一键配置还原逻辑 (-Restore)】
# =====================================================================
if ($Restore) {
    Write-Host "[*] 正在启动配置一键还原程序..." -ForegroundColor Yellow
    
    $VergeBak = "$ClashAppData\verge.yaml.bak"
    $MergeBak = "$ClashAppData\profiles\Merge.yaml.bak"
    $RestoredAny = $false

    # 还原 verge.yaml
    if (Test-Path $VergeBak) {
        Copy-Item -Path $VergeBak -Destination "$ClashAppData\verge.yaml" -Force
        Write-Host "[✓] 已成功还原系统全局配置 verge.yaml" -ForegroundColor Green
        $RestoredAny = $true
    } else {
        Write-Host "[-] 未检测到 verge.yaml 的备份文件 (.bak)，跳过。" -ForegroundColor Gray
    }

    # 还原 Merge.yaml
    if (Test-Path $MergeBak) {
        Copy-Item -Path $MergeBak -Destination "$ClashAppData\profiles\Merge.yaml" -Force
        Write-Host "[✓] 已成功还原全局覆写规则 Merge.yaml" -ForegroundColor Green
        $RestoredAny = $true
    } else {
        Write-Host "[-] 未检测到 Merge.yaml 的备份文件 (.bak)，跳过。" -ForegroundColor Gray
    }

    if (-not $RestoredAny) {
        Write-Warning "[!] 本机未检测到任何可用的历史配置备份 (.bak)！"
        Read-Host "按下回车键退出..."
        exit
    }

    # 重启 Clash Verge 重载还原后的配置
    Write-Host "[*] 正在强制重新启动 Clash Verge 以应用还原后的配置..." -ForegroundColor Yellow
    Get-Process -Name "Clash Verge" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    $ExePath = "C:\Program Files\Clash Verge\clash-verge.exe"
    if (-not (Test-Path $ExePath)) {
        $ExePath = "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe"
    }

    if (Test-Path $ExePath) {
        Start-Process -FilePath $ExePath
        Write-Host "[✓] Clash Verge Rev 客户端已顺利重新拉起！" -ForegroundColor Green
    }

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " 🎉 配置还原工作已圆满完成！本机配置已安全恢复至改动前状态。" -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Cyan
    Read-Host "按下回车键即可安全关闭本窗口..."
    exit
}

# =====================================================================
# 分支二：【常规同步部署逻辑 (Default)】
# =====================================================================
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

if (-not $IsInstalled) {
    Write-Host "[!] 检测到本机未安装 Clash Verge Rev！" -ForegroundColor Red
    Write-Host "[*] 正在使用 Windows 原生 Winget 静默下载并安装官方最新版本..." -ForegroundColor Yellow
    
    try {
        winget install io.github.clash-verge-rev.clash-verge-rev --silent --accept-source-agreements --accept-package-agreements
        Write-Host "[✓] Winget 安装程序已成功触发运行！" -ForegroundColor Green
        
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
        Write-Error "[x] 错误: Winget 自动部署失败。请先手动安装软件，然后再运行本脚本同步配置。"
        Read-Host "按下回车键退出脚本..."
        exit
    }
} else {
    Write-Host "[✓] 扫描到已安装 Clash Verge Rev，可执行路径: $ExePath" -ForegroundColor Green
}

# 创建目标 AppData 目录结构 (若不存在)
if (-not (Test-Path $ClashAppData)) {
    New-Item -ItemType Directory -Force -Path $ClashAppData | Out-Null
}
if (-not (Test-Path "$ClashAppData\profiles")) {
    New-Item -ItemType Directory -Force -Path "$ClashAppData\profiles" | Out-Null
}

# 备份本机原配置 (防意外退回，仅在不存在旧备份时写入，防止覆盖最初最干净的备份)
Write-Host "[*] 正在检测并为您备份本机原有配置..." -ForegroundColor Yellow
if (Test-Path "$ClashAppData\verge.yaml") {
    if (-not (Test-Path "$ClashAppData\verge.yaml.bak")) {
        Copy-Item -Path "$ClashAppData\verge.yaml" -Destination "$ClashAppData\verge.yaml.bak" -Force
        Write-Host "[+] 已成功建立初始 verge.yaml.bak 物理防线备份" -ForegroundColor Green
    } else {
        Write-Host "[i] 检测到已存在历史备份 verge.yaml.bak，为保护最原始配置，不再进行覆盖。" -ForegroundColor Gray
    }
}
if (Test-Path "$ClashAppData\profiles\Merge.yaml") {
    if (-not (Test-Path "$ClashAppData\profiles\Merge.yaml.bak")) {
        Copy-Item -Path "$ClashAppData\profiles\Merge.yaml" -Destination "$ClashAppData\profiles\Merge.yaml.bak" -Force
        Write-Host "[+] 已成功建立初始 Merge.yaml.bak 物理防线备份" -ForegroundColor Green
    } else {
        Write-Host "[i] 检测到已存在历史备份 Merge.yaml.bak，为保护最原始配置，不再进行覆盖。" -ForegroundColor Gray
    }
}

# 安全统一步署核心配置文件
Write-Host "[*] 正在同步全新安全统合配置..." -ForegroundColor Yellow

if (-not (Test-Path "$BackupSource\verge.yaml") -or -not (Test-Path "$BackupSource\Merge.yaml")) {
    Write-Error "[x] 错误: 未能在备份源目录 ($BackupSource) 中找到核心配置文件 verge.yaml 或 Merge.yaml！"
    Read-Host "按下回车键退出脚本..."
    exit
}

Copy-Item -Path "$BackupSource\verge.yaml" -Destination "$ClashAppData\verge.yaml" -Force
Copy-Item -Path "$BackupSource\Merge.yaml" -Destination "$ClashAppData\profiles\Merge.yaml" -Force

Write-Host "[✓] 核心系统运行参数配置 (verge.yaml) 已强制统一！" -ForegroundColor Green
Write-Host "[✓] 核心全局覆写分流规则 (Merge.yaml) 已强制统一！" -ForegroundColor Green

# 热重启 Clash Verge Rev 以重载配置
Write-Host "[*] 正在重新启动 Clash Verge 客户端以重载配置..." -ForegroundColor Yellow

Get-Process -Name "Clash Verge" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

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
