[CmdletBinding()]
param(
    [switch]$McpOnly,
    [ValidateRange(1024, 65535)][int]$Port = 8000
)

& (Join-Path $PSScriptRoot 'scripts\windows-dev.ps1') -Action stop -Port $Port -McpOnly:$McpOnly
exit $LASTEXITCODE
