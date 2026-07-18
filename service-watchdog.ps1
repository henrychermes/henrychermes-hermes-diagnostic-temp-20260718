$ErrorActionPreference = "Continue"

$OllamaHealth = "http://127.0.0.1:11434/api/tags"
$CodexBridgeHealth = "http://127.0.0.1:8999/health"
$LLMRouterHealth = "http://127.0.0.1:8000/health"

$CodexBridgeDir = "C:\Users\henry.000\workspace\codex-bridge"
$CodexBridgePython = "C:\Users\henry.000\workspace\codex-bridge\.venv\Scripts\python.exe"
$CodexCmd = "C:\Users\henry.000\AppData\Roaming\npm\codex.cmd"

$LLMRouterDir = "C:\Users\henry.000\workspace\LLMRouter"
$LLMRouterExe = "C:\Users\henry.000\AppData\Local\Programs\Python\Python312\Scripts\llmrouter.exe"
$LLMRouterConfig = "C:\Users\henry.000\workspace\LLMRouter\configs\henry_hybrid_openai_ollama.yaml"

function Write-ServiceLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path "C:\Hermes-RouterServices\logs\watchdog.log" -Value "[$timestamp] $Message"
}

function Test-Endpoint {
    param([string]$Url)
    try {
        Invoke-RestMethod -Uri $Url -TimeoutSec 8 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-PortProcessIds {
    param([int]$Port)
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq "Listen" -or $_.State -eq "Established" } |
        Select-Object -ExpandProperty OwningProcess -Unique
}

function Stop-PortProcess {
    param(
        [int]$Port,
        [string]$Name
    )

    $pids = Get-PortProcessIds -Port $Port

    foreach ($procId in $pids) {
        if ($procId -and $procId -ne 0) {
            try {
                Write-ServiceLog "Stopping stale $Name process on port $Port. PID: $procId"
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            } catch {
                Write-ServiceLog "Failed to stop $Name PID $procId. $($_.Exception.Message)"
            }
        }
    }
}

function Start-HiddenProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory
    )

    $stdout = "C:\Hermes-RouterServices\logs\$Name.out.log"
    $stderr = "C:\Hermes-RouterServices\logs\$Name.err.log"

    Write-ServiceLog "Starting $Name"

    Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
}

function Ensure-Ollama {
    if (Test-Endpoint $OllamaHealth) {
        return
    }

    Write-ServiceLog "Ollama is not reachable. Starting Ollama."

    $ollamaCmd = $null

    $cmd = Get-Command "ollama.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        $ollamaCmd = $cmd.Source
    }

    if (-not $ollamaCmd) {
        $possible = @(
            "C:\Users\henry.000\AppData\Local\Programs\Ollama\ollama.exe",
            "C:\Program Files\Ollama\ollama.exe"
        )

        foreach ($path in $possible) {
            if (Test-Path $path) {
                $ollamaCmd = $path
                break
            }
        }
    }

    if (-not $ollamaCmd) {
        Write-ServiceLog "Could not find ollama.exe"
        return
    }

    Start-HiddenProcess `
        -Name "ollama" `
        -FilePath $ollamaCmd `
        -ArgumentList @("serve") `
        -WorkingDirectory "C:\Users\henry.000\workspace"

    Start-Sleep -Seconds 10
}

function Ensure-CodexBridge {
    if (Test-Endpoint $CodexBridgeHealth) {
        return
    }

    Write-ServiceLog "Codex bridge is not reachable. Restarting."

    Stop-PortProcess -Port 8999 -Name "codex-bridge"

    if (-not (Test-Path $CodexBridgePython)) {
        Write-ServiceLog "Missing Codex bridge Python: $CodexBridgePython"
        return
    }

    if (-not (Test-Path $CodexCmd)) {
        Write-ServiceLog "Missing Codex command: $CodexCmd"
        return
    }

    $env:CODEX_CMD = $CodexCmd
    $env:CODEX_ARGS = "exec --skip-git-repo-check --"
    $env:CODEX_TIMEOUT_SECONDS = "600"
    $env:CODEX_BRIDGE_WORKDIR = "C:\Users\henry.000\workspace\codex-bridge\workdir"

    Start-HiddenProcess `
        -Name "codex-bridge" `
        -FilePath $CodexBridgePython `
        -ArgumentList @("-m", "uvicorn", "codex_bridge:app", "--host", "127.0.0.1", "--port", "8999") `
        -WorkingDirectory $CodexBridgeDir

    Start-Sleep -Seconds 10
}

function Ensure-LLMRouter {
    if (Test-Endpoint $LLMRouterHealth) {
        return
    }

    Write-ServiceLog "LLMRouter is not reachable. Restarting."

    Stop-PortProcess -Port 8000 -Name "llmrouter"

    if (-not (Test-Path $LLMRouterExe)) {
        Write-ServiceLog "Missing LLMRouter executable: $LLMRouterExe"
        return
    }

    if (-not (Test-Path $LLMRouterConfig)) {
        Write-ServiceLog "Missing LLMRouter config: $LLMRouterConfig"
        return
    }

    Start-HiddenProcess `
        -Name "llmrouter" `
        -FilePath $LLMRouterExe `
        -ArgumentList @("serve", "--config", $LLMRouterConfig) `
        -WorkingDirectory $LLMRouterDir

    Start-Sleep -Seconds 10
}

Write-ServiceLog "Watchdog started."

while ($true) {
    Ensure-Ollama
    Ensure-CodexBridge
    Ensure-LLMRouter

    Start-Sleep -Seconds 60
}



