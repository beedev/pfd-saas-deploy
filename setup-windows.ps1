# pfd-saas - set up (or upgrade) the app on a Windows PC, from nothing.
#
#   In PowerShell (no admin needed to start; Windows asks when it must):
#     irm https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/setup-windows.ps1 | iex
#   or, after downloading the file:
#     powershell -ExecutionPolicy Bypass -File setup-windows.ps1
#
# Windows counterpart of setup-mac.sh, published the same way (CI copies it to
# the PUBLIC repo beedev/pfd-saas-deploy after each image build). Written for
# Windows PowerShell 5.1, which every Windows 10 / 11 PC has. Keep this file
# ASCII-only: 5.1 reads a script without a BOM as ANSI, and non-ASCII
# characters there can break parsing.
#
# What it does:
#   1. WSL 2 + Docker Desktop. Docker on Windows runs Linux containers inside
#      WSL 2. If WSL is missing it installs it (one admin prompt) and asks you
#      to RESTART and run this again - the second run continues. Docker
#      Desktop comes from winget, else Docker's own installer.
#   2. Pulls the image. Anonymous first (the package is public). If a saved
#      GHCR login is refused it logs out and retries anonymously; only then
#      does it ask for a GitHub token. The real docker error is always shown.
#   3. (Re)creates the container with --restart unless-stopped on the
#      persistent volume. The volume is NEVER removed: re-running = upgrade.
#   4. Waits for /api/health.
#   5. First install only: creates the Personal account, switches on the
#      Transformation tracker, saves an OpenAI key if you paste one.
#   6. Keeps it alive: Docker Desktop starts at sign-in (its own setting), a
#      watchdog Scheduled Task every 5 min (windows/watchdog.ps1) and a monthly
#      DB backup task (windows/backup.ps1, 1st at 03:00, runs late if the PC
#      was off, newest 12 kept in %USERPROFILE%\pfd-backups).
#   7. Opens the browser.
#
# Telegram is not set up (a second instance on the same bot would steal the
# prod bot's messages).
#
# Optional environment overrides (set before running, e.g. $env:PORT = 3001):
#   PORT=3000  CONTAINER_NAME=pfd-saas  VOLUME_NAME=pfd_saas_data
#   IMAGE=ghcr.io/beedev/pfd-saas:latest  GHCR_USER=beedev
#   NO_PULL=1         use an image already on this machine (testing)
#   SKIP_SETUP=1      skip step 5
#   SKIP_OPENAI=1     don't ask for an OpenAI key in step 5
#   SKIP_ALWAYS_ON=1  skip step 6
#   NO_OPEN=1         don't open the browser at the end
#   PFD_HOME=%USERPROFILE%\pfd-watchdog
#   PFD_TEST_NON_WINDOWS=1  run on macOS/Linux pwsh for testing: skips the
#                     Windows-only parts (WSL/Docker install, Scheduled Tasks)
#                     and starts the container with DISABLE_CRON=true

$ErrorActionPreference = 'Stop'

function Get-Setting([string]$Name, [string]$Default) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($v)) { return $Default } else { return $v }
}

$Port          = Get-Setting 'PORT' '3000'
$ContainerName = Get-Setting 'CONTAINER_NAME' 'pfd-saas'
$VolumeName    = Get-Setting 'VOLUME_NAME' 'pfd_saas_data'
$Image         = Get-Setting 'IMAGE' 'ghcr.io/beedev/pfd-saas:latest'
$GhcrUser      = Get-Setting 'GHCR_USER' 'beedev'
$Url           = "http://localhost:$Port"
# The script's own calls go to 127.0.0.1, where Docker publishes the port.
# `localhost` can resolve to IPv6 ::1 first and reach a different program
# listening only there (found while testing: another dev server on ::1).
$ApiBase       = "http://127.0.0.1:$Port"
$PfdHome       = Get-Setting 'PFD_HOME' (Join-Path $HOME 'pfd-watchdog')
$DeployRaw     = (Get-Setting 'PFD_DEPLOY_RAW' 'https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main') + '/windows'
$TestMode      = -not [string]::IsNullOrEmpty($env:PFD_TEST_NON_WINDOWS)
$OnWindows     = $env:OS -eq 'Windows_NT'
$DockerWaitSec = 180
$HealthWaitSec = 180

# PowerShell 5.1 may default to old TLS versions that GitHub and Docker refuse.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Step([string]$n, [string]$text) { Write-Host ''; Write-Host "[$n] " -ForegroundColor Blue -NoNewline; Write-Host $text }
function Ok([string]$text)   { Write-Host '  OK  ' -ForegroundColor Green -NoNewline; Write-Host $text }
function Warn([string]$text) { Write-Host '  !!  ' -ForegroundColor Yellow -NoNewline; Write-Host $text }
# throw, not exit: under `irm | iex`, exit would close the user's PowerShell window.
function Fail([string]$text) { Write-Host '  XX  ' -ForegroundColor Red -NoNewline; Write-Host $text; throw "pfd-saas setup stopped: $text" }

# Run a native command, capture all output, never throw on a non-zero exit.
function Invoke-Native([string]$exe, [string[]]$arguments) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe @arguments 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out.Trim() }
}
function Test-DockerEngine { (Invoke-Native 'docker' @('info', '--format', '{{.ServerVersion}}')).Code -eq 0 }

# ---- 1. WSL 2 + Docker Desktop ---------------------------------------------
Step '1/7' 'WSL 2 and Docker Desktop'
if (-not $OnWindows -and -not $TestMode) { Fail 'This script is for Windows. On a Mac use setup-mac.sh; on Linux use install.sh.' }

# ProgramFiles exists only on Windows (test mode runs elsewhere).
$DockerDir = if ($OnWindows) { Join-Path $env:ProgramFiles 'Docker\Docker' } else { '' }
$DockerExe = if ($OnWindows) { Join-Path $DockerDir 'Docker Desktop.exe' } else { '' }
if ($OnWindows) {
  # A fresh install may not have put the CLI on PATH for this session yet.
  $env:Path = $env:Path + ';' + (Join-Path $DockerDir 'resources\bin')

  if ((Invoke-Native 'wsl.exe' @('--status')).Code -ne 0) {
    Warn 'WSL 2 is not installed. Docker Desktop needs it to run Linux containers.'
    Write-Host '  Installing WSL - Windows will ask for permission (admin).'
    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) { Fail "WSL install failed (exit $($p.ExitCode)). Run 'wsl --install' in an admin PowerShell, restart, then run this again." }
    Write-Host ''
    Write-Host '  WSL is installed. RESTART this PC, then run this script again - it continues from here.' -ForegroundColor Yellow
    return
  }
  Ok 'WSL 2 is installed'

  if (-not (Test-Path $DockerExe)) {
    $installed = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Write-Host '  Installing Docker Desktop with winget (~600 MB; Windows asks for admin once)...'
      $r = Invoke-Native 'winget' @('install', '-e', '--id', 'Docker.DockerDesktop', '--accept-package-agreements', '--accept-source-agreements', '--silent')
      $installed = (Test-Path $DockerExe)
      if (-not $installed) { Warn "winget did not finish the install: $($r.Output)" }
    }
    if (-not $installed) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
      $setup = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
      Write-Host "  Downloading Docker Desktop installer ($arch, ~600 MB)..."
      Invoke-WebRequest -UseBasicParsing -Uri "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe" -OutFile $setup
      Write-Host '  Installing - Windows will ask for permission (admin).'
      $p = Start-Process -FilePath $setup -ArgumentList 'install', '--quiet', '--accept-license', '--backend=wsl-2' -Verb RunAs -Wait -PassThru
      Remove-Item $setup -ErrorAction SilentlyContinue
      if ($p.ExitCode -ne 0 -or -not (Test-Path $DockerExe)) { Fail "Docker Desktop install failed (exit $($p.ExitCode))." }
    }
    Ok 'Docker Desktop installed'
    Warn 'If Docker does not start below, SIGN OUT of Windows and back in (the installer added you to the docker-users group), then run this again.'
  } else {
    Ok 'Docker Desktop already installed'
  }

  if (-not (Test-DockerEngine)) {
    Start-Process -FilePath $DockerExe
    Write-Host "  Starting Docker (up to ${DockerWaitSec}s; accept Docker's terms if its window asks)" -NoNewline
    $up = $false
    for ($i = 0; $i -lt $DockerWaitSec; $i += 2) {
      if (Test-DockerEngine) { $up = $true; break }
      Write-Host '.' -NoNewline; Start-Sleep -Seconds 2
    }
    Write-Host ''
    if (-not $up) { Fail 'Docker did not start. Open Docker Desktop, finish its first-run screens (or sign out and in), then run this again.' }
  }
} elseif (-not (Test-DockerEngine)) {
  Fail 'Test mode: Docker is not running on this machine.'
}
Ok 'Docker engine is running'

# ---- 2. Image --------------------------------------------------------------
Step '2/7' "Image $Image"
if ($env:NO_PULL) {
  if ((Invoke-Native 'docker' @('image', 'inspect', $Image)).Code -ne 0) { Fail "NO_PULL is set but $Image is not on this machine." }
  Ok 'Using the local image (NO_PULL)'
} else {
  $pull = Invoke-Native 'docker' @('pull', '-q', $Image)
  if ($pull.Code -ne 0 -and $pull.Output -match 'unauthorized|denied') {
    # The package is public: a refusal usually means an old saved GHCR login
    # (expired token) is being sent. Drop it and try anonymously first.
    Warn 'GHCR refused the saved login - logging out of ghcr.io and retrying anonymously.'
    Invoke-Native 'docker' @('logout', 'ghcr.io') | Out-Null
    $pull = Invoke-Native 'docker' @('pull', '-q', $Image)
  }
  if ($pull.Code -ne 0 -and $pull.Output -match 'unauthorized|denied') {
    Warn 'GHCR still refuses. A GitHub token with the read:packages scope is needed'
    Write-Host '  (github.com -> Settings -> Developer settings -> Personal access tokens).'
    $sec = Read-Host "  GitHub token for $GhcrUser" -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ([string]::IsNullOrEmpty($token)) { Fail 'No token entered.' }
    # EAP Continue: in 5.1, 2>&1 on a native command under 'Stop' throws on the first stderr line.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $login = $token | docker login ghcr.io -u $GhcrUser --password-stdin 2>&1 | Out-String; $loginCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev; $token = $null }
    if ($loginCode -ne 0) { Fail "GHCR login failed - check the token has read:packages. ($($login.Trim()))" }
    $pull = Invoke-Native 'docker' @('pull', '-q', $Image)
  }
  if ($pull.Code -ne 0) { Write-Host $pull.Output; Fail 'Could not download the image (docker output above).' }
  Ok 'Image downloaded'
}

# ---- 3. Container ----------------------------------------------------------
Step '3/7' "Container $ContainerName on port $Port"
$firstInstall = (Invoke-Native 'docker' @('volume', 'inspect', $VolumeName)).Code -ne 0
$names = (Invoke-Native 'docker' @('ps', '-a', '--format', '{{.Names}}')).Output -split "`r?`n"
if ($names -contains $ContainerName) {
  Invoke-Native 'docker' @('rm', '-f', $ContainerName) | Out-Null
  Ok "Removed old container (data in volume $VolumeName kept)"
}
# Refuse rather than silently move ports: AUTH_URL must match the real port.
$busy = $false
if ($OnWindows) {
  $busy = [bool](Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue)
} else {
  # Both stacks: a program may listen on IPv6 ::1 only.
  foreach ($addr in @('127.0.0.1', '::1')) {
    try { $c = New-Object Net.Sockets.TcpClient($addr, [int]$Port); $busy = $true; $c.Close() } catch { }
  }
}
if ($busy) { Fail "Port $Port is already in use. Free it, or set `$env:PORT to another port and run again." }

# Log rotation: a damaged record (e.g. after an engine crash) would otherwise
# hide all later output from `docker logs`.
$runArgs = @('run', '-d', '--name', $ContainerName, '--restart', 'unless-stopped', '--stop-timeout', '30',
  '--log-opt', 'max-size=20m', '--log-opt', 'max-file=5',
  '-v', "${VolumeName}:/data", '-p', "${Port}:3000", '-e', "AUTH_URL=$Url")
# Throwaway test containers must never run the scheduler (project rule).
if ($TestMode) { $runArgs += @('-e', 'DISABLE_CRON=true') }
$run = Invoke-Native 'docker' ($runArgs + @($Image))
if ($run.Code -ne 0) { Write-Host $run.Output; Fail 'Could not start the container (docker output above).' }
if ($firstInstall) { Ok 'Started (new volume)' } else { Ok 'Started (existing volume - upgrade)' }

# ---- 4. Health -------------------------------------------------------------
Step '4/7' 'Waiting for the app'
Write-Host "  First start creates the database and runs migrations (up to ${HealthWaitSec}s)" -NoNewline
$healthy = $false
for ($i = 0; $i -lt $HealthWaitSec; $i += 2) {
  try {
    $h = Invoke-WebRequest -UseBasicParsing -Uri "$ApiBase/api/health" -TimeoutSec 2
    if ($h.StatusCode -eq 200) { $healthy = $true; break }
  } catch { }
  Write-Host '.' -NoNewline; Start-Sleep -Seconds 2
}
Write-Host ''
if (-not $healthy) {
  Write-Host (Invoke-Native 'docker' @('logs', '--tail', '30', $ContainerName)).Output
  Fail 'The app never became healthy (log above).'
}
Ok 'App is healthy'

# ---- 5. First-run setup ----------------------------------------------------
Step '5/7' 'First-run setup'
# Calls the app's API with one cookie session; returns status + body without
# throwing on 4xx/5xx (PowerShell 5.1 and 7 report errors differently).
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Invoke-Api([string]$Method, [string]$Path, [string]$Json) {
  $params = @{ UseBasicParsing = $true; Method = $Method; Uri = "$ApiBase$Path"; WebSession = $session; TimeoutSec = 60 }
  if ($Json) { $params.ContentType = 'application/json'; $params.Body = $Json }
  try {
    $r = Invoke-WebRequest @params
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
  } catch {
    $status = 0; $body = $_.Exception.Message
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
    return [pscustomobject]@{ Status = $status; Body = $body }
  }
}

if ($env:SKIP_SETUP) {
  Ok 'Skipped (SKIP_SETUP)'
} elseif (-not $firstInstall) {
  Ok 'Existing install - settings left as they are'
} else {
  $r = Invoke-Api 'POST' '/api/auth/switch-account?to=personal' $null
  if ($r.Status -ne 200) { Fail "Could not create the Personal account: $($r.Body)" }
  Ok 'Personal account created'

  $r = Invoke-Api 'PATCH' '/api/user-preferences' '{"habitsEnabled":true}'
  if ($r.Status -ne 200) { Fail "Could not enable the Transformation tracker: $($r.Body)" }
  Ok 'Transformation tracker (100-day challenge) switched on'

  $key = ''
  if ($env:SKIP_OPENAI) {
    Ok 'OpenAI key question skipped (SKIP_OPENAI)'
  } else {
    # A hidden prompt needs a real keyboard; without one, carry on without a key.
    try {
      $sec = Read-Host '  OpenAI API key for Artha + meal estimates (Enter to skip)' -AsSecureString
      if ($sec) { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }
    } catch { Warn 'No keyboard to ask for the OpenAI key - skipping it' }
  }
  if (-not [string]::IsNullOrEmpty($key)) {
    # Keys are [A-Za-z0-9_-] only, so they are safe to put into JSON as-is.
    if ($key -notmatch '^[A-Za-z0-9_-]+$') { Fail 'That does not look like an OpenAI key.' }
    $r = Invoke-Api 'POST' '/api/settings/openai-key' ('{"key":"' + $key + '"}')
    if ($r.Status -eq 200) { Ok 'OpenAI key checked with OpenAI and saved' }
    else { Warn "OpenAI key not saved: $($r.Body) - add it later under Settings" }
  } else {
    Ok 'No OpenAI key - add one any time under Settings'
  }
  $key = $null
}

# ---- 6. Always on ----------------------------------------------------------
Step '6/7' 'Keep it running (sign-in, watchdog, backups)'
if ($env:SKIP_ALWAYS_ON) {
  Ok 'Skipped (SKIP_ALWAYS_ON)'
} else {
  New-Item -ItemType Directory -Force -Path $PfdHome | Out-Null

  # Helpers: from this checkout when run from the repo, else from the public
  # deploy repo. If a download fails keep the installed copy (an upgrade must
  # not stop here); fail only when there is no copy at all.
  $selfDir = $PSScriptRoot
  foreach ($f in @('watchdog.ps1', 'backup.ps1', 'run-hidden.vbs')) {
    $dest = Join-Path $PfdHome $f
    $local = if ($selfDir) { Join-Path $selfDir "windows\$f" } else { $null }
    if ($local -and (Test-Path $local)) {
      Copy-Item $local $dest -Force
    } else {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri "$DeployRaw/$f" -OutFile "$dest.new"
        Move-Item "$dest.new" $dest -Force
      } catch {
        Remove-Item "$dest.new" -ErrorAction SilentlyContinue
        if (-not (Test-Path $dest)) { Fail "Could not download $f from $DeployRaw and no installed copy exists." }
        Warn "Could not download $f - keeping the installed copy"
      }
    }
  }

  # Settings for both helpers: keep other lines, rewrite container + URL.
  $envFile = Join-Path $PfdHome 'watchdog.env'
  $keep = @()
  if (Test-Path $envFile) { $keep = @(Get-Content $envFile | Where-Object { $_ -notmatch '^(CONTAINER|HEALTH_URL)=' }) }
  $lines = $keep + @("CONTAINER=$ContainerName", "HEALTH_URL=$ApiBase/api/health")
  Set-Content -Path $envFile -Value $lines -Encoding ASCII
  Ok "Settings written to $envFile"

  if ($TestMode) {
    Warn 'Test mode: Docker sign-in setting and Scheduled Tasks not registered'
  } else {
    # Docker Desktop's own settings (exist after its first run): start at
    # sign-in, and don't pop the dashboard each time it (re)starts.
    $settingsFile = @((Join-Path $env:APPDATA 'Docker\settings-store.json'), (Join-Path $env:APPDATA 'Docker\settings.json')) |
      Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($settingsFile) {
      try {
        $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
        foreach ($k in @('AutoStart', 'OpenUIOnStartupDisabled')) {
          if ($s.PSObject.Properties[$k]) { $s.$k = $true } else { $s | Add-Member -NotePropertyName $k -NotePropertyValue $true }
        }
        $s | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsFile -Encoding UTF8
        Ok 'Docker Desktop: start at sign-in, no dashboard on start'
      } catch { Warn "Could not update Docker's settings ($settingsFile); turn on 'Start Docker Desktop when you sign in' in its Settings" }
    } else {
      Warn "Docker's settings file not found yet; turn on 'Start Docker Desktop when you sign in' in Docker Desktop -> Settings -> General"
    }

    # Scheduled Tasks run as you, only while you are signed in, through a tiny
    # launcher so no console window flashes every 5 minutes.
    $vbs = Join-Path $PfdHome 'run-hidden.vbs'
    function Register-PfdTask([string]$Name, [string]$Script, $Trigger) {
      $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$(Join-Path $PfdHome $Script)`""
      $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
      Register-ScheduledTask -TaskName $Name -TaskPath '\pfd-saas\' -Action $action -Trigger $Trigger -Settings $settings -Force | Out-Null
    }
    $every5 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-PfdTask 'watchdog' 'watchdog.ps1' $every5
    Ok "Watchdog checks every 5 minutes (log: $PfdHome\watchdog.log)"

    # Monthly on the 1st at 03:00. ScheduledTasks has no monthly cmdlet
    # trigger, so the task is created daily and its trigger swapped for a
    # monthly one through the Task Scheduler COM API.
    Register-PfdTask 'backup' 'backup.ps1' (New-ScheduledTaskTrigger -Daily -At '03:00')
    try {
      $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
      $task = $svc.GetFolder('\pfd-saas').GetTask('backup')
      $def = $task.Definition
      $def.Triggers.Clear()
      $t = $def.Triggers.Create(4)                     # 4 = TASK_TRIGGER_MONTHLY
      $t.StartBoundary = (Get-Date -Hour 3 -Minute 0 -Second 0).ToString("yyyy-MM-dd'T'HH:mm:ss")
      $t.DaysOfMonth = 1                               # bit 0 = the 1st
      $t.MonthsOfYear = 4095                           # all twelve months
      $svc.GetFolder('\pfd-saas').RegisterTaskDefinition('backup', $def, 6, $null, $null, 3) | Out-Null
      Ok "Monthly DB backup -> $HOME\pfd-backups (1st, 03:00; newest 12 kept)"
    } catch {
      Warn "Backup task left DAILY (could not switch it to monthly: $($_.Exception.Message)); it still keeps only the newest 12"
    }
    Warn 'A PC that is off or asleep runs nothing - keep it on if the app must always be reachable'
  }
}

# ---- 7. Done ---------------------------------------------------------------
Step '7/7' 'Done'
Write-Host ''
Write-Host "  pfd-saas is running at $Url" -ForegroundColor Green
Write-Host ''
Write-Host '  Sign in:  click "Use my own data"'
Write-Host '  Upgrade:  run this script again (your data stays)'
Write-Host "  Logs:     docker logs -f $ContainerName"
Write-Host "  Stop:     docker stop $ContainerName   (otherwise it comes back after a crash or restart)"
Write-Host "  Backup:   powershell -ExecutionPolicy Bypass -File `"$PfdHome\backup.ps1`"   (runs by itself monthly)"
Write-Host ''
if (-not $env:NO_OPEN -and $OnWindows) { Start-Process $Url }
