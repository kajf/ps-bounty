# Local-only module search-order fixture.
# Demonstrates expected PSModulePath precedence; not a vulnerability by itself.
[CmdletBinding()]
param(
    [string]$Root = (Join-Path ([System.IO.Path]::GetTempPath()) ("ps-module-shadow-" + [System.IO.Path]::GetRandomFileName()))
)

$ErrorActionPreference = 'Stop'
$moduleName = 'ShadowAuditModule'
$attackerRoot = Join-Path $Root 'attacker'
$trustedRoot = Join-Path $Root 'trusted'
$attackerModule = Join-Path $attackerRoot $moduleName
$trustedModule = Join-Path $trustedRoot $moduleName
New-Item -ItemType Directory -Path $attackerModule, $trustedModule -Force | Out-Null
@"
function Invoke-ShadowAudit { 'attacker-path' }
Export-ModuleMember -Function Invoke-ShadowAudit
"@ | Set-Content -LiteralPath (Join-Path $attackerModule "$moduleName.psm1") -Encoding utf8
@"
function Invoke-ShadowAudit { 'trusted-path' }
Export-ModuleMember -Function Invoke-ShadowAudit
"@ | Set-Content -LiteralPath (Join-Path $trustedModule "$moduleName.psm1") -Encoding utf8

$oldPath = $env:PSModulePath
try {
    $env:PSModulePath = $attackerRoot + [System.IO.Path]::PathSeparator + $trustedRoot
    Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
    $result = Invoke-ShadowAudit
    [pscustomobject]@{
        Root = $Root
        PSModulePath = $env:PSModulePath
        Result = $result
        LoadedPath = (Get-Module $moduleName).Path
        Classification = 'Expected search-order behavior; requires attacker control of an earlier PSModulePath entry.'
    }
}
finally {
    $env:PSModulePath = $oldPath
    Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
}
