[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$McpOnly,
    [switch]$ForDebug,
    [switch]$NoReload,
    [switch]$Status,
    [ValidateRange(1024, 65535)][int]$Port = 8000
)

# Resolve paths from the script, so a terminal in another folder also works.
$action = if ($Status) { 'status' } elseif ($CheckOnly) { 'check' } else { 'start' }
& (Join-Path $PSScriptRoot 'scripts\windows-dev.ps1') -Action $action -Port $Port `
    -McpOnly:$McpOnly -ForDebug:$ForDebug -NoReload:$NoReload
exit $LASTEXITCODE
