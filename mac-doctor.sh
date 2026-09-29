#!/bin/bash
# pfd-saas Mac doctor — diagnose an install, then bring it fully up to date.
#
#   bash ~/Downloads/mac-doctor.sh            # diagnose + fix
#   DRY_RUN=1 bash ~/Downloads/mac-doctor.sh  # diagnose only, change nothing
#
# 1. Reports what is on this Mac: Docker, pfd containers/volumes, which
#    setup-mac.sh copies exist (old ones lack the "Keep it running" step),
#    LaunchAgents, ~/pfd-watchdog.
# 2. Finds the existing app container and reuses ITS name, volume and port,
#    so your data stays attached (a different volume name = an empty app).
# 3. Downloads the latest setup-mac.sh from GitHub and runs it as an upgrade
#    (data kept; first-run setup skipped on an existing volume).
# 4. Verifies the three com.pfd-saas LaunchAgents are loaded.
# Everything printed is also saved to ~/Desktop/pfd-doctor-report.txt.

set -uo pipefail
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"

REPORT="$HOME/Desktop/pfd-doctor-report.txt"
exec > >(tee "$REPORT") 2>&1

RAW="${PFD_DEPLOY_RAW:-https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main}/setup-mac.sh"  # public deploy repo (source repo is private)
IMAGE_REPO="ghcr.io/beedev/pfd-saas"
hr() { printf '\n==== %s ====\n' "$1"; }

hr "Mac"
echo "date:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "user:     $USER   macOS $(sw_vers -productVersion)   chip $(uname -m)"

hr "Docker"
if [ -d /Applications/Docker.app ]; then echo "Docker Desktop: installed"; else echo "Docker Desktop: NOT installed"; fi
if docker info >/dev/null 2>&1; then
  echo "engine: running ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  DOCKER_UP=1
else
  echo "engine: NOT running"
  DOCKER_UP=0
fi
DS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
[ -f "$DS" ] && echo "Docker AutoStart setting: $(plutil -extract AutoStart raw "$DS" 2>/dev/null || echo 'not set')"

CONTAINER=""; VOLUME=""; PORT=""
if [ "$DOCKER_UP" = 1 ]; then
  hr "Containers"
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  hr "Volumes"
  docker volume ls --format '{{.Name}}' | grep -i pfd || echo "(no pfd volumes)"

  # The app container: created from our image. Use .Config.Image (the name it
  # was created from) — after a newer `docker pull`, `docker ps` shows an old
  # container's image as a bare hash, which would miss it and start an EMPTY app.
  CONTAINER=""
  for c in $(docker ps -a --format '{{.Names}}'); do
    case "$(docker inspect "$c" --format '{{.Config.Image}}')" in
      "$IMAGE_REPO"*) CONTAINER="$c"; break ;;
    esac
  done
  if [ -n "$CONTAINER" ]; then
    VOLUME=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
    PORT=$(docker inspect "$CONTAINER" --format '{{range $p, $b := .HostConfig.PortBindings}}{{(index $b 0).HostPort}}{{end}}')
    echo; echo "app container: $CONTAINER   volume: ${VOLUME:-?}   port: ${PORT:-?}"
    echo "image commit:  $(docker inspect "$CONTAINER" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null | cut -c1-7)"
    echo "restart policy: $(docker inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}')"
  else
    echo; echo "app container: none found (will do a fresh install)"
  fi
fi

hr "setup-mac.sh copies (1 = has the 'Keep it running' step, 0 = old)"
found=0
for f in "$HOME"/Downloads/setup-mac*.sh "$HOME"/setup-mac*.sh "$HOME"/Desktop/setup-mac*.sh; do
  [ -f "$f" ] || continue
  found=1; printf '%s: %s\n' "$f" "$(grep -c 'Keep it running' "$f")"
done
[ "$found" = 1 ] || echo "(none found)"

hr "LaunchAgents"
ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -iE 'pfd|docker' || echo "(no pfd/docker agent files)"
echo "-- loaded:"; launchctl list | grep -iE 'pfd|docker-autostart' || echo "(none loaded)"

hr "~/pfd-watchdog"
ls -la "$HOME/pfd-watchdog" 2>/dev/null || echo "(folder does not exist)"
[ -f "$HOME/pfd-watchdog/watchdog.env" ] && { echo "-- watchdog.env:"; grep -vE 'TOKEN' "$HOME/pfd-watchdog/watchdog.env"; }

if [ -n "${DRY_RUN:-}" ]; then
  hr "DRY RUN — nothing changed"
  echo "Would run the latest setup-mac.sh with: CONTAINER_NAME=${CONTAINER:-pfd-saas} VOLUME_NAME=${VOLUME:-pfd_saas_data} PORT=${PORT:-3000}"
  echo "Report saved to $REPORT"
  exit 0
fi

hr "Upgrade with the latest setup-mac.sh"
DEST="$HOME/pfd-setup"
mkdir -p "$DEST"
if ! curl -fsSL -o "$DEST/setup-mac.sh" "$RAW"; then
  echo "✗ could not download setup-mac.sh from GitHub (network?)"; exit 1
fi
echo "downloaded: $DEST/setup-mac.sh (has step 6: $(grep -c 'Keep it running' "$DEST/setup-mac.sh"))"

# Reuse the existing container's names so the data volume stays attached.
export CONTAINER_NAME="${CONTAINER:-pfd-saas}"
export VOLUME_NAME="${VOLUME:-pfd_saas_data}"
export PORT="${PORT:-3000}"
echo "running with CONTAINER_NAME=$CONTAINER_NAME VOLUME_NAME=$VOLUME_NAME PORT=$PORT"
bash "$DEST/setup-mac.sh"
rc=$?
echo "setup-mac.sh exit code: $rc"

hr "Verify"
sleep 2
AGENTS_OK=0
for a in com.pfd-saas.docker-autostart com.pfd-saas.watchdog com.pfd-saas.backup; do
  if launchctl list | grep -q "$a"; then echo "✓ $a loaded"; AGENTS_OK=$((AGENTS_OK+1)); else echo "✗ $a NOT loaded"; fi
done
echo "-- watchdog.env:"; grep -vE 'TOKEN' "$HOME/pfd-watchdog/watchdog.env" 2>/dev/null || echo "(missing)"
C="$CONTAINER_NAME"
echo "container: $(docker inspect "$C" --format '{{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} stopTimeout={{.Config.StopTimeout}}' 2>/dev/null || echo 'not found')"
curl -fsS -m 5 "http://localhost:$PORT/api/health" >/dev/null 2>&1 && echo "✓ app healthy at http://localhost:$PORT" || echo "✗ app NOT answering at http://localhost:$PORT"

hr "Result"
if [ "$rc" = 0 ] && [ "$AGENTS_OK" = 3 ]; then
  echo "ALL GOOD: app upgraded, data volume $VOLUME_NAME kept, 3 always-on agents loaded."
else
  echo "NOT COMPLETE — AirDrop $REPORT back so it can be diagnosed."
fi
echo "Report saved to $REPORT"
