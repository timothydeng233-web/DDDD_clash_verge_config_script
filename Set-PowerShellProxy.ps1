#requires -Version 5.1

<#
.SYNOPSIS
    为 PowerShell 配置 Clash 本地代理。默认只影响当前会话。

.EXAMPLE
    . .\Set-PowerShellProxy.ps1 -Action Enable

.EXAMPLE
    .\Set-PowerShellProxy.ps1 -Action Enable -Mode Persistent

.EXAMPLE
    .\Set-PowerShellProxy.ps1 -Action Disable -Mode Persistent
#>

[CmdletBinding()]
param(
    [ValidateSet("Enable", "Disable", "Status")]
    [string]$Action = "Status",
    [ValidateSet("Session", "Persistent")]
    [string]$Mode = "Session",
    [ValidateRange(0, 65535)]
    [int]$MixedPort = 0,
    [string]$ConfigDir
)

$ErrorActionPreference = "Stop"
$NoProxyValue = "localhost,127.0.0.1,::1,.local"

function Find-ClashConfigDirectory {
    param([string]$PreferredDirectory)
    $candidates = @()
    if ($PreferredDirectory) { $candidates += $PreferredDirectory }
    $candidates += @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:APPDATA "clash-verge-rev"),
        (Join-Path $env:USERPROFILE ".config\clash-verge-rev")
    )
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $candidate "verge.yaml") -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-DetectedMixedPort {
    param([int]$RequestedPort, [string]$Root)
    if ($RequestedPort -gt 0) { return $RequestedPort }
    if ($Root) {
        $vergePath = Join-Path $Root "verge.yaml"
        $text = Get-Content -LiteralPath $vergePath -Raw -Encoding UTF8
        if ($text -match '(?m)^verge_mixed_port\s*:\s*([0-9]+)\s*$') { return [int]$Matches[1] }
    }
    throw "无法检测 Clash 混合端口，请使用 -MixedPort 明确指定。"
}

function Set-SessionProxy {
    param([string]$ProxyUrl)
    $env:HTTP_PROXY = $ProxyUrl
    $env:HTTPS_PROXY = $ProxyUrl
    $env:NO_PROXY = $NoProxyValue
}

function Clear-SessionProxy {
    Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:ALL_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
}

$root = Find-ClashConfigDirectory $ConfigDir
$port = if ($Action -eq "Enable" -or $Action -eq "Status") {
    try { Get-DetectedMixedPort $MixedPort $root } catch { if ($Action -eq "Enable") { throw }; $null }
} else { $null }

if ($Action -eq "Status") {
    Write-Host "当前会话 HTTP_PROXY : $env:HTTP_PROXY"
    Write-Host "当前会话 HTTPS_PROXY: $env:HTTPS_PROXY"
    Write-Host "当前会话 NO_PROXY   : $env:NO_PROXY"
    Write-Host "用户级 HTTP_PROXY   : $([Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User'))"
    Write-Host "用户级 HTTPS_PROXY  : $([Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User'))"
    if ($port) {
        $listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-Host "Clash 混合端口       : 127.0.0.1:$port（监听=$listening）"
    }
    return
}

if ($Mode -eq "Session" -and $MyInvocation.InvocationName -ne '.') {
    throw "Session 模式必须点源运行，才能影响当前终端：. .\Set-PowerShellProxy.ps1 -Action $Action -Mode Session"
}

if ($Action -eq "Enable") {
    $proxyUrl = "http://127.0.0.1:$port"
    $listening = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $listening) { throw "Clash 混合端口未监听：127.0.0.1:$port" }
    Set-SessionProxy $proxyUrl
    if ($Mode -eq "Persistent") {
        [Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxyUrl, "User")
        [Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyUrl, "User")
        [Environment]::SetEnvironmentVariable("NO_PROXY", $NoProxyValue, "User")
    }
    Write-Host "[✓] 已启用 $Mode PowerShell 代理：$proxyUrl" -ForegroundColor Green
} else {
    Clear-SessionProxy
    if ($Mode -eq "Persistent") {
        foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")) {
            [Environment]::SetEnvironmentVariable($name, $null, "User")
        }
    }
    Write-Host "[✓] 已清除 $Mode PowerShell 代理。" -ForegroundColor Green
}
