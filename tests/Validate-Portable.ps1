#requires -Version 5.1
param([string]$InstallPath = (Join-Path $PSScriptRoot '..\..\clash-verge.exe'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$real = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$protected = @('verge.yaml', 'profiles.yaml', 'clash-verge.yaml', 'profiles\Merge.yaml', 'profiles\Script.js')
$before = @{}
foreach ($relative in $protected) {
    $path = Join-Path $real $relative
    $before[$relative] = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else { '<missing>' }
}

$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('clash-portability-' + [guid]::NewGuid().ToString('N'))))
try {
    $config = Join-Path $tempRoot 'config'
    $output = Join-Path $tempRoot 'output'
    New-Item -ItemType Directory -Path $config -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $config 'verge.yaml') -Value 'mixed_port: 7890' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $config 'profiles.yaml') -Value 'current: sample' -Encoding UTF8
    @'
proxy-groups:
  - name: Proxy A
    type: select
    proxies:
      - DIRECT
  - name: Gemini B
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,DIRECT
'@ | Set-Content -LiteralPath (Join-Path $config 'clash-verge.yaml') -Encoding UTF8

    & (Join-Path $repo 'Deploy-ClashVerge.ps1') -Action Generate -InstallPath $InstallPath `
        -ConfigDir $config -OutputDirectory $output -TargetSubscription Sample `
        -ProxyGroup 'Proxy A' -GeminiGroup 'Gemini B'
    if (-not (Test-Path -LiteralPath (Join-Path $output 'Script.js'))) { throw 'Script.js was not generated.' }

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js is required to validate generated Script.js.' }
    if ($node) {
        $generatedScript = Join-Path $output 'Script.js'
        & $node.Source --check $generatedScript
        if ($LASTEXITCODE -ne 0) {
            $number = 0
            Get-Content -LiteralPath $generatedScript | ForEach-Object { $number++; '{0,3}: {1}' -f $number, $_ } | Select-Object -First 18
            throw 'Generated JavaScript syntax failed.'
        }
        @'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const main = vm.runInNewContext(source + '\nmain');
function fixture() { return { 'proxy-groups': [{ name: 'Proxy A', type: 'select', proxies: ['DIRECT'] }, { name: 'Gemini B', type: 'select', proxies: ['DIRECT'] }], rules: ['MATCH,DIRECT'] }; }
const other = fixture();
if (main(other, 'Other') !== other || other.rules.length !== 1) throw Error('Other subscription changed');
const target = main(fixture(), 'Sample');
if (!target.rules.includes('DOMAIN-SUFFIX,github.com,Proxy A')) throw Error('Main group missing');
if (!target.rules.includes('DOMAIN-SUFFIX,google.com,Gemini B')) throw Error('Gemini group missing');
if (!target.rules.some(x => x.includes('windowsupdate.com,DIRECT'))) throw Error('Microsoft download group missing');
const missing = { 'proxy-groups': [{name:'Proxy A'}], rules:['MATCH,DIRECT'] };
if (main(missing, 'Sample').rules.length !== 1) throw Error('Missing group should leave config unchanged');
fs.writeFileSync(process.argv[3], JSON.stringify(target));
console.log('JavaScript routing and subscription isolation: OK');
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'check.js') -Encoding UTF8
        $targetConfig = Join-Path $tempRoot 'target.json'
        & $node.Source (Join-Path $tempRoot 'check.js') $generatedScript $targetConfig
        if ($LASTEXITCODE -ne 0) { throw 'Generated JavaScript behavior failed.' }
        $mihomo = Join-Path (Split-Path -Parent $InstallPath) 'verge-mihomo.exe'
        if (-not (Test-Path -LiteralPath $mihomo)) { throw 'verge-mihomo.exe is required.' }
        & $mihomo -t -f $targetConfig
        if ($LASTEXITCODE -ne 0) { throw 'Mihomo rejected the generated subscription rules.' }
    }
    Write-Host 'Portable generation and Mihomo validation: OK'
} finally {
    $changed = @()
    foreach ($relative in $protected) {
        $path = Join-Path $real $relative
        $after = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else { '<missing>' }
        if ($after -ne $before[$relative]) { $changed += $relative }
    }
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($tempRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    if ($changed.Count -gt 0) { throw "Protected running configuration changed: $($changed -join ', ')" }
    Write-Host 'Running configuration fingerprints unchanged.'
}
