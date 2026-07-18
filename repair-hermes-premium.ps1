$ErrorActionPreference = 'Stop'

$hermesInstallRoot = Join-Path $env:LOCALAPPDATA 'hermes'
$hermesHome = Join-Path $HOME '.hermes'
$hermesConfig = Join-Path $hermesHome 'config.yaml'
$legacyAppDataConfig = Join-Path $hermesInstallRoot 'config.yaml'
$legacyAgentConfig = Join-Path $hermesInstallRoot 'hermes-agent\config.yaml'
$hermesExe = Join-Path $hermesInstallRoot 'hermes-agent\apps\desktop\release\win-unpacked\Hermes.exe'
$hermesPython = Join-Path $hermesInstallRoot 'hermes-agent\venv\Scripts\python.exe'
$routerRoot = 'C:\Users\henry.000\workspace\LLMRouter'
$routerPython = Join-Path $routerRoot '.venv\Scripts\python.exe'
$routerConfig = Join-Path $routerRoot 'configs\henry_hybrid_openai_ollama.yaml'
$routerLog = Join-Path $routerRoot 'data\premium-router.stdout.log'
$routerErrorLog = Join-Path $routerRoot 'data\premium-router.stderr.log'
$codexBridgeRoot = 'C:\Users\henry.000\workspace\codex-bridge'
$codexBridgePython = Join-Path $codexBridgeRoot '.venv\Scripts\python.exe'
$codexBridgeLog = Join-Path $codexBridgeRoot 'debug\hermes-codex-bridge.stdout.log'
$codexBridgeErrorLog = Join-Path $codexBridgeRoot 'debug\hermes-codex-bridge.stderr.log'

Write-Host 'Hermes premium repair started.' -ForegroundColor Cyan
Write-Host 'Checking required files...'

foreach ($required in @($hermesConfig, $hermesExe, $hermesPython, $routerPython, $routerConfig, $codexBridgePython)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required path not found: $required"
    }
}

# Official native-Windows Hermes keeps all user data in %USERPROFILE%\.hermes.
# Pin every future terminal, desktop, and scheduled-task launch to that profile.
[Environment]::SetEnvironmentVariable('HERMES_HOME', $hermesHome, 'User')
$env:HERMES_HOME = $hermesHome
Write-Host "Hermes profile: $env:HERMES_HOME"

# Stop the watchdog first so it cannot respawn a gateway holding stale
# in-memory provider settings while configuration files are consolidated.
Stop-ScheduledTask -TaskName 'Hermes WhatsApp Gateway Watchdog' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'Hermes.exe' -or
    $_.CommandLine -match 'hermes_cli\.main\s+gateway\s+run' -or
    $_.CommandLine -match 'hermes-gateway-watchdog\.ps1'
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

Write-Host 'Azure credentials are not required for the Hermes Codex route.'

# Keep the bridge model-agnostic: Codex chooses its configured/default model.
# Upgrade the CLI first because the previously installed v0.143.0 could not
# run the user's current default model.
$npmCmd = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
if (-not (Test-Path -LiteralPath $npmCmd)) {
    throw "npm.cmd not found: $npmCmd"
}
Write-Host 'Updating Codex CLI so it can use the current account default model...'
& $npmCmd install --global '@openai/codex@latest'
if ($LASTEXITCODE -ne 0) {
    throw "Codex CLI update failed with exit code $LASTEXITCODE"
}
$codexArgs = 'exec --sandbox danger-full-access --skip-git-repo-check --'
[Environment]::SetEnvironmentVariable('CODEX_ARGS', $codexArgs, 'User')
$env:CODEX_ARGS = $codexArgs
Write-Host 'Configured the Hermes Codex bridge to use the Codex account default model.'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Write-Host 'Updating the live Hermes configuration...'
Copy-Item -LiteralPath $hermesConfig -Destination "$hermesConfig.backup-$stamp"
$lines = @(Get-Content -LiteralPath $hermesConfig)
$modelIndex = [Array]::IndexOf($lines, 'model:')
if ($modelIndex -lt 0) { throw "No model section found in $hermesConfig" }

$defaultIndex = $null
for ($i = $modelIndex + 1; $i -lt [Math]::Min($modelIndex + 20, $lines.Count); $i++) {
    if ($lines[$i] -match '^\S') { break }
    if ($lines[$i] -match '^\s+default:\s*') { $defaultIndex = $i; break }
}
if ($null -eq $defaultIndex) { throw "No default model setting found in $hermesConfig" }
$lines[$defaultIndex] = '  default: codex-premium'

# Session resets or interactive model switches can persist another provider.
# Restore every top-level connection field explicitly rather than changing
# only the model name.
$modelSettings = [ordered]@{
    provider = 'custom'
    base_url = 'http://127.0.0.1:8000/v1'
    api_key = ***MASKED***
    api_mode = 'chat_completions'
}
foreach ($entry in $modelSettings.GetEnumerator()) {
    $settingIndex = $null
    for ($i = $modelIndex + 1; $i -lt [Math]::Min($modelIndex + 25, $lines.Count); $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match "^\s+$($entry.Key)\s*:") { $settingIndex = $i; break }
    }
    $newLine = "  $($entry.Key): $($entry.Value)"
    if ($null -ne $settingIndex) {
        $lines[$settingIndex] = $newLine
    } else {
        $lines = @($lines[0..$defaultIndex]) + $newLine + @($lines[($defaultIndex + 1)..($lines.Count - 1)])
    }
}

# Hermes previously defaulted to 768 output tokens. That is too small for
# premium tool calls and causes finish_reason=length / truncated tool calls.
# Raise both supported output-limit keys in the top-level model section.
foreach ($setting in @('max_output_tokens', 'max_tokens')) {
    $settingIndex = $null
    for ($i = $modelIndex + 1; $i -lt [Math]::Min($modelIndex + 20, $lines.Count); $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match "^\s+$setting\s*:") { $settingIndex = $i; break }
    }
    if ($null -ne $settingIndex) {
        $lines[$settingIndex] = "  ${setting}: 8192"
    } else {
        $lines = @($lines[0..$defaultIndex]) + "  ${setting}: 8192" + @($lines[($defaultIndex + 1)..($lines.Count - 1)])
    }
}

$toolsetsIndex = [Array]::IndexOf($lines, 'toolsets:')
if ($toolsetsIndex -ge 0 -and $lines -notmatch '^\s*-\s*web\s*$') {
    $before = @($lines[0..$toolsetsIndex])
    $after = @($lines[($toolsetsIndex + 1)..($lines.Count - 1)])
    $lines = $before + '  - web' + $after
}
Set-Content -LiteralPath $hermesConfig -Value $lines -Encoding utf8

# Remove forbidden C0/C1 control bytes left by an earlier encoding conversion.
# They make PyYAML reject the entire file and silently fall back to defaults.
$yamlText = Get-Content -LiteralPath $hermesConfig -Raw
$yamlText = [regex]::Replace($yamlText, '[^\x09\x0A\x0D\x20-\x7E\u00A0-\uFFFF]', '')
Set-Content -LiteralPath $hermesConfig -Value $yamlText -Encoding utf8

& $hermesPython -c "import pathlib,yaml; p=pathlib.Path(r'$hermesConfig'); d=yaml.safe_load(p.read_text(encoding='utf-8-sig')); assert isinstance(d,dict) and isinstance(d.get('model'),dict); print('Hermes YAML parse: OK')"
if ($LASTEXITCODE -ne 0) {
    throw "Hermes YAML parser rejected the canonical configuration: $hermesConfig"
}

# Break any hard link created by an earlier repair so the canonical profile is
# once again an independent user-data file.
$independentConfig = Join-Path $hermesHome "config.canonical-$stamp.tmp"
Copy-Item -LiteralPath $hermesConfig -Destination $independentConfig
Remove-Item -LiteralPath $hermesConfig -Force
Move-Item -LiteralPath $independentConfig -Destination $hermesConfig

# Infrastructure directories must not contain competing user configurations.
foreach ($legacyConfig in @($legacyAppDataConfig, $legacyAgentConfig)) {
    if (Test-Path -LiteralPath $legacyConfig) {
        Copy-Item -LiteralPath $legacyConfig -Destination "$legacyConfig.retired-$stamp"
        Remove-Item -LiteralPath $legacyConfig -Force
        Write-Host "Removed non-primary Hermes configuration: $legacyConfig"
    }
}

$verifyText = Get-Content -LiteralPath $hermesConfig -Raw
$modelBlock = [regex]::Match($verifyText, '(?ms)^model:\s*\r?\n(?<body>(?:^[ \t]+.*(?:\r?\n|$))*)').Groups['body'].Value
if ($modelBlock -notmatch '(?m)^\s+provider:\s*custom\s*$' -or
    $modelBlock -notmatch '(?m)^\s+default:\s*codex-premium\s*$' -or
    $modelBlock -notmatch '(?m)^\s+base_url:\s*http://127\.0\.0\.1:8000/v1\s*$' -or
    $verifyText -match '(?i)azure-foundry') {
    throw "Canonical Hermes configuration verification failed: $hermesConfig"
}
Write-Host "Verified canonical Hermes configuration: $hermesConfig"

# Migrate the previously paired WhatsApp session into the canonical plugin
# layout. Copy the complete session directory because Signal keys and device
# state span many files, not only creds.json.
$whatsappTarget = Join-Path $hermesHome 'platforms\whatsapp\session'
$whatsappCandidates = @(
    (Join-Path $hermesInstallRoot 'platforms\whatsapp\session'),
    (Join-Path $hermesInstallRoot 'whatsapp\session'),
    (Join-Path $hermesHome 'whatsapp\session')
)
if (-not (Test-Path -LiteralPath (Join-Path $whatsappTarget 'creds.json'))) {
    $pairedSource = $whatsappCandidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'creds.json')
    } | Select-Object -First 1
    if ($pairedSource) {
        New-Item -ItemType Directory -Path $whatsappTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $pairedSource '*') -Destination $whatsappTarget -Recurse -Force
        Write-Host "Migrated WhatsApp pairing from: $pairedSource"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $whatsappTarget 'creds.json'))) {
    throw 'Existing WhatsApp pairing credentials were not found. Automatic gateway startup cannot continue until the account is paired.'
}
Write-Host "Verified WhatsApp pairing: $whatsappTarget"

$env:CODEX_BRIDGE_WORKDIR = 'C:\Users\henry.000\hermes-oracle-app'
Write-Host "Codex bridge workspace: $env:CODEX_BRIDGE_WORKDIR"
Write-Host 'Restarting the Codex premium bridge on port 9000...'
$bridgeListener = Get-NetTCPConnection -LocalPort 9000 -State Listen -ErrorAction SilentlyContinue
if ($bridgeListener) {
    $bridgeListener | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}
Start-Process -FilePath $codexBridgePython `
    -ArgumentList @('-m', 'uvicorn', 'codex_bridge:app', '--host', '127.0.0.1', '--port', '9000') `
    -WorkingDirectory $codexBridgeRoot -WindowStyle Hidden `
    -RedirectStandardOutput $codexBridgeLog -RedirectStandardError $codexBridgeErrorLog

$bridgeReady = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:9000/health' -TimeoutSec 2 | Out-Null
        $bridgeReady = $true
        break
    } catch { }
}
if (-not $bridgeReady) {
    throw "Codex bridge did not start. Check $codexBridgeErrorLog"
}

Write-Host 'Stopping the existing LLMRouter listener on port 8000...'
$listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $listener | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

$routerArgs = @(
    '-m', 'openclaw_router',
    '--config', $routerConfig,
    '--host', '127.0.0.1',
    '--port', '8000'
)
Start-Process -FilePath $routerPython -ArgumentList $routerArgs -WorkingDirectory $routerRoot `
    -WindowStyle Hidden -RedirectStandardOutput $routerLog -RedirectStandardError $routerErrorLog

Write-Host 'Waiting for LLMRouter to become ready...'
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8000/v1/models' -TimeoutSec 2 | Out-Null
        $ready = $true
        break
    } catch { }
}
if (-not $ready) {
    throw "LLMRouter did not start. Check $routerErrorLog"
}

$body = @{
    model = 'codex-premium'
    messages = @(@{ role = 'user'; content = 'Reply with exactly: CODEX_OK' })
    stream = $false
    max_tokens = 32
} | ConvertTo-Json -Depth 6

Write-Host 'Validating codex-premium with the Codex default model (this can take up to 90 seconds)...'
try {
    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:8000/v1/chat/completions' `
        -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 90
} catch {
    $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw "Premium validation failed: $detail. Check $routerErrorLog"
}

if ([string]::IsNullOrWhiteSpace($response.choices[0].message.content)) {
    throw 'Premium validation returned an empty response; Hermes was not restarted.'
}

Write-Host 'Premium validation passed. Preparing a clean Hermes desktop restart...'
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'Hermes.exe' -or
    $_.ExecutablePath -like "$hermesInstallRoot\*" -or
    $_.CommandLine -like "*$hermesInstallRoot*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

# The Electron desktop stores its last gateway session ID separately from the
# Hermes session database. After changing HERMES_HOME that ID points to a
# session that cannot exist in the new canonical profile, causing HTTP 404.
$desktopDataRoot = Join-Path $env:APPDATA 'Hermes'
foreach ($uiStateName in @('Local Storage', 'Session Storage')) {
    $uiStatePath = Join-Path $desktopDataRoot $uiStateName
    if (Test-Path -LiteralPath $uiStatePath) {
        Move-Item -LiteralPath $uiStatePath -Destination "$uiStatePath.stale-$stamp" -Force
        Write-Host "Cleared stale desktop session state: $uiStateName"
    }
}

$watchdogInstaller = Join-Path $PSScriptRoot 'install-hermes-gateway-watchdog.ps1'
if (Test-Path -LiteralPath $watchdogInstaller) {
    Write-Host 'Installing the hidden full-service Hermes watchdog...'
    & $watchdogInstaller
}

$gatewayReady = [bool](Get-NetTCPConnection -LocalPort 8642 -State Listen -ErrorAction SilentlyContinue)
if (-not $gatewayReady) {
    throw 'Hermes gateway is not ready; desktop was not launched.'
}
Write-Host 'Gateway is stable. Launching Hermes desktop...'
Start-Process -FilePath $hermesExe

Write-Host ''
Write-Host 'Repair complete.' -ForegroundColor Green
Write-Host 'Hermes default: codex-premium'
Write-Host 'Hermes provider: custom via http://127.0.0.1:8000/v1'
Write-Host 'Codex bridge model: Codex account default'
Write-Host "Premium validation: $($response.choices[0].message.content)"
Write-Host "Router log: $routerLog"
Write-Host "Router error log: $routerErrorLog"



