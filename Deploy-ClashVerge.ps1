#requires -Version 5.1

<#
.SYNOPSIS
    Clash Verge Rev 本机适配、部署与恢复工具。

.DESCRIPTION
    本脚本是给 Codex/管理员审计后使用的模板工具，不假设所有电脑使用相同的
    安装目录、配置目录或订阅策略组。默认只执行 Audit，不会修改系统。
#>

[CmdletBinding()]
param (
    [ValidateSet("Audit", "Test", "IsolatedTest", "Generate", "Deploy", "Restore")]
    [string]$Action = "Audit",
    [string]$InstallPath,
    [string]$ConfigDir,
    [string]$ProxyGroup,
    [string]$GeminiGroup,
    [string]$AcademicGroup = "DIRECT",
    [string]$MicrosoftGroup = "DIRECT",
    [string]$MicrosoftDownloadGroup = "DIRECT",
    [string]$OutputDirectory,
    [ValidateSet("Auto", "Enable", "Disable")]
    [string]$TunMode = "Auto",
    [ValidateSet("Auto", "Enable", "Disable")]
    [string]$BlockQuic = "Auto",
    [ValidateScript({ $_ -eq 0 -or ($_ -ge 576 -and $_ -le 9000) })]
    [int]$TunMtu = 0,
    [ValidateRange(0, 65535)]
    [int]$MixedPort = 0,
    [switch]$InstallIfMissing,
    [switch]$SkipOpenAiRules,
    [switch]$SkipGeminiRules,
    [switch]$SkipAcademicRules,
    [switch]$SkipMicrosoftRules,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$WingetPackageId = "ClashVergeRev.ClashVergeRev"
$MergeTemplatePath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "Merge.yaml"
$OpenAiDomainsPath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "OpenAI.domains.txt"
$GeminiDomainsPath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "Gemini.domains.txt"
$AcademicDomainsPath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "Academic.domains.txt"
$MicrosoftDomainsPath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "Microsoft.domains.txt"
$MicrosoftDownloadDomainsPath = Join-Path (Join-Path $PSScriptRoot "ConfigBackup") "Microsoft.Download.domains.txt"

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { return $null }
}

function Find-ClashVerge {
    param([string]$PreferredPath)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($PreferredPath) { $candidates.Add($PreferredPath) }
    Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path) { $candidates.Add($_.Path) } } catch { }
    }
    $uninstallRoots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "^Clash Verge" } |
        ForEach-Object {
            if ($_.InstallLocation) {
                $location = ([string]$_.InstallLocation).Trim('"')
                $candidates.Add((Join-Path $location "clash-verge.exe"))
            }
            if ($_.DisplayIcon) {
                $candidates.Add((([string]$_.DisplayIcon -split ',')[0]).Trim('"'))
            }
        }
    $candidates.Add("C:\Program Files\Clash Verge\clash-verge.exe")
    $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Clash Verge\clash-verge.exe"))
    $candidates.Add((Join-Path $env:USERPROFILE "scoop\apps\clash-verge-rev\current\clash-verge.exe"))
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $resolved = Resolve-NormalizedPath $candidate
        if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $appDir = Split-Path -Parent $resolved
            $mihomo = Join-Path $appDir "verge-mihomo.exe"
            return [pscustomobject]@{
                ExePath = $resolved
                AppDir = $appDir
                MihomoPath = $(if (Test-Path -LiteralPath $mihomo) { $mihomo } else { $null })
                Version = (Get-Item -LiteralPath $resolved).VersionInfo.FileVersion
            }
        }
    }
    return $null
}

function Find-ConfigDirectory {
    param([string]$PreferredDirectory)
    $candidates = @()
    if ($PreferredDirectory) { $candidates += $PreferredDirectory }
    $candidates += @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:APPDATA "clash-verge-rev"),
        (Join-Path $env:USERPROFILE ".config\clash-verge-rev")
    )
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $resolved = Resolve-NormalizedPath $candidate
        if (-not $resolved) { continue }
        $markers = @("verge.yaml", "profiles.yaml", "config.yaml", "profiles")
        $score = @($markers | Where-Object { Test-Path -LiteralPath (Join-Path $resolved $_) }).Count
        if ($score -ge 2) { return $resolved }
    }
    return $null
}

function Initialize-ConfigDirectory {
    param([Parameter(Mandatory = $true)]$App)
    Write-Host "[*] 首次启动 Clash Verge Rev 以生成用户配置目录..." -ForegroundColor Yellow
    Start-Process -FilePath $App.ExePath | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $found = Find-ConfigDirectory
        if ($found) { break }
    } while ((Get-Date) -lt $deadline)
    Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | Stop-Process -Force
    return $found
}

function Get-ProxyGroupNames {
    param([Parameter(Mandatory = $true)][string]$GeneratedConfigPath)
    if (-not (Test-Path -LiteralPath $GeneratedConfigPath)) { return @() }
    $insideGroups = $false
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $GeneratedConfigPath -Encoding UTF8) {
        if ($line -match '^proxy-groups\s*:') { $insideGroups = $true; continue }
        if ($insideGroups -and $line -match '^\s*-\s*name\s*:\s*(.+?)\s*$') {
            $name = $Matches[1].Trim().Trim('"').Trim("'")
            if ($name) { $names.Add($name) }
            continue
        }
        if ($insideGroups -and $line -match '^[A-Za-z0-9_-]+\s*:') { break }
    }
    return @($names | Select-Object -Unique)
}

function Select-ProxyGroup {
    param([string[]]$AvailableGroups, [string]$RequestedGroup)
    if ($RequestedGroup) {
        if ($AvailableGroups -notcontains $RequestedGroup) {
            throw "指定的策略组 '$RequestedGroup' 不存在。可用策略组: $($AvailableGroups -join ', ')"
        }
        return $RequestedGroup
    }
    $preferred = @("🔰 选择节点", "选择节点", "节点选择", "代理", "Proxy", "PROXY")
    $matches = @($preferred | Where-Object { $AvailableGroups -contains $_ })
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) {
        throw "检测到多个候选策略组，请使用 -ProxyGroup 明确指定: $($matches -join ', ')"
    }
    return $null
}

function Resolve-RuleTarget {
    param(
        [string[]]$AvailableGroups,
        [string]$RequestedTarget,
        [Parameter(Mandatory = $true)][string]$DefaultTarget,
        [Parameter(Mandatory = $true)][string]$ParameterName
    )
    $target = if ($RequestedTarget) { $RequestedTarget } else { $DefaultTarget }
    $builtins = @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")
    if (($builtins -notcontains $target) -and ($AvailableGroups -notcontains $target)) {
        throw "$ParameterName 指定的目标 '$target' 不存在。可用策略组: $($AvailableGroups -join ', ')"
    }
    return $target
}

function Get-DomainRuleDefinitions {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ServiceName
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "缺少 $ServiceName 域名定义: $Path" }
    $definitions = @()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $value = $line.Trim()
        if (-not $value -or $value.StartsWith('#')) { continue }
        if ($value -notmatch '^(DOMAIN|DOMAIN-SUFFIX),([^,\s]+)$') {
            throw "无效的 $ServiceName 域名定义: $value"
        }
        $definitions += [pscustomobject]@{ Type = $Matches[1]; Domain = $Matches[2].ToLowerInvariant() }
    }
    return $definitions
}

function Get-RoutingRules {
    param([Parameter(Mandatory = $true)][string]$GeneratedConfigPath)
    if (-not (Test-Path -LiteralPath $GeneratedConfigPath)) { return @() }
    $currentSection = $null
    $prependRules = @()
    $finalRules = @()
    foreach ($line in Get-Content -LiteralPath $GeneratedConfigPath -Encoding UTF8) {
        if ($line -match '^(rules|prepend-rules)\s*:') { $currentSection = $Matches[1]; continue }
        if (-not $currentSection) { continue }
        if ($line -match '^\s*-\s*(.+?)\s*$') {
            if ($currentSection -eq 'rules') { $finalRules += $Matches[1] }
            else { $prependRules += $Matches[1] }
            continue
        }
        if ($line -match '^[A-Za-z0-9_-]+\s*:') { $currentSection = $null }
    }
    if ($finalRules.Count -gt 0) { return $finalRules }
    return $prependRules
}

function Get-DomainRouteTarget {
    param([Parameter(Mandatory = $true)][string]$Domain, [string[]]$Rules)
    $hostName = $Domain.ToLowerInvariant()
    for ($index = 0; $index -lt $Rules.Count; $index++) {
        $parts = @($Rules[$index] -split ',')
        if ($parts.Count -lt 2) { continue }
        $type = $parts[0].Trim().ToUpperInvariant()
        $matched = $false
        if ($type -eq 'DOMAIN' -and $parts.Count -ge 3) {
            $matched = $hostName -eq $parts[1].Trim().ToLowerInvariant()
        } elseif ($type -eq 'DOMAIN-SUFFIX' -and $parts.Count -ge 3) {
            $suffix = $parts[1].Trim().ToLowerInvariant()
            $matched = $hostName -eq $suffix -or $hostName.EndsWith('.' + $suffix)
        } elseif ($type -eq 'DOMAIN-KEYWORD' -and $parts.Count -ge 3) {
            $matched = $hostName.Contains($parts[1].Trim().ToLowerInvariant())
        } elseif ($type -eq 'MATCH') {
            $matched = $true
        }
        if ($matched) {
            $targetIndex = $parts.Count - 1
            if ($parts[$targetIndex].Trim() -eq 'no-resolve') { $targetIndex-- }
            return [pscustomobject]@{ Target = $parts[$targetIndex].Trim(); Rule = $Rules[$index]; Index = $index + 1 }
        }
    }
    return $null
}

function Test-DomainRouting {
    param(
        [Parameter(Mandatory = $true)][string]$GeneratedConfigPath,
        [Parameter(Mandatory = $true)][string]$DefinitionsPath,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ExpectedGroup
    )
    $rules = @(Get-RoutingRules $GeneratedConfigPath)
    $issues = @()
    foreach ($definition in Get-DomainRuleDefinitions $DefinitionsPath $ServiceName) {
        $route = Get-DomainRouteTarget $definition.Domain $rules
        if (-not $route -or $route.Target -ne $ExpectedGroup) {
            $issues += [pscustomobject]@{
                Domain = $definition.Domain
                Actual = $(if ($route) { $route.Target } else { '<未匹配>' })
                Expected = $ExpectedGroup
            }
        }
    }
    return $issues
}

function Test-OpenAiConnectivity {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Warning "未找到 curl.exe，跳过 OpenAI 公共端点连通测试。"
        return
    }
    Write-Host "[*] OpenAI/ChatGPT 公共端点连通测试（不使用账号或 API Key）..." -ForegroundColor Yellow
    $targets = @(
        "https://chatgpt.com/",
        "https://ws.chatgpt.com/",
        "https://api.openai.com/v1/models",
        "https://auth.openai.com/",
        "https://cdn.workos.com/"
    )
    foreach ($target in $targets) {
        $result = & curl.exe -I -sS -o NUL --connect-timeout 8 --max-time 12 `
            -w "%{http_code}|connect=%{time_connect}|tls=%{time_appconnect}|total=%{time_total}" $target 2>&1
        if ($LASTEXITCODE -eq 0 -and $result -notmatch '^000\|') {
            Write-Host "[✓] $target $result" -ForegroundColor Green
        } else {
            Write-Warning "$target 连接失败: $result"
        }
    }
}

function Test-ServiceConnectivity {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string[]]$Targets
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Warning "未找到 curl.exe，跳过 $ServiceName 公共端点连通测试。"
        return
    }
    Write-Host "[*] $ServiceName 公共端点连通测试（不使用账号或密钥）..." -ForegroundColor Yellow
    foreach ($target in $Targets) {
        $result = & curl.exe -I -sS -o NUL --connect-timeout 8 --max-time 12 `
            -w "%{http_code}|connect=%{time_connect}|tls=%{time_appconnect}|total=%{time_total}" $target 2>&1
        if ($LASTEXITCODE -eq 0 -and $result -notmatch '^000\|') {
            Write-Host "[✓] $target $result" -ForegroundColor Green
        } else {
            Write-Warning "$target 连接失败: $result"
        }
    }
}

function Test-GeminiConnectivity {
    Test-ServiceConnectivity "Gemini/Google AI" @(
        "https://gemini.google.com/",
        "https://aistudio.google.com/",
        "https://generativelanguage.googleapis.com/v1beta/models",
        "https://cloudaicompanion.googleapis.com/",
        "https://accounts.google.com/"
    )
}

function Test-MicrosoftConnectivity {
    Test-ServiceConnectivity "Microsoft Store/Windows Update" @(
        "https://store.microsoft.com/",
        "https://storeedgefd.dsx.mp.microsoft.com/",
        "https://displaycatalog.mp.microsoft.com/",
        "https://licensing.mp.microsoft.com/",
        "https://login.live.com/",
        "http://download.windowsupdate.com/"
    )
}

function Test-AcademicConnectivity {
    Test-ServiceConnectivity "学术网站/ScienceDirect" @(
        "https://www.sciencedirect.com/",
        "https://pdf.sciencedirectassets.com/",
        "https://www.elsevier.com/",
        "https://ieeexplore.ieee.org/",
        "https://www.scopus.com/"
    )
    Write-Host "[i] PDF CDN 根地址返回 403 仍表示 DNS、TCP 和 TLS 已连通；真实 PDF 必须使用浏览器刚生成的短期签名地址验证。"
}

function Get-VergeMixedPort {
    param([Parameter(Mandatory = $true)][string]$VergePath)
    if (-not (Test-Path -LiteralPath $VergePath)) { return $null }
    $text = Get-Content -LiteralPath $VergePath -Raw -Encoding UTF8
    if ($text -match '(?m)^verge_mixed_port\s*:\s*([0-9]+)\s*$') { return [int]$Matches[1] }
    return $null
}

function Show-ChromeAudit {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe" }
    $chromePath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($chromePath) {
        Write-Host "[✓] Chrome: $chromePath" -ForegroundColor Green
        Write-Host "[i] Chrome 版本: $((Get-Item -LiteralPath $chromePath).VersionInfo.FileVersion)"
    } else { Write-Host "[i] 未检测到 Google Chrome。" }
    foreach ($root in @("HKLM:\Software\Policies\Google\Chrome", "HKCU:\Software\Policies\Google\Chrome")) {
        if (-not (Test-Path $root)) { continue }
        $policy = Get-ItemProperty $root -ErrorAction SilentlyContinue
        foreach ($name in @("ProxyMode", "ProxyServer", "QuicAllowed", "DnsOverHttpsMode", "AlwaysOpenPdfExternally")) {
            if ($null -ne $policy.$name) { Write-Host "[i] Chrome 策略 $name = $($policy.$name) ($root)" }
        }
        $forceListPath = Join-Path $root "ExtensionInstallForcelist"
        if (Test-Path $forceListPath) {
            $forceList = Get-ItemProperty $forceListPath -ErrorAction SilentlyContinue
            if (($forceList.PSObject.Properties.Value | Out-String) -match 'efaidnbmnnnibpcajpcglclefindmkaj') {
                Write-Warning "Chrome 企业策略正在强制安装 Adobe Acrobat 扩展。"
            }
        }
    }

    $chromeUserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    $acrobatExtensionId = "efaidnbmnnnibpcajpcglclefindmkaj"
    if (-not (Test-Path -LiteralPath $chromeUserData -PathType Container)) { return }
    foreach ($profile in Get-ChildItem -LiteralPath $chromeUserData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }) {
        $extensionPath = Join-Path $profile.FullName ("Extensions\" + $acrobatExtensionId)
        if (-not (Test-Path -LiteralPath $extensionPath -PathType Container)) { continue }
        $stateText = "状态未知"
        $pdfMode = "未读取"
        $preferencesPath = Join-Path $profile.FullName "Preferences"
        if (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
            try {
                $preferences = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $preferences.plugins.always_open_pdf_externally) {
                    $pdfMode = if ([bool]$preferences.plugins.always_open_pdf_externally) { "下载/外部打开" } else { "Chrome 内置查看器" }
                }
            } catch {
                $pdfMode = "读取失败（Chrome 可能正在更新配置）"
            }
        }
        $securePreferencesPath = Join-Path $profile.FullName "Secure Preferences"
        if (Test-Path -LiteralPath $securePreferencesPath -PathType Leaf) {
            try {
                $securePreferences = Get-Content -LiteralPath $securePreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $settings = $securePreferences.extensions.settings
                $settingProperty = if ($settings) {
                    $settings.PSObject.Properties | Where-Object { $_.Name -eq $acrobatExtensionId } | Select-Object -First 1
                } else { $null }
                if ($settingProperty) {
                    $disableReasons = @($settingProperty.Value.disable_reasons | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 0 })
                    if ($disableReasons.Count -gt 0) {
                        $stateText = "停用（Chrome 原因码 $($disableReasons -join ',')）"
                    } elseif ([int]$settingProperty.Value.state -eq 1) {
                        $stateText = "启用"
                    } else {
                        $stateText = "已安装，状态未明确"
                    }
                }
            } catch {
                $stateText = "读取失败（Chrome 可能正在更新配置）"
            }
        }
        Write-Warning "Chrome 配置档 '$($profile.Name)' 安装了 Adobe Acrobat 扩展：$stateText；PDF 模式：$pdfMode。ScienceDirect PDF 异常时优先用无痕模式和临时停用扩展做 A/B 测试。"
    }
}

function Show-MicrosoftAudit {
    $store = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($store) { Write-Host "[✓] Microsoft Store: $($store.Version)" -ForegroundColor Green }
    else { Write-Warning "当前用户未检测到 Microsoft Store 应用包。" }
    foreach ($serviceName in @("InstallService", "ClipSVC", "AppXSvc", "DoSvc", "wuauserv")) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $startMode = if ($service.PSObject.Properties["StartType"]) {
                $service.StartType
            } else {
                (Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue).StartMode
            }
            Write-Host "[i] Microsoft 服务 $serviceName : $($service.Status) / $startMode"
        } else { Write-Warning "未检测到 Microsoft 服务: $serviceName" }
    }
    $winHttp = (& netsh winhttp show proxy 2>&1 | Out-String).Trim()
    if ($winHttp) { Write-Host "[i] WinHTTP 代理状态: $($winHttp -replace '\r?\n', ' | ')" }
}

function Set-TopLevelYamlScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $pattern = "(?m)^" + [regex]::Escape($Key) + "\s*:.*$"
    $replacement = "$Key`: $Value"
    if ([regex]::IsMatch($Content, $pattern)) {
        return [regex]::Replace($Content, $pattern, $replacement, 1)
    }
    return $Content.TrimEnd() + [Environment]::NewLine + $replacement + [Environment]::NewLine
}

function New-LocalConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentVergePath,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$SelectedProxyGroup,
        [Parameter(Mandatory = $true)][string]$SelectedGeminiGroup,
        [Parameter(Mandatory = $true)][string]$SelectedAcademicGroup,
        [Parameter(Mandatory = $true)][string]$SelectedMicrosoftGroup,
        [Parameter(Mandatory = $true)][string]$SelectedMicrosoftDownloadGroup,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $verge = Get-Content -LiteralPath $CurrentVergePath -Raw -Encoding UTF8
    $verge = Set-TopLevelYamlScalar $verge "enable_system_proxy" "false"
    $verge = Set-TopLevelYamlScalar $verge "clash_core" "verge-mihomo"
    if ($MixedPort -gt 0) { $verge = Set-TopLevelYamlScalar $verge "verge_mixed_port" ([string]$MixedPort) }
    if ($TunMode -eq "Enable") { $verge = Set-TopLevelYamlScalar $verge "enable_tun_mode" "true" }
    if ($TunMode -eq "Disable") { $verge = Set-TopLevelYamlScalar $verge "enable_tun_mode" "false" }
    $generatedVerge = Join-Path $OutputDirectory "verge.yaml"
    [IO.File]::WriteAllText($generatedVerge, $verge, (New-Object Text.UTF8Encoding($false)))

    $merge = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    if ($merge -notmatch [regex]::Escape('__PROXY_GROUP__')) { throw "Merge 模板缺少 __PROXY_GROUP__ 占位符。" }
    $merge = $merge.Replace('__PROXY_GROUP__', $SelectedProxyGroup)
    $openAiLines = "  # OpenAI rules disabled by -SkipOpenAiRules"
    if (-not $SkipOpenAiRules) {
        $openAiLines = @(
            Get-DomainRuleDefinitions $OpenAiDomainsPath "OpenAI" |
                ForEach-Object { "  - $($_.Type),$($_.Domain),$SelectedProxyGroup" }
        ) -join [Environment]::NewLine
    }
    $merge = $merge.Replace('  # __OPENAI_RULES__', $openAiLines)
    $geminiLines = "  # Gemini rules disabled by -SkipGeminiRules"
    if (-not $SkipGeminiRules) {
        $geminiLines = @(
            Get-DomainRuleDefinitions $GeminiDomainsPath "Gemini" |
                ForEach-Object { "  - $($_.Type),$($_.Domain),$SelectedGeminiGroup" }
        ) -join [Environment]::NewLine
    }
    $merge = $merge.Replace('  # __GEMINI_RULES__', $geminiLines)
    $academicLines = "  # Academic rules disabled by -SkipAcademicRules"
    if (-not $SkipAcademicRules) {
        $academicLines = @(
            Get-DomainRuleDefinitions $AcademicDomainsPath "Academic" |
                ForEach-Object { "  - $($_.Type),$($_.Domain),$SelectedAcademicGroup" }
        ) -join [Environment]::NewLine
    }
    $merge = $merge.Replace('  # __ACADEMIC_RULES__', $academicLines)
    $microsoftLines = "  # Microsoft rules disabled by -SkipMicrosoftRules"
    $microsoftDownloadLines = "  # Microsoft download rules disabled by -SkipMicrosoftRules"
    if (-not $SkipMicrosoftRules) {
        $microsoftLines = @(
            Get-DomainRuleDefinitions $MicrosoftDomainsPath "Microsoft" |
                ForEach-Object { "  - $($_.Type),$($_.Domain),$SelectedMicrosoftGroup" }
        ) -join [Environment]::NewLine
        $microsoftDownloadLines = @(
            Get-DomainRuleDefinitions $MicrosoftDownloadDomainsPath "Microsoft Download" |
                ForEach-Object { "  - $($_.Type),$($_.Domain),$SelectedMicrosoftDownloadGroup" }
        ) -join [Environment]::NewLine
    }
    $merge = $merge.Replace('  # __MICROSOFT_RULES__', $microsoftLines)
    $merge = $merge.Replace('  # __MICROSOFT_DOWNLOAD_RULES__', $microsoftDownloadLines)
    $tunBlock = "# TUN 配置保留客户端/订阅现值"
    if ($TunMode -ne "Auto" -or $TunMtu -gt 0) {
        $tunLines = @("tun:")
        if ($TunMode -eq "Enable") { $tunLines += "  enable: true" }
        if ($TunMode -eq "Disable") { $tunLines += "  enable: false" }
        $tunLines += @("  stack: mixed", "  auto-route: true", "  auto-detect-interface: true")
        if ($TunMtu -gt 0) { $tunLines += "  mtu: $TunMtu" }
        $tunBlock = $tunLines -join [Environment]::NewLine
    }
    $merge = $merge.Replace('# __TUN_BLOCK__', $tunBlock)
    $quicLine = "  # QUIC blocking disabled"
    if ($BlockQuic -eq "Enable") { $quicLine = "  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT" }
    $merge = $merge.Replace('  # __BLOCK_QUIC_RULE__', $quicLine)
    $generatedMerge = Join-Path $OutputDirectory "Merge.yaml"
    [IO.File]::WriteAllText($generatedMerge, $merge, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Verge = $generatedVerge; Merge = $generatedMerge }
}

function Test-RuleTargets {
    param([Parameter(Mandatory = $true)][string]$MergePath, [string[]]$AvailableGroups)
    $builtins = @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $MergePath -Encoding UTF8) {
        if ($line -notmatch '^\s*-\s*(.+)$') { continue }
        $rule = ($Matches[1] -split '\s+#', 2)[0].Trim()
        if ($rule -notmatch ',') { continue }
        $parts = @($rule -split ',')
        $targetIndex = $parts.Count - 1
        if ($parts[$targetIndex].Trim() -eq "no-resolve") { $targetIndex-- }
        $target = $parts[$targetIndex].Trim()
        if (($builtins -notcontains $target) -and ($AvailableGroups -notcontains $target)) { $missing.Add($target) }
    }
    $result = @($missing | Select-Object -Unique)
    if ($result.Count -gt 0) { throw "Merge 引用了不存在的策略组: $($result -join ', ')" }
}

function Test-IsolatedMergeSafety {
    param([Parameter(Mandatory = $true)][string]$MergePath)
    $text = Get-Content -LiteralPath $MergePath -Raw -Encoding UTF8
    $dangerousTopLevelKeys = @($text -split "`r?`n" | Where-Object {
        $_ -match '^(proxies|proxy-providers|proxy-groups|rules)\s*:'
    })
    if ($dangerousTopLevelKeys.Count -gt 0) {
        throw "隔离安全检查失败：Merge 含有可能覆盖订阅节点或规则的顶层字段: $($dangerousTopLevelKeys -join '; ')"
    }
    if ($text -match '__[A-Z0-9_]+__') {
        throw "隔离安全检查失败：生成的 Merge 仍包含未替换占位符 '$($Matches[0])'。"
    }
}

function Get-ConfigurationFingerprint {
    param([Parameter(Mandatory = $true)][string]$Root)
    $result = @{}
    foreach ($relativePath in @("verge.yaml", "profiles\Merge.yaml", "profiles.yaml", "clash-verge.yaml")) {
        $path = Join-Path $Root $relativePath
        $result[$relativePath] = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else { "<missing>" }
    }
    return $result
}

function Assert-ConfigurationFingerprintUnchanged {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Before,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $after = Get-ConfigurationFingerprint $Root
    $changed = @($Before.Keys | Where-Object { $Before[$_] -ne $after[$_] })
    if ($changed.Count -gt 0) {
        throw "隔离测试期间本机运行配置发生变化，已停止后续操作: $($changed -join ', ')"
    }
}

function Test-YamlWithMihomo {
    param([string]$MihomoPath, [Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not $MihomoPath) { Write-Warning "未找到 verge-mihomo.exe，只完成文本级检查。"; return }
    & $MihomoPath -t -f $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Mihomo 配置校验失败: $ConfigPath" }
}

function Stop-ClashVerge {
    Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 700
}

function New-DeploymentSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$App)
    $snapshot = Join-Path (Join-Path $Root "codex-deployment-backups") (Get-Date -Format "yyyyMMdd-HHmmss-fff")
    New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
    $entries = @()
    foreach ($relative in @("verge.yaml", "profiles\Merge.yaml", "profiles.yaml")) {
        $source = Join-Path $Root $relative
        $exists = Test-Path -LiteralPath $source -PathType Leaf
        $hash = $null
        if ($exists) {
            $destination = Join-Path $snapshot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
            $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        }
        $entries += [pscustomobject]@{ relativePath = $relative; existed = $exists; sha256 = $hash }
    }
    [pscustomobject]@{
        createdAt = (Get-Date).ToString("o")
        configDir = $Root
        installPath = $App.ExePath
        appVersion = $App.Version
        mihomoPath = $App.MihomoPath
        files = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $snapshot "manifest.json") -Encoding UTF8
    return $snapshot
}

function Install-FileAtomically {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $pending = Join-Path $parent ((Split-Path -Leaf $Destination) + ".pending-" + [guid]::NewGuid().ToString("N"))
    Copy-Item -LiteralPath $Source -Destination $pending -Force
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($pending, $Destination, $null) }
    else { Move-Item -LiteralPath $pending -Destination $Destination }
}

function Restore-Snapshot {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$SnapshotPath)
    if (-not $SnapshotPath) {
        $SnapshotPath = Get-ChildItem -LiteralPath (Join-Path $Root "codex-deployment-backups") -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $SnapshotPath) { throw "没有找到可恢复的部署快照。" }
    $manifestPath = Join-Path $SnapshotPath "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "快照缺少 manifest.json: $SnapshotPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Stop-ClashVerge
    $allowed = @("verge.yaml", "profiles\Merge.yaml", "profiles.yaml")
    foreach ($entry in $manifest.files) {
        if ($allowed -notcontains [string]$entry.relativePath) { continue }
        $destination = Join-Path $Root ([string]$entry.relativePath)
        if ([bool]$entry.existed) {
            $source = Join-Path $SnapshotPath ([string]$entry.relativePath)
            if (-not (Test-Path -LiteralPath $source)) { throw "快照文件缺失: $source" }
            if ($entry.sha256 -and ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne [string]$entry.sha256)) {
                throw "快照文件哈希不匹配，拒绝恢复: $source"
            }
            Install-FileAtomically $source $destination
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    return $SnapshotPath
}

function Show-Audit {
    param($App, [string]$Root)
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " Clash Verge Rev Codex 本机适配审计" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($App) {
        Write-Host "[✓] 程序: $($App.ExePath)" -ForegroundColor Green
        Write-Host "[i] 版本: $($App.Version)"
        Write-Host "[i] Mihomo: $($App.MihomoPath)"
    } else { Write-Warning "未检测到 Clash Verge Rev。需要安装时使用 -InstallIfMissing。" }
    if ($Root) {
        Write-Host "[✓] 配置目录: $Root" -ForegroundColor Green
        $mixedPortValue = Get-VergeMixedPort (Join-Path $Root "verge.yaml")
        if ($mixedPortValue) {
            $portListening = Test-NetConnection -ComputerName 127.0.0.1 -Port $mixedPortValue -InformationLevel Quiet -WarningAction SilentlyContinue
            Write-Host "[i] Clash 混合端口: 127.0.0.1:$mixedPortValue（监听=$portListening）"
        } else { Write-Warning "未能从 verge.yaml 读取混合端口。" }
        $groups = @(Get-ProxyGroupNames (Join-Path $Root "clash-verge.yaml"))
        Write-Host "[i] 当前策略组: $($groups -join ', ')"
        try {
            $selected = Select-ProxyGroup $groups $ProxyGroup
            if ($selected) { Write-Host "[✓] 候选代理策略组: $selected" -ForegroundColor Green }
            else { Write-Warning "无法自动选择代理策略组；部署时必须传入 -ProxyGroup。" }
            if ($selected) {
                $finalConfigPath = Join-Path $Root "clash-verge.yaml"
                $openAiIssues = @(Test-DomainRouting $finalConfigPath $OpenAiDomainsPath "OpenAI" $selected)
                if ($openAiIssues.Count -eq 0) {
                    Write-Host "[✓] OpenAI 官方依赖域名均路由到同一策略组。" -ForegroundColor Green
                } else {
                    Write-Warning "发现 $($openAiIssues.Count) 个 OpenAI 辅助域名未路由到 '$selected':"
                    $openAiIssues | ForEach-Object { Write-Host "    $($_.Domain) -> $($_.Actual)" }
                }
                $selectedGemini = Resolve-RuleTarget $groups $GeminiGroup $selected "-GeminiGroup"
                $geminiIssues = @(Test-DomainRouting $finalConfigPath $GeminiDomainsPath "Gemini" $selectedGemini)
                if ($geminiIssues.Count -eq 0) { Write-Host "[✓] Gemini 域名均路由到 '$selectedGemini'。" -ForegroundColor Green }
                else {
                    Write-Warning "发现 $($geminiIssues.Count) 个 Gemini 域名未路由到 '$selectedGemini':"
                    $geminiIssues | ForEach-Object { Write-Host "    $($_.Domain) -> $($_.Actual)" }
                }
                $selectedMicrosoft = Resolve-RuleTarget $groups $MicrosoftGroup "DIRECT" "-MicrosoftGroup"
                $selectedMicrosoftDownload = Resolve-RuleTarget $groups $MicrosoftDownloadGroup "DIRECT" "-MicrosoftDownloadGroup"
                $microsoftIssues = @(Test-DomainRouting $finalConfigPath $MicrosoftDomainsPath "Microsoft" $selectedMicrosoft)
                $downloadIssues = @(Test-DomainRouting $finalConfigPath $MicrosoftDownloadDomainsPath "Microsoft Download" $selectedMicrosoftDownload)
                if (($microsoftIssues.Count + $downloadIssues.Count) -eq 0) {
                    Write-Host "[✓] Microsoft 控制链路与下载链路使用预期出口。" -ForegroundColor Green
                } else {
                    Write-Warning "Microsoft 路由不一致：控制链路 $($microsoftIssues.Count) 项，下载链路 $($downloadIssues.Count) 项。"
                    @($microsoftIssues + $downloadIssues) | ForEach-Object { Write-Host "    $($_.Domain) -> $($_.Actual)，期望 $($_.Expected)" }
                }
                $selectedAcademic = Resolve-RuleTarget $groups $AcademicGroup "DIRECT" "-AcademicGroup"
                $academicIssues = @(Test-DomainRouting $finalConfigPath $AcademicDomainsPath "Academic" $selectedAcademic)
                if ($academicIssues.Count -eq 0) {
                    Write-Host "[✓] ScienceDirect PDF/Elsevier CDN 使用预期出口 '$selectedAcademic'。" -ForegroundColor Green
                } else {
                    Write-Warning "ScienceDirect PDF/Elsevier CDN 有 $($academicIssues.Count) 项未使用预期出口 '$selectedAcademic'。"
                }
            }
        } catch { Write-Warning $_.Exception.Message }
        $profilesPath = Join-Path $Root "profiles.yaml"
        if ((Test-Path -LiteralPath $profilesPath) -and
            ((Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8) -notmatch '(?m)^\s+merge\s*:\s*Merge\s*$')) {
            Write-Warning "当前订阅没有绑定默认 Merge；部署文件后仍需在客户端为订阅选择 Merge。"
        }
    } else { Write-Warning "未检测到可信的配置目录；可使用 -ConfigDir 明确指定。" }
    if ($TunMtu -eq 0) { Write-Host "[i] MTU: Auto（不覆盖现值）" }
    else { Write-Host "[i] MTU: $TunMtu（部署前应确认物理出口 MTU）" }
    Write-Host "[i] PowerShell 当前会话 HTTP_PROXY: $env:HTTP_PROXY"
    Write-Host "[i] PowerShell 用户级 HTTP_PROXY: $([Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User'))"
    Show-ChromeAudit
    Show-MicrosoftAudit
    $wslConfig = Join-Path $env:USERPROFILE ".wslconfig"
    if (Test-Path -LiteralPath $wslConfig) {
        $wslText = Get-Content -LiteralPath $wslConfig -Raw -ErrorAction SilentlyContinue
        $networkMode = if ($wslText -match '(?im)^\s*networkingMode\s*=\s*([^\s#;]+)') { $Matches[1] } else { "未显式设置" }
        Write-Host "[i] WSL networkingMode: $networkMode"
    }
    Write-Host "[i] 默认 Audit 不会修改任何文件。"
}

$app = Find-ClashVerge $InstallPath
if (-not $app -and $InstallIfMissing) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "未找到 winget。" }
    Write-Host "[*] 正在通过官方 WinGet 包安装 Clash Verge Rev..." -ForegroundColor Yellow
    & winget install --id $WingetPackageId --exact --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "WinGet 安装失败。" }
    $app = Find-ClashVerge $InstallPath
}

$configRoot = Find-ConfigDirectory $ConfigDir
if (-not $configRoot -and $app -and $Action -eq "Deploy") { $configRoot = Initialize-ConfigDirectory $app }
if ($Action -eq "Audit" -or $Action -eq "Test") {
    Show-Audit $app $configRoot
    if ($Action -eq "Test") {
        Test-OpenAiConnectivity
        Test-GeminiConnectivity
        Test-MicrosoftConnectivity
        Test-AcademicConnectivity
    }
    exit 0
}
if (-not $app) { throw "未检测到 Clash Verge Rev；请指定 -InstallPath 或使用 -InstallIfMissing。" }
if (-not $configRoot) { throw "未检测到配置目录；请先启动一次客户端或使用 -ConfigDir。" }

if ($Action -eq "Restore") {
    $restored = $null
    try {
        $restored = Restore-Snapshot $configRoot
    } finally {
        Start-Process -FilePath $app.ExePath | Out-Null
    }
    Write-Host "[✓] 已恢复快照并重新启动客户端: $restored" -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $MergeTemplatePath)) { throw "缺少 Merge 模板: $MergeTemplatePath" }
$currentVerge = Join-Path $configRoot "verge.yaml"
if (-not (Test-Path -LiteralPath $currentVerge)) { throw "当前配置缺少 verge.yaml，拒绝覆盖。" }
$groups = @(Get-ProxyGroupNames (Join-Path $configRoot "clash-verge.yaml"))
$selectedGroup = Select-ProxyGroup $groups $ProxyGroup
if (-not $selectedGroup) { throw "无法自动识别代理策略组。可用策略组: $($groups -join ', ')。请使用 -ProxyGroup 指定。" }
$selectedGeminiGroup = Resolve-RuleTarget $groups $GeminiGroup $selectedGroup "-GeminiGroup"
$selectedAcademicGroup = Resolve-RuleTarget $groups $AcademicGroup "DIRECT" "-AcademicGroup"
$selectedMicrosoftGroup = Resolve-RuleTarget $groups $MicrosoftGroup "DIRECT" "-MicrosoftGroup"
$selectedMicrosoftDownloadGroup = Resolve-RuleTarget $groups $MicrosoftDownloadGroup "DIRECT" "-MicrosoftDownloadGroup"
if ($TunMtu -gt 0 -and -not $Force) { Write-Warning "将显式设置 TUN MTU=$TunMtu；部署前应确认本机物理出口 MTU。" }
if ($Action -eq "IsolatedTest") { Show-Audit $app $configRoot }

$keepGeneratedFiles = $Action -eq "Generate"
if ($keepGeneratedFiles) {
    $staging = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $PSScriptRoot "LocalConfig" }
} else {
    $staging = Join-Path ([IO.Path]::GetTempPath()) ("clash-verge-codex-" + [guid]::NewGuid().ToString("N"))
}
$isolationFingerprint = Get-ConfigurationFingerprint $configRoot
try {
    $generatedFiles = New-LocalConfiguration $currentVerge $MergeTemplatePath $selectedGroup $selectedGeminiGroup $selectedAcademicGroup `
        $selectedMicrosoftGroup $selectedMicrosoftDownloadGroup $staging
    Test-RuleTargets $generatedFiles.Merge $groups
    if (-not $SkipOpenAiRules) {
        if (@(Test-DomainRouting $generatedFiles.Merge $OpenAiDomainsPath "OpenAI" $selectedGroup).Count -gt 0) {
            throw "生成配置的 OpenAI 路由校验失败。"
        }
    }
    if (-not $SkipGeminiRules) {
        if (@(Test-DomainRouting $generatedFiles.Merge $GeminiDomainsPath "Gemini" $selectedGeminiGroup).Count -gt 0) {
            throw "生成配置的 Gemini 路由校验失败。"
        }
    }
    if (-not $SkipAcademicRules) {
        if (@(Test-DomainRouting $generatedFiles.Merge $AcademicDomainsPath "Academic" $selectedAcademicGroup).Count -gt 0) {
            throw "生成配置的 Academic 路由校验失败。"
        }
    }
    if (-not $SkipMicrosoftRules) {
        if (@(Test-DomainRouting $generatedFiles.Merge $MicrosoftDomainsPath "Microsoft" $selectedMicrosoftGroup).Count -gt 0) {
            throw "生成配置的 Microsoft 控制链路校验失败。"
        }
        if (@(Test-DomainRouting $generatedFiles.Merge $MicrosoftDownloadDomainsPath "Microsoft Download" $selectedMicrosoftDownloadGroup).Count -gt 0) {
            throw "生成配置的 Microsoft 下载链路校验失败。"
        }
    }
    Test-IsolatedMergeSafety $generatedFiles.Merge
    Test-YamlWithMihomo $app.MihomoPath $generatedFiles.Merge
    Assert-ConfigurationFingerprintUnchanged $isolationFingerprint $configRoot
    Write-Host "[✓] 临时隔离预检通过，本机运行配置未发生变化。" -ForegroundColor Green
    if ($keepGeneratedFiles) {
        Write-Host "[✓] 已生成并验证本机配置，但没有部署: $staging" -ForegroundColor Green
        exit 0
    }
    if ($Action -eq "IsolatedTest") {
        Test-OpenAiConnectivity
        Test-GeminiConnectivity
        Test-MicrosoftConnectivity
        Test-AcademicConnectivity
        Assert-ConfigurationFingerprintUnchanged $isolationFingerprint $configRoot
        Write-Host "[✓] 隔离测试完成；临时文件将删除，本机配置没有部署或重载。" -ForegroundColor Green
        exit 0
    }
    $snapshot = $null
    Stop-ClashVerge
    try {
        $snapshot = New-DeploymentSnapshot $configRoot $app
        Install-FileAtomically $generatedFiles.Verge (Join-Path $configRoot "verge.yaml")
        Install-FileAtomically $generatedFiles.Merge (Join-Path $configRoot "profiles\Merge.yaml")
        Start-Process -FilePath $app.ExePath | Out-Null
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue)) { throw "客户端启动后未保持运行。" }
        $finalConfig = Join-Path $configRoot "clash-verge.yaml"
        if (Test-Path -LiteralPath $finalConfig) { Test-YamlWithMihomo $app.MihomoPath $finalConfig }
    } catch {
        $deploymentError = $_.Exception
        try {
            if ($snapshot) {
                Write-Warning "部署失败，正在自动恢复本次快照: $($deploymentError.Message)"
                Restore-Snapshot $configRoot $snapshot | Out-Null
            } else {
                Write-Warning "创建部署快照失败，未安装任何配置: $($deploymentError.Message)"
            }
        } catch {
            Write-Warning "自动恢复快照也失败，请保留现场并人工检查：$($_.Exception.Message)"
        } finally {
            Start-Process -FilePath $app.ExePath | Out-Null
        }
        throw $deploymentError
    }
    Write-Host "[✓] 本机适配配置已部署。快照: $snapshot" -ForegroundColor Green
    Write-Host "[✓] 使用的代理策略组: $selectedGroup" -ForegroundColor Green
    Write-Host "[✓] Gemini 策略组: $selectedGeminiGroup" -ForegroundColor Green
    Write-Host "[✓] 学术 PDF/CDN 出口: $selectedAcademicGroup" -ForegroundColor Green
    Write-Host "[✓] Microsoft 控制链路: $selectedMicrosoftGroup" -ForegroundColor Green
    Write-Host "[✓] Microsoft Store/Update 下载链路: $selectedMicrosoftDownloadGroup" -ForegroundColor Green
    $profilesPath = Join-Path $configRoot "profiles.yaml"
    if (-not (Test-Path -LiteralPath $profilesPath) -or
        ((Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8) -notmatch '(?m)^\s+merge\s*:\s*Merge\s*$')) {
        Write-Warning "配置文件已安装，但当前订阅尚未绑定 Merge。请在客户端为订阅选择 Merge 后刷新。"
    }
} finally {
    if (-not $keepGeneratedFiles -and (Test-Path -LiteralPath $staging)) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
