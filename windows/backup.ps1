# pfd-saas monthly database backup (Windows). Counterpart of scripts/mac/backup.sh,
# installed by setup-windows.ps1 into %USERPROFILE%\pfd-watchdog and run by the
# Scheduled Task \pfd-saas\backup (1st of the month, 03:00; runs at the next
# chance if the PC was off). Windows PowerShell 5.1; keep this file ASCII-only.
#
# Binary-safe on purpose: PowerShell 5.1 re-encodes anything redirected with
# `>` as text, which would corrupt a pg_dump stream. So the dump is written
# INSIDE the container and copied out byte-for-byte with `docker cp`.
# A .partial name is used until the copy succeeds, so a failed run never
# looks like a good backup. Keeps the newest KEEP dumps.
#
# Settings (from watchdog.env, written by setup-windows.ps1):
#   CONTAINER (default pfd-saas)   BACKUP_DIR (default %USERPROFILE%\pfd-backups)   KEEP (default 12)

$ErrorActionPreference = 'Continue'

$Dir       = if ($env:PFD_HOME) { $env:PFD_HOME } else { Join-Path $HOME 'pfd-watchdog' }
$EnvFile   = Join-Path $Dir 'watchdog.env'
$LogFile   = Join-Path $Dir 'backup.log'
$Container = 'pfd-saas'
$BackupDir = Join-Path $HOME 'pfd-backups'
$Keep      = 12
if (Test-Path $EnvFile) {
  foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$') {
      switch ($Matches[1]) {
        'CONTAINER'  { $Container = $Matches[2] }
        'BACKUP_DIR' { $BackupDir = $Matches[2] }
        'KEEP'       { $Keep = [int]$Matches[2] }
      }
    }
  }
}
if ($env:OS -eq 'Windows_NT') { $env:Path = $env:Path + ';' + (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin') }

New-Item -ItemType Directory -Force -Path $Dir, $BackupDir | Out-Null
function Log([string]$msg) {
  $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $LogFile -Value $line -Encoding ASCII
  Write-Host $line
}

$out = Join-Path $BackupDir ("{0}-db-backup-{1}.dump" -f $Container, (Get-Date -Format 'ddMMyyyy'))
$partial = "$out.partial"
$inside = '/tmp/pfd-backup.dump'

# No double quotes inside this command: Windows PowerShell 5.1 strips embedded
# quotes from native-command arguments. Safe unquoted - the entrypoint makes the
# password alphanumeric only (openssl base64 with /=+ removed).
$cmd = 'PGPASSWORD=$(cat /data/.secrets/postgres_password) pg_dump -Fc -h 127.0.0.1 -U pfd_saas -d pfd_saas -f ' + $inside
& docker exec $Container sh -c $cmd 2>&1 | Out-Null
$dumpOk = $LASTEXITCODE -eq 0
if ($dumpOk) {
  & docker cp "${Container}:$inside" $partial 2>&1 | Out-Null
  $dumpOk = ($LASTEXITCODE -eq 0) -and (Test-Path $partial) -and ((Get-Item $partial).Length -gt 0)
}
& docker exec $Container rm -f $inside 2>&1 | Out-Null

if ($dumpOk) {
  Move-Item -Path $partial -Destination $out -Force
  Log ("backup OK -> {0} ({1:N1} MB)" -f $out, ((Get-Item $out).Length / 1MB))
} else {
  Remove-Item $partial -ErrorAction SilentlyContinue
  Log "backup FAILED for container $Container"
  exit 1
}

# Retention: newest $Keep dumps for this container.
Get-ChildItem -Path $BackupDir -Filter "$Container-db-backup-*.dump" |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep |
  ForEach-Object { Remove-Item $_.FullName -Force; Log "pruned $($_.FullName)" }
