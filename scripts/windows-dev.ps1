[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'status', 'check')][string]$Action = 'start',
    [switch]$McpOnly,
    [switch]$ForDebug,
    [switch]$NoReload,
    [ValidateRange(1024, 65535)][int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonExe = Join-Path $projectRoot '.venv\Scripts\python.exe'
$logDir = Join-Path $projectRoot 'log'
$statePath = Join-Path $logDir 'windows-dev.json'
$state = @{ project_root = $projectRoot; services = @() }
$startedHere = @()
$lockStream = $null
$locationPushed = $false

function Test-Port([int]$ServicePort) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connection = $client.ConnectAsync('127.0.0.1', $ServicePort)
        if (-not $connection.Wait(500)) { return $false }
        return $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}

function Save-State {
    $json = $script:state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ProcessImage([int]$ServicePid) {
    # Limited-query access also works when WMI/Get-Process cannot show the path.
    if (-not ('MewHelpDevProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class MewHelpDevProcess {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    public static string ImagePath(int pid) {
        IntPtr handle = OpenProcess(0x1000, false, pid);
        if (handle == IntPtr.Zero) return null;
        try {
            var path = new StringBuilder(32768);
            uint size = (uint)path.Capacity;
            return QueryFullProcessImageName(handle, 0, path, ref size) ? path.ToString() : null;
        } finally { CloseHandle(handle); }
    }
    public static void StopVerified(int pid, string expectedPath, long expectedTicks) {
        IntPtr handle = OpenProcess(0x1001, false, pid);
        if (handle == IntPtr.Zero) {
            int error = Marshal.GetLastWin32Error();
            if (error == 87) return; // Process already exited.
            throw new Win32Exception(error);
        }
        try {
            var path = new StringBuilder(32768);
            uint size = (uint)path.Capacity;
            long created, exited, kernel, user;
            if (!GetProcessTimes(handle, out created, out exited, out kernel, out user))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (DateTime.FromFileTimeUtc(created).Ticks != expectedTicks)
                throw new InvalidOperationException("Process identity changed; shutdown cancelled.");
            if (exited != 0) return;
            if (!QueryFullProcessImageName(handle, 0, path, ref size)) {
                int error = Marshal.GetLastWin32Error();
                if (GetProcessTimes(handle, out created, out exited, out kernel, out user) && exited != 0) return;
                throw new Win32Exception(error);
            }
            if (!String.Equals(path.ToString(), expectedPath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Process identity changed; shutdown cancelled.");
            if (!TerminateProcess(handle, 1)) {
                int error = Marshal.GetLastWin32Error();
                // A child may exit naturally after its supervisor is stopped.
                if (!GetProcessTimes(handle, out created, out exited, out kernel, out user) || exited == 0)
                    throw new Win32Exception(error);
            }
        } finally { CloseHandle(handle); }
    }
}
'@
    }
    return [MewHelpDevProcess]::ImagePath($ServicePid)
}

function Test-ManagedProcess($Record) {
    # PID reuse is possible: require both the executable and original creation time.
    $proc = Get-Process -Id $Record.pid -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    try {
        return ((Get-ProcessImage $Record.pid) -eq $pythonExe -and
            $proc.StartTime.ToUniversalTime().Ticks.ToString() -eq $Record.started_ticks)
    } catch { return $false }
}

function Stop-ManagedProcess($Record) {
    if (-not (Test-ManagedProcess $Record)) {
        Write-Host "[SKIP] $($Record.name): original process is gone or cannot be verified."
        return
    }
    # Snapshot descendants before stopping the supervisor so a reloader cannot
    # bring its worker back. Verify each PID again through the same native handle.
    $snapshot = @(Get-CimInstance Win32_Process)
    $tree = @(@{ pid = $Record.pid; image = $pythonExe; started_ticks = $Record.started_ticks })
    $seen = @{ ([string]$Record.pid) = $true }
    for ($index = 0; $index -lt $tree.Count; $index++) {
        $parent = $tree[$index]
        foreach ($child in @($snapshot | Where-Object { $_.ParentProcessId -eq $parent.pid })) {
            if ($seen.ContainsKey([string]$child.ProcessId)) { continue }
            $proc = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $ticks = $proc.StartTime.ToUniversalTime().Ticks
            if ($ticks -lt [long]$parent.started_ticks) { continue }
            $image = Get-ProcessImage $child.ProcessId
            if (-not $image) { throw "Cannot verify child PID $($child.ProcessId); shutdown cancelled." }
            $tree += @{ pid = $child.ProcessId; image = $image; started_ticks = $ticks.ToString() }
            $seen[[string]$child.ProcessId] = $true
        }
    }
    foreach ($item in $tree) {
        [MewHelpDevProcess]::StopVerified($item.pid, $item.image, [long]$item.started_ticks)
    }
    Write-Host "[STOP] $($Record.name)"
}

function Test-Service([string]$Service, [int]$ServicePort) {
    & $pythonExe -X utf8 scripts/check_dev.py probe --service $Service --port $ServicePort 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Stop-ExistingApplication([int]$ServicePort) {
    if (-not (Test-Port $ServicePort)) { return }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $ServicePort -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    if (-not $listeners.Count) { throw "Cannot identify the listener on port $ServicePort. No process was stopped." }

    # A healthy page matching this checkout can identify a manual launch even
    # when Windows hides its command line. Never identify it from a port alone.
    $pageMatches = $false
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$ServicePort/" -TimeoutSec 3
        $pageMatches = $response.Content -eq [System.IO.File]::ReadAllText((Join-Path $projectRoot 'app\static\index.html'))
    } catch { }

    $roots = @{}
    foreach ($listenerId in $listeners) {
        $node = Get-CimInstance Win32_Process -Filter "ProcessId = $listenerId" -ErrorAction SilentlyContinue
        $rootNode = $null
        $seen = @{}
        # Follow Python launchers/reloaders up to this checkout's virtualenv.
        # Do not climb into a terminal, VS Code or an unrelated supervisor.
        for ($depth = 0; $node -and $depth -lt 12; $depth++) {
            if ($seen.ContainsKey([string]$node.ProcessId)) { break }
            $seen[[string]$node.ProcessId] = $true
            $image = Get-ProcessImage $node.ProcessId
            if (-not $image -or [System.IO.Path]::GetFileName($image) -notin @('python.exe', 'pythonw.exe')) { break }
            if ($image -eq $pythonExe) { $rootNode = $node }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($node.ParentProcessId)" -ErrorAction SilentlyContinue
            if (-not $parent -or $parent.CreationDate -gt $node.CreationDate) { break }
            $node = $parent
        }
        if (-not $rootNode) { throw "Port $ServicePort is not owned by this project's Python environment. No process was stopped." }
        $proc = Get-Process -Id $rootNode.ProcessId -ErrorAction Stop
        $ticks = $proc.StartTime.ToUniversalTime().Ticks.ToString()
        $recorded = @($script:state.services | Where-Object {
            $_.name -eq "app-$ServicePort" -and $_.pid -eq $proc.Id -and $_.started_ticks -eq $ticks
        }).Count -gt 0
        $commandMatches = $rootNode.CommandLine -match '(?i)(?:^|\s)-m\s+uvicorn\s+app\.main:app(?:\s|$)'
        if (-not $recorded -and -not $commandMatches -and -not $pageMatches) {
            throw "Port $ServicePort is not the MewHelp application. No process was stopped."
        }
        $roots[[string]$proc.Id] = @{ name = "app-$ServicePort"; pid = $proc.Id; started_ticks = $ticks }
    }
    # Resolve every listener before stopping any of them, and verify identity
    # again in Stop-ManagedProcess to guard against stale/reused PIDs.
    foreach ($record in $roots.Values) {
        Write-Host "[RESTART] Port ${ServicePort}: stopping previous MewHelp application (PID $($record.pid))."
        Stop-ManagedProcess $record
        $script:state.services = @($script:state.services | Where-Object { $_.pid -ne $record.pid })
    }
    Save-State
    $deadline = (Get-Date).AddSeconds(10)
    while ((Test-Port $ServicePort) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (Test-Port $ServicePort) { throw "Port $ServicePort was not released. Check the previous application's permissions or reload supervisor." }
    Write-Host "[FREE] Port $ServicePort is ready for a fresh application."
}

function Start-ServiceProcess([string]$Name, [string]$Service, [int]$ServicePort, [string[]]$PythonArgs) {
    if (Test-Port $ServicePort) {
        if (-not (Test-Service $Service $ServicePort)) {
            throw "Port $ServicePort is occupied by an unexpected or unready service. Nothing on this port was stopped."
        }
        $owned = @($script:state.services | Where-Object { $_.name -eq $Name -and (Test-ManagedProcess $_) })
        $kind = if ($owned.Count) { 'managed' } else { 'existing; stop script will leave it running' }
        Write-Host "[REUSE] $Name :$ServicePort ($kind)"
        return
    }
    foreach ($record in @($script:state.services | Where-Object { $_.name -eq $Name })) {
        if (Test-ManagedProcess $record) { throw "$Name is recorded but not ready. Run stop.ps1 first and check its log." }
    }
    $script:state.services = @($script:state.services | Where-Object { $_.name -ne $Name })
    $oldPort = $env:PORT
    try {
        if ($Service -ne 'app') { $env:PORT = [string]$ServicePort }
        $proc = Start-Process -FilePath $pythonExe -ArgumentList $PythonArgs -WorkingDirectory $projectRoot `
            -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir "$Name.stdout.log") `
            -RedirectStandardError (Join-Path $logDir "$Name.stderr.log") -PassThru
    } finally { $env:PORT = $oldPort }
    $record = @{ name = $Name; pid = $proc.Id; port = $ServicePort; started_ticks = $proc.StartTime.ToUniversalTime().Ticks.ToString() }
    $script:startedHere += $record
    $script:state.services += $record
    Save-State
    $deadline = (Get-Date).AddSeconds(75)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ManagedProcess $record)) { throw "$Name exited early. See log\$Name.stderr.log." }
        if ((Test-Port $ServicePort) -and (Test-Service $Service $ServicePort)) {
            Write-Host "[READY] $Name :$ServicePort"
            return
        }
        Start-Sleep -Milliseconds 400
    }
    throw "$Name did not become ready. See log\$Name.stderr.log."
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This entry point is for Windows.' }
    if (-not (Test-Path -LiteralPath $pythonExe)) { throw 'Missing .venv\Scripts\python.exe. Run uv sync --python 3.12 first.' }
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $env:PYTHONUTF8 = '1'
    $env:PYTHONUNBUFFERED = '1'
    Push-Location -LiteralPath $projectRoot
    $locationPushed = $true
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    try {
        $lockStream = [System.IO.File]::Open((Join-Path $logDir 'windows-dev.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another start/stop command is running. Wait for it to finish.' }
    if (Test-Path -LiteralPath $statePath) {
        $loaded = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.project_root -ne $projectRoot) { throw 'Runtime state belongs to another project folder.' }
        $state.services = @($loaded.services)
    }

    if ($Action -eq 'stop') {
        $targets = @($state.services | Where-Object { $_.name -eq "app-$Port" -or $_.name -in @('mcp-logistics', 'mcp-aftersales') })
        if ($McpOnly) { $targets = @($targets | Where-Object { $_.name -like 'mcp-*' }) }
        foreach ($record in $targets) { Stop-ManagedProcess $record }
        $state.services = @($state.services | Where-Object { $targets -notcontains $_ })
        Save-State
        Write-Host '[OK] Only processes recorded by these scripts were considered. MySQL and the VM are unchanged.'
    } else {
        $configJson = & $pythonExe -X utf8 scripts/check_dev.py config
        if ($LASTEXITCODE -ne 0) { throw 'Configuration check failed.' }
        $ports = ($configJson -join "`n") | ConvertFrom-Json
        if ($Port -in @($ports.logistics, $ports.aftersales)) { throw 'The application port must differ from the MCP ports.' }
        if ($Action -eq 'status') {
            foreach ($service in @(@('app', $Port), @('logistics', $ports.logistics), @('aftersales', $ports.aftersales))) {
                $status = if (Test-Port $service[1]) { 'LISTENING' } else { 'STOPPED' }
                Write-Host ("{0,-12} :{1} {2}" -f $service[0], $service[1], $status)
            }
        } else {
            & $pythonExe -X utf8 scripts/check_dev.py check
            if ($LASTEXITCODE -ne 0) { throw 'Dependencies are not ready. Follow the message above and retry.' }
            if ($Action -eq 'start') {
                if ($ForDebug -or -not $McpOnly) { Stop-ExistingApplication $Port }
                Start-ServiceProcess 'mcp-logistics' 'logistics' $ports.logistics @('-X', 'utf8', 'mcp_servers/logistics_server.py')
                Start-ServiceProcess 'mcp-aftersales' 'aftersales' $ports.aftersales @('-X', 'utf8', 'mcp_servers/aftersales_server.py')
                if (-not $McpOnly -and -not $ForDebug) {
                    $appArgs = @('-X', 'utf8', '-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', [string]$Port)
                    if (-not $NoReload) { $appArgs += @('--reload', '--reload-dir', 'app') }
                    Start-ServiceProcess "app-$Port" 'app' $Port $appArgs
                    Write-Host "[OK] Open http://127.0.0.1:$Port"
                } else { Write-Host '[OK] MCP services are ready. VS Code can now launch the application.' }
                Write-Host "[LOG] $logDir"
            }
        }
    }
} catch {
    # On partial startup failure, roll back only children created by this invocation.
    foreach ($record in $startedHere) {
        try {
            Stop-ManagedProcess $record
            $state.services = @($state.services | Where-Object { $_.pid -ne $record.pid })
        } catch { Write-Warning $_.Exception.Message }
    }
    if ($startedHere.Count) { Save-State }
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    if ($locationPushed) { Pop-Location }
}
exit 0
