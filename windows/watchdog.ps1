# pfd-saas watchdog (Windows, Docker Desktop). Windows counterpart of
# scripts/mac/watchdog.sh, installed by setup-windows.ps1 into
# %USERPROFILE%\pfd-watchdog and run by the Scheduled Task \pfd-saas\watchdog
# every 5 minutes. Windows PowerShell 5.1; keep this file ASCII-only.
#
# Same rules as the Mac watchdog, minus Telegram (not set up on second
# machines):
#   1. Docker engine hung        - `docker version` does not answer -> restart
#                                  Docker Desktop.
#   2. Container DNS dead        - the container cannot resolve a name -> also
#                                  a Docker restart, BUT only if this PC can
#                                  resolve it. If the PC itself is offline
#                                  (Wi-Fi drop, ISP down, just woke up) a
#                                  Docker restart cannot help: log and do
#                                  nothing.
#   3. App down                  - engine fine, /api/health fails -> restart
#                                  just the container.
# Anti-flap: acts only after 2 failed runs in a row, and at most once per
# cooldown. Backoff: if a recovery did not help, the cooldown doubles
# (15 min, 30, 60 ... capped at 6 h) and resets once everything is healthy.
# Docker Desktop is restarted in the background (its dashboard-on-start is
# turned off by setup-windows.ps1).

$ErrorActionPreference = 'Continue'

$Dir         = if ($env:PFD_HOME) { $env:PFD_HOME } else { Join-Path $HOME 'pfd-watchdog' }
$EnvFile     = Join-Path $Dir 'watchdog.env'
$StateFile   = Join-Path $Dir 'state'
$LogFile     = Join-Path $Dir 'watchdog.log'
$ConsecThreshold = 2
$CooldownSecs    = 900
$MaxCooldownSecs = 21600
$Container = 'pfd-saas'
$HealthUrl = 'http://127.0.0.1:3000/api/health'   # 127.0.0.1, not localhost (may resolve to ::1)
$ProbeHost = 'www.google.com'

# watchdog.env: KEY=value lines (quotes optional), written by setup-windows.ps1.
if (Test-Path $EnvFile) {
  foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$') {
      switch ($Matches[1]) {
        'CONTAINER'  { $Container = $Matches[2] }
        'HEALTH_URL' { $HealthUrl = $Matches[2] }
        'PROBE_HOST' { $ProbeHost = $Matches[2] }
      }
    }
  }
}

$OnWindows = $env:OS -eq 'Windows_NT'
$DockerDir = if ($OnWindows) { Join-Path $env:ProgramFiles 'Docker\Docker' } else { '' }
if ($OnWindows) { $env:Path = $env:Path + ';' + (Join-Path $DockerDir 'resources\bin') }

# Culture-proof (no text parsing, so a decimal-comma locale cannot break it). .NET 4.6+.
function Now { [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Log([string]$msg) { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding ASCII }

# Run a native command with a hard time limit, so a hung engine cannot hang
# the watchdog. True only when it exits 0 in time.
function Invoke-Bounded([int]$Seconds, [string]$Exe, [string[]]$Arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return $false }
  # Drain the pipes so a chatty process cannot block on a full buffer.
  $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($Seconds * 1000)) { try { $p.Kill() } catch { }; return $false }
  return $p.ExitCode -eq 0
}

function Test-Daemon       { Invoke-Bounded 12 'docker' @('version', '--format', '{{.Server.Version}}') }
function Test-ContainerDns { Invoke-Bounded 12 'docker' @('exec', $Container, 'node', '-e', "require('dns').lookup('$ProbeHost',e=>process.exit(e?1:0))") }
function Test-HostDns {
  try { [void][Net.Dns]::GetHostAddresses($ProbeHost); return $true } catch { return $false }
}
function Test-Health {
  try { (Invoke-WebRequest -UseBasicParsing -Uri $HealthUrl -TimeoutSec 8).Content -match '"ok":true' } catch { $false }
}
function Wait-Health {  # up to ~120 s
  for ($i = 0; $i -lt 40; $i++) { if (Test-Health) { return $true }; Start-Sleep -Seconds 3 }
  return $false
}

function Restart-DockerDesktop {
  # Windows only. The process names below also exist on a Mac, where stopping
  # them would take down every container on that machine (e.g. prod).
  if (-not $OnWindows) { Log 'restart_docker: not on Windows - would restart Docker Desktop here; skipped'; return $false }
  Log 'restart_docker: stopping Docker Desktop'
  foreach ($n in @('Docker Desktop', 'com.docker.backend', 'com.docker.build', 'com.docker.dev-envs')) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 5
  Log 'restart_docker: starting Docker Desktop (in the background)'
  Start-Process -FilePath (Join-Path $DockerDir 'Docker Desktop.exe') -WindowStyle Minimized
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-Daemon) { Log "restart_docker: engine up after ~$($i * 3)s"; return $true }
    Start-Sleep -Seconds 3
  }
  Log 'restart_docker: engine still down after ~180s'
  return $false
}

# ---- state: "CONSEC LAST_ACTION_EPOCH FAILED_RECOVERIES HEALTHY_SINCE_ACTION" ----
$consec = 0; $lastAction = 0; $failed = 0; $healthySince = 1
if (Test-Path $StateFile) {
  $parts = ((Get-Content $StateFile -Raw) -split '\s+') | Where-Object { $_ -ne '' }
  if ($parts.Count -ge 1) { $consec = [int]$parts[0] }
  if ($parts.Count -ge 2) { $lastAction = [int]$parts[1] }
  if ($parts.Count -ge 3) { $failed = [int]$parts[2] }
  if ($parts.Count -ge 4) { $healthySince = [int]$parts[3] }
}
function Write-State($a, $b, $c, $d) { Set-Content -Path $StateFile -Value "$a $b $c $d" -Encoding ASCII }
function Get-CooldownSecs {
  $c = $CooldownSecs
  for ($i = 0; $i -lt $failed -and $c -lt $MaxCooldownSecs; $i++) { $c *= 2 }
  [Math]::Min($c, $MaxCooldownSecs)
}

# ---- classify ----
$problem = ''
if (-not (Test-Daemon)) { $problem = 'daemon-wedge' }
elseif (-not (Test-ContainerDns)) {
  if (Test-HostDns) { $problem = 'container-dns-dead' }
  else {
    if ($consec -ne 0) { Log "host offline - not a Docker problem; resetting (was consec=$consec)" }
    Write-State 0 $lastAction $failed $healthySince
    return
  }
}
elseif (-not (Test-Health)) { $problem = 'app-down' }

if (-not $problem) {
  if ($consec -ne 0) { Log "recovered/healthy (was consec=$consec)" }
  if ($failed -ne 0) { Log "backoff reset (was $failed failed recoveries)" }
  Write-State 0 $lastAction 0 1
  return
}

$consec++
Write-State $consec $lastAction $failed $healthySince
Log "PROBLEM=$problem consec=$consec"
if ($consec -lt $ConsecThreshold) { return }

$cd = Get-CooldownSecs
if (((Now) - $lastAction) -lt $cd) { Log "in cooldown ($cd s, $failed failed recoveries), not acting on $problem"; return }
if ($lastAction -ne 0 -and $healthySince -eq 0) {
  $failed++
  Log "last recovery did not help - backoff now $(Get-CooldownSecs) s ($failed failed)"
}

if ($problem -eq 'app-down') {
  Log "app-down confirmed; restarting container $Container"
  [void](Invoke-Bounded 60 'docker' @('restart', $Container))
  if (Wait-Health) { Log 'recovered: /api/health ok after a container restart' } else { Log 'container restart did not restore health - needs a manual look' }
} else {
  Log "$problem confirmed; restarting Docker Desktop (other containers restart too)"
  if ((Restart-DockerDesktop) -and (Wait-Health)) { Log 'recovered: Docker restarted, /api/health ok' } else { Log 'restarted Docker but the app is NOT healthy yet - needs a manual look' }
}
Write-State 0 (Now) $failed 0
