<#
.SYNOPSIS
  Copy the plugin package into Substance Designer's sduserplugins folder.

.DESCRIPTION
  Deploys the whole plugin/ package (not single files) as sd_mcp_plugin, after
  backing up the current one OUTSIDE sduserplugins (SD would load a backup kept
  inside it). SD loads plugins at startup: restart SD afterwards.

.PARAMETER Target
  sduserplugins folder. Default: Documents\Adobe\Adobe Substance 3D Designer\python\sduserplugins

.PARAMETER Force
  Overwrite without asking.
#>
param(
    [string]$Target = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Adobe\Adobe Substance 3D Designer\python\sduserplugins'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'plugin'
$dest = Join-Path $Target 'sd_mcp_plugin'
$backupRoot = Join-Path (Split-Path -Parent $Target) 'sduserplugins_backup'

if (-not (Test-Path (Join-Path $src '__init__.py'))) { throw "Not a plugin package: $src" }
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target | Out-Null }

if (Test-Path $dest) {
    if (-not $Force) {
        $a = Read-Host "Replace existing $dest ? (y/N)"
        if ($a -notmatch '^[yY]') { Write-Host 'Aborted.'; exit 1 }
    }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $bak = Join-Path $backupRoot ('sd_mcp_plugin_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item -Recurse -Force $dest $bak
    Write-Host "Backup: $bak"
    Remove-Item -Recurse -Force $dest
}

New-Item -ItemType Directory -Path $dest | Out-Null
Get-ChildItem -Path $src -Filter '*.py' | Copy-Item -Destination $dest
Write-Host ("Deployed {0} files to {1}" -f (Get-ChildItem $dest -Filter '*.py').Count, $dest)
Write-Host 'Restart Substance Designer to load the new plugin, then call get_scene_info.'
