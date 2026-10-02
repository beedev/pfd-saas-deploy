#!/bin/bash
# pfd-saas — set up (or upgrade) the app on a Mac, from nothing.
#
#   curl -fsSLo setup-mac.sh https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/setup-mac.sh
#
# Published to the PUBLIC repo beedev/pfd-saas-deploy (the source repo is
# private). The copy there is synced from scripts/ by CI after each image build.
#   bash setup-mac.sh
#
# What it does:
#   1. Installs Docker Desktop if missing (official .dmg for this chip,
#      Docker's own installer with --accept-license; asks for your Mac
#      password once), then starts it and waits for the engine.
#   2. Pulls the image. Tries anonymously first; only if GHCR refuses (the
#      package is private) does it ask for a GitHub token with read:packages.
#   3. (Re)creates the container with --restart unless-stopped on the
#      persistent volume. The volume is NEVER removed, so re-running this
#      script is how you upgrade.
#   4. Waits for /api/health.
#   5. First install only (the volume did not exist before): creates the
#      Personal account, switches on the Transformation tracker, and saves an
#      OpenAI key if you paste one.
#   6. Keeps it alive, like the prod Mac (LaunchAgents under com.pfd-saas.*):
#        - Docker Desktop starts at login (AutoStart setting + a login agent,
#          because Docker sometimes rewrites its own setting);
#        - the wedge watchdog every 5 min (restarts Docker when the engine
#          hangs or container DNS dies; restarts the container if the app is
#          down) — scripts/mac/watchdog.sh;
#        - a monthly DB backup to ~/pfd-backups, 1st at 03:00, newest 12 kept
#          — scripts/mac/backup.sh.
#      Skipped on a Mac that already has the prod (com.bharath.*) agents.
#   7. Opens the browser.
#
# Telegram is deliberately not set up: a second instance on the same bot
# would steal the prod bot's messages (single getUpdates consumer).
#
# Env overrides (all optional):
#   PORT=3000  CONTAINER_NAME=pfd-saas  VOLUME_NAME=pfd_saas_data
#   IMAGE=ghcr.io/beedev/pfd-saas:latest  GHCR_USER=beedev
#   NO_PULL=1      use an image already on this machine (testing)
#   SKIP_SETUP=1   skip step 5
#   NO_OPEN=1      don't open the browser at the end
#   SKIP_ALWAYS_ON=1  skip step 6
#   PFD_HOME=~/pfd-watchdog  LAUNCH_AGENTS_DIR=~/Library/LaunchAgents
#   NO_LAUNCHCTL=1 write the LaunchAgents but don't load them (testing)

set -euo pipefail

PORT="${PORT:-3000}"
CONTAINER_NAME="${CONTAINER_NAME:-pfd-saas}"
VOLUME_NAME="${VOLUME_NAME:-pfd_saas_data}"
IMAGE="${IMAGE:-ghcr.io/beedev/pfd-saas:latest}"
GHCR_USER="${GHCR_USER:-beedev}"
URL="http://localhost:$PORT"
DOCKER_WAIT_SEC=180
HEALTH_WAIT_SEC=180

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
step()    { printf "\n${BLUE}[%s]${NC} ${BOLD}%s${NC}\n" "$1" "$2"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$1"; }
fail()    { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

# Prompts read from the terminal, not stdin, so `curl … | bash` still works.
# Returns 1 when there is no terminal to ask on.
ask() {  # ask <prompt> <var> [silent]
  { [ -r /dev/tty ] && : </dev/tty; } 2>/dev/null || return 1
  if [ "${3:-}" = silent ]; then
    IFS= read -rs -p "$1" "$2" </dev/tty; printf "\n"
  else
    IFS= read -r -p "$1" "$2" </dev/tty
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ─── 1. Docker ────────────────────────────────────────────────────────
step "1/7" "Docker"
[ "$(uname)" = "Darwin" ] || fail "This script is for macOS. On Linux use install.sh."

# Docker.app ships its CLI inside the bundle; a fresh install may not have
# linked it onto PATH yet.
export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin"

if [ ! -d /Applications/Docker.app ]; then
  case "$(uname -m)" in
    arm64)  DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg" ;;
    x86_64) DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg" ;;
    *) fail "Unknown Mac architecture: $(uname -m)" ;;
  esac
  printf "  Downloading Docker Desktop (~600 MB)...\n"
  curl -fL --progress-bar -o "$TMP/Docker.dmg" "$DMG_URL"
  printf "  Installing — macOS will ask for your password (admin rights).\n"
  sudo hdiutil attach -nobrowse -quiet "$TMP/Docker.dmg"
  sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license --user="$USER"
  sudo hdiutil detach -quiet /Volumes/Docker || true
  success "Docker Desktop installed"
else
  success "Docker Desktop already installed"
fi

if ! docker info >/dev/null 2>&1; then
  open -a Docker
  printf "  Starting Docker (up to ${DOCKER_WAIT_SEC}s; answer any Docker window that opens)"
  for i in $(seq 1 "$DOCKER_WAIT_SEC"); do
    docker info >/dev/null 2>&1 && break
    printf "."; sleep 1
    [ "$i" = "$DOCKER_WAIT_SEC" ] && { printf "\n"; fail "Docker did not start. Open Docker Desktop, finish its first-run screens, then re-run."; }
  done
  printf "\n"
fi
success "Docker engine is running"

# ─── 2. Image ─────────────────────────────────────────────────────────
step "2/7" "Image $IMAGE"
if [ -n "${NO_PULL:-}" ]; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "NO_PULL set but $IMAGE is not on this machine"
  success "Using local image (NO_PULL)"
elif docker pull -q "$IMAGE" >"$TMP/pull.log" 2>&1; then
  success "Image downloaded"
elif grep -qiE 'unauthorized|denied' "$TMP/pull.log"; then
  warn "The image is private. A GitHub token with the read:packages scope is needed"
  printf "  (github.com → Settings → Developer settings → Personal access tokens).\n"
  printf "  Docker keeps the login in the macOS keychain, so this is asked only once.\n"
  ask "  GitHub token for $GHCR_USER: " GH_TOKEN silent || fail "Need a terminal to enter the token."
  [ -n "$GH_TOKEN" ] || fail "No token entered."
  printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
    || fail "GHCR login failed — check the token has read:packages."
  unset GH_TOKEN
  docker pull -q "$IMAGE" >/dev/null || fail "Pull still failed after login."
  success "Logged in and image downloaded"
else
  cat "$TMP/pull.log" >&2
  fail "Could not download the image (network?)."
fi

# ─── 3. Container ─────────────────────────────────────────────────────
step "3/7" "Container $CONTAINER_NAME on port $PORT"
FIRST_INSTALL=0
docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || FIRST_INSTALL=1

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
  success "Removed old container (data in volume $VOLUME_NAME kept)"
fi
# Refuse rather than silently move ports: AUTH_URL must match the real port.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Port $PORT is already in use. Free it, or re-run with PORT=<other>."
fi

# Log rotation: a damaged record (e.g. from a Docker engine wedge) would
# otherwise hide all later output from `docker logs`, forever.
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped --stop-timeout 30 \
  --log-opt max-size=20m --log-opt max-file=5 \
  -v "$VOLUME_NAME:/data" -p "$PORT:3000" \
  -e "AUTH_URL=$URL" \
  "$IMAGE" >/dev/null
success "Started ($([ $FIRST_INSTALL = 1 ] && echo 'new volume' || echo 'existing volume — upgrade'))"

# ─── 4. Health ────────────────────────────────────────────────────────
step "4/7" "Waiting for the app"
printf "  First start creates the database and runs migrations (up to ${HEALTH_WAIT_SEC}s)"
for i in $(seq 1 "$HEALTH_WAIT_SEC"); do
  curl -fsS -m 2 "$URL/api/health" >/dev/null 2>&1 && break
  printf "."; sleep 1
  if [ "$i" = "$HEALTH_WAIT_SEC" ]; then
    printf "\n"; docker logs --tail 30 "$CONTAINER_NAME" >&2 || true
    fail "App never became healthy (log above)."
  fi
done
printf "\n"
success "App is healthy"

# ─── 5. First-run setup ───────────────────────────────────────────────
step "5/7" "First-run setup"
if [ -n "${SKIP_SETUP:-}" ]; then
  success "Skipped (SKIP_SETUP)"
elif [ "$FIRST_INSTALL" != 1 ]; then
  success "Existing install — settings left as they are"
else
  JAR="$TMP/cookies"
  api() {  # api <method> <path> [json] → prints HTTP status; body in $TMP/body
    local args=(-s -m 60 -b "$JAR" -c "$JAR" -o "$TMP/body" -w '%{http_code}' -X "$1")
    [ -n "${3:-}" ] && args+=(-H 'content-type: application/json' -d "$3")
    curl "${args[@]}" "$URL$2"
  }

  [ "$(api POST '/api/auth/switch-account?to=personal')" = 200 ] \
    || fail "Could not create the Personal account: $(cat "$TMP/body")"
  success "Personal account created"

  [ "$(api PATCH /api/user-preferences '{"habitsEnabled":true}')" = 200 ] \
    || fail "Could not enable the Transformation tracker: $(cat "$TMP/body")"
  success "Transformation tracker (100-day challenge) switched on"

  OPENAI_KEY=""
  ask "  OpenAI API key for Artha + meal estimates (Enter to skip): " OPENAI_KEY silent || true
  if [ -n "$OPENAI_KEY" ]; then
    # Keys are [A-Za-z0-9_-] only, so they are safe to drop into JSON as-is.
    printf '%s' "$OPENAI_KEY" | grep -qE '^[A-Za-z0-9_-]+$' || fail "That does not look like an OpenAI key."
    if [ "$(api POST /api/settings/openai-key "{\"key\":\"$OPENAI_KEY\"}")" = 200 ]; then
      success "OpenAI key checked with OpenAI and saved"
    else
      warn "OpenAI key not saved: $(cat "$TMP/body") — add it later under Settings"
    fi
  else
    success "No OpenAI key — add one any time under Settings"
  fi
  unset OPENAI_KEY
fi

# ─── 6. Always on ─────────────────────────────────────────────────────
step "6/7" "Keep it running (login, watchdog, backups)"
PFD_HOME="${PFD_HOME:-$HOME/pfd-watchdog}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
MAC_RAW="${PFD_DEPLOY_RAW:-https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main}/mac"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo .)"

if [ -n "${SKIP_ALWAYS_ON:-}" ]; then
  success "Skipped (SKIP_ALWAYS_ON)"
elif [ -f "$LAUNCH_AGENTS_DIR/com.bharath.vaspar-pfd-watchdog.plist" ]; then
  warn "This Mac already runs the prod watchdog (com.bharath.*) — not adding a second one"
else
  mkdir -p "$PFD_HOME" "$LAUNCH_AGENTS_DIR"

  # Helper scripts: from this checkout when run from the repo, else from the
  # public deploy repo. If the download fails, keep the copy already installed
  # (an upgrade must not stop here); fail only when there is no copy at all.
  for f in watchdog.sh backup.sh; do
    if [ -f "$SELF_DIR/mac/$f" ]; then
      cp "$SELF_DIR/mac/$f" "$PFD_HOME/$f"
    elif curl -fsSL -o "$PFD_HOME/$f.new" "$MAC_RAW/$f" && [ -s "$PFD_HOME/$f.new" ]; then
      mv "$PFD_HOME/$f.new" "$PFD_HOME/$f"
    else
      rm -f "$PFD_HOME/$f.new"
      [ -s "$PFD_HOME/$f" ] || fail "Could not download $f from $MAC_RAW and no installed copy exists"
      warn "Could not download $f — keeping the installed copy"
    fi
    chmod +x "$PFD_HOME/$f"
  done

  # Settings for both helpers. Keep any existing lines (e.g. Telegram) and
  # (re)write just the container and URL.
  ENV_FILE="$PFD_HOME/watchdog.env"
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  grep -vE '^(CONTAINER|HEALTH_URL)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
  { cat "$ENV_FILE.tmp"; echo "CONTAINER=\"$CONTAINER_NAME\""; echo "HEALTH_URL=\"$URL/api/health\""; } > "$ENV_FILE"
  rm -f "$ENV_FILE.tmp"

  # Docker Desktop's own start-at-login setting (the file exists after its first run).
  DOCKER_SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
  if [ -f "$DOCKER_SETTINGS" ] && [ -z "${NO_LAUNCHCTL:-}" ]; then
    plutil -replace AutoStart -bool YES "$DOCKER_SETTINGS" 2>/dev/null \
      && success "Docker Desktop setting: start at login" \
      || warn "Could not set Docker's AutoStart; the login agent below covers it"
    # Don't pop the Docker dashboard every time Docker (re)starts — the
    # watchdog may restart it in the background and nobody needs the window.
    plutil -replace OpenUIOnStartupDisabled -bool YES "$DOCKER_SETTINGS" 2>/dev/null \
      && success "Docker Desktop setting: don't open the dashboard on start" \
      || warn "Could not turn off Docker's dashboard-on-start (harmless)"
  fi

  # write_agent <label> <body-xml>
  write_agent() {
    cat > "$LAUNCH_AGENTS_DIR/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
$2
  <key>StandardOutPath</key><string>$PFD_HOME/$1.log</string>
  <key>StandardErrorPath</key><string>$PFD_HOME/$1.log</string>
</dict>
</plist>
PLIST
    plutil -lint "$LAUNCH_AGENTS_DIR/$1.plist" >/dev/null || fail "Bad plist: $1"
    if [ -z "${NO_LAUNCHCTL:-}" ]; then
      launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$1.plist" || fail "Could not load $1"
    fi
  }

  write_agent com.pfd-saas.docker-autostart '  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>Docker</string></array>
  <key>RunAtLoad</key><true/>'
  success "Docker opens at login"

  write_agent com.pfd-saas.watchdog "  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$PFD_HOME/watchdog.sh</string></array>
  <key>StartInterval</key><integer>300</integer>"
  success "Watchdog checks every 5 minutes (log: $PFD_HOME/watchdog.log)"

  write_agent com.pfd-saas.backup "  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$PFD_HOME/backup.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Day</key><integer>1</integer><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>"
  success "Monthly DB backup → ~/pfd-backups (1st, 03:00; newest 12 kept)"
  warn "A sleeping Mac runs nothing — keep this Mac awake if the app must always be reachable"
fi

# ─── 7. Done ──────────────────────────────────────────────────────────
step "7/7" "Done"
printf "\n${BOLD}${GREEN}━━━ pfd-saas is running at %s ━━━${NC}\n\n" "$URL"
printf "  Sign in:  click ${BOLD}Use my own data${NC}\n"
printf "  Upgrade:  run this script again (your data stays)\n"
printf "  Logs:     docker logs -f %s\n" "$CONTAINER_NAME"
printf "  Stop:     docker stop %s   (otherwise it returns by itself after a crash or reboot)\n" "$CONTAINER_NAME"
printf "  Backup:   bash %s/backup.sh   (runs by itself monthly)\n\n" "${PFD_HOME:-$HOME/pfd-watchdog}"
[ -n "${NO_OPEN:-}" ] || open "$URL" 2>/dev/null || true
