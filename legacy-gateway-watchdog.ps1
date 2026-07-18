$ErrorActionPreference = 'Continue'

$hermesInstallRoot = Join-Path $env:LOCALAPPDATA 'hermes'
$hermesRoot = Join-Path $env:USERPROFILE '.hermes'
$env:HERMES_HOME = $hermesRoot
$nodeRoot = Join-Path $env:ProgramFiles 'nodejs'
if (Test-Path -LiteralPath (Join-Path $nodeRoot 'node.exe')) {
    $env:Path = "$nodeRoot;$env:Path"
}
$hermesAgentRoot = Join-Path $hermesInstallRoot 'hermes-agent'
$hermesPython = Join-Path $hermesAgentRoot 'venv\Scripts\python.exe'
$watchdogLog = Join-Path $hermesRoot 'logs\windows-gateway-watchdog.log'
$gatewayPort = 8642

# Only one watchdog may supervise the gateway. Multiple detached watchdogs
# otherwise race to launch gateways and create misleading port conflicts.
$watchdogMutex = [Threading.Mutex]::new($true, 'Local\HermesWhatsAppGatewayWatchdog', [ref]$createdNew)
if (-not $createdNew) { exit 0 }
$routerRoot = 'C:\Users\henry.000\workspace\LLMRouter'
$routerPython = Join-Path $routerRoot '.venv\Scripts\python.exe'
$routerConfig = Join-Path $routerRoot 'configs\henry_hybrid_openai_ollama.yaml'
$routerLog = Join-Path $routerRoot 'data\premium-router.stdout.log'
$routerErrorLog = Join-Path $routerRoot 'data\premium-router.stderr.log'
$bridgeRoot = 'C:\Users\henry.000\workspace\codex-bridge'
$bridgePython = Join-Path $bridgeRoot '.venv\Scripts\python.exe'
$bridgeLog = Join-Path $bridgeRoot 'debug\hermes-codex-bridge.stdout.log'
$bridgeErrorLog = Join-Path $bridgeRoot 'debug\hermes-codex-bridge.stderr.log'

function Write-WatchdogLog([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    try { Add-Content -LiteralPath $watchdogLog -Value $line -Encoding utf8 } catch { }
}

function Test-Listener([int]$Port) {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $wait = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $connected = $wait.AsyncWaitHandle.WaitOne(1000) -and $client.Connected
        $client.Close()
        return $connected
    } catch {
        return $false
    }
}

function Start-HiddenService(
    [string]$FilePath,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [string]$Stdout,
    [string]$Stderr
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Windows failed to start $FilePath" }
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return $process
}

function Ensure-PremiumBackends {
    if (-not (Test-Listener 9000)) {
        Write-WatchdogLog 'Codex bridge is not listening; starting it.'
        Start-Process -FilePath $bridgePython -ArgumentList @('-m','uvicorn','codex_bridge:app','--host','127.0.0.1','--port','9000') -WorkingDirectory $bridgeRoot -WindowStyle Hidden -RedirectStandardOutput $bridgeLog -RedirectStandardError $bridgeErrorLog
        Start-Sleep -Seconds 3
    }
    if (-not (Test-Listener 8000)) {
        Write-WatchdogLog 'LLMRouter is not listening; starting it.'
        Start-Process -FilePath $routerPython -ArgumentList @('-m','openclaw_router','--config',$routerConfig,'--host','127.0.0.1','--port','8000') -WorkingDirectory $routerRoot -WindowStyle Hidden -RedirectStandardOutput $routerLog -RedirectStandardError $routerErrorLog
        Start-Sleep -Seconds 4
    }
    if (-not (Test-Listener 9000) -or -not (Test-Listener 8000)) {
        Write-WatchdogLog "Premium backend readiness failed (bridge=$(Test-Listener 9000), router=$(Test-Listener 8000))."
        return $false
    }
    return $true
}

if (-not (Test-Path -LiteralPath $hermesPython)) {
    Write-WatchdogLog "FATAL: Hermes Python executable not found: $hermesPython"
    exit 2
}

Write-WatchdogLog "Watchdog started (PID=$PID)."

while ($true) {
    $null = Ensure-PremiumBackends

    if (Test-Listener $gatewayPort) {
        Start-Sleep -Seconds 15
        continue
    }

    Write-WatchdogLog 'Gateway is not listening; launching hermes gateway run.'
    try {
        # ProcessStartInfo.CreateNoWindow is stronger than Start-Process
        # -WindowStyle Hidden and prevents the gateway's child bridge from
        # inheriting or allocating a visible console window.
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $hermesPython
        $startInfo.Arguments = '-m hermes_cli.main gateway run'
        $startInfo.WorkingDirectory = $hermesAgentRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Windows failed to start the gateway process.'
        }

        # Native Windows startup may spend several minutes discovering plugins.
        # Allow up to five minutes before treating a live process as hung.
        $startupReady = $false
        for ($startupAttempt = 0; $startupAttempt -lt 75 -and -not $process.HasExited; $startupAttempt++) {
            Start-Sleep -Seconds 3
            if (Test-Listener $gatewayPort) {
                $startupReady = $true
                break
            }
        }
        if ($startupReady) {
            Write-WatchdogLog "Gateway started successfully (PID=$($process.Id))."
        } elseif ($process.HasExited) {
            Write-WatchdogLog "Gateway exited during startup (exit=$($process.ExitCode)). Retrying in 15 seconds."
        } else {
            Write-WatchdogLog "Gateway process PID=$($process.Id) did not become ready within 300 seconds; terminating for restart."
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        while (-not $process.HasExited) {
            $null = Ensure-PremiumBackends
            if (-not (Test-Listener $gatewayPort)) {
                Start-Sleep -Seconds 15
                if (-not (Test-Listener $gatewayPort) -and -not $process.HasExited) {
                    Write-WatchdogLog "Gateway process PID=$($process.Id) is alive but unresponsive; terminating for restart."
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    break
                }
            }
            Start-Sleep -Seconds 15
        }
        if ($process.HasExited) {
            Write-WatchdogLog "Gateway process exited (exit=$($process.ExitCode))."
        }
    } catch {
        Write-WatchdogLog "Gateway launch error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 15
}

