#!/bin/bash
# pfd-saas wedge watchdog (macOS, Docker Desktop).
#
# Repo copy of the watchdog that has run on the prod Mac since 2026-09
# (~/pfd-watchdog/watchdog.sh). Container, port and Telegram come from
# ~/pfd-watchdog/watchdog.env, so the same file serves prod (vaspar-pfd :9999,
# the defaults) and any other Mac (setup-mac.sh writes CONTAINER + HEALTH_URL).
#
# Detects the two failure modes we've actually hit in prod and auto-recovers:
#   1. Docker daemon/VM wedge  — `docker version` hangs; the running container
#      keeps serving but loses its DNS forwarder (getaddrinfo EAI_AGAIN),
#      silencing Telegram + freezing the overview. Only a Docker Desktop
#      restart clears it (which also bounces any other containers — accepted).
#   2. Container DNS dead       — same symptom class; treated like a wedge.
#   3. App down                 — daemon fine but /api/health fails; a lighter
#      `docker restart $CONTAINER` is enough.
#
# Anti-flap: acts only after 2 consecutive failed runs, and at most once per
# 15 min (cooldown). Alerts before + after every recovery action via Telegram.
# Runs from a LaunchAgent every 5 min. All state + logs live under this dir
# (NOT ~/Desktop — LaunchAgents exit 78 on Desktop paths, see project memory).

set -u

# LaunchAgents get a bare PATH — make docker/open/osascript/perl resolvable.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="$HOME/pfd-watchdog"
ENV_FILE="$DIR/watchdog.env"
STATE_FILE="$DIR/state"
LOG_FILE="$DIR/watchdog.log"
CONSEC_THRESHOLD=2          # consecutive fails before acting
COOLDOWN_SECS=900           # min seconds between recovery actions

CONTAINER="vaspar-pfd"
HEALTH_URL="http://localhost:9999/api/health"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

now() { date +%s; }
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*" >> "$LOG_FILE"; }

# run_bounded SECS cmd...  — run a command with a hard wall-clock cap (macOS has
# no `timeout`; perl alarm+exec is the portable equivalent). Non-zero on timeout.
run_bounded() { local s="$1"; shift; perl -e 'my $s=shift; alarm $s; exec @ARGV or exit 127' "$s" "$@"; }

tg() {
  local msg="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "TELEGRAM not configured — would have sent: $msg"; return 0
  fi
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$msg" >/dev/null 2>&1 \
    && log "telegram sent: $msg" || log "telegram FAILED to send: $msg"
}

# --- health probes (each bounded so a wedge can't hang the watchdog) ---
daemon_ok()        { run_bounded 12 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }
container_dns_ok() { run_bounded 12 docker exec "$CONTAINER" node -e 'require("dns").lookup("api.telegram.org",e=>process.exit(e?1:0))' >/dev/null 2>&1; }
health_ok()        { curl -fs --max-time 8 "$HEALTH_URL" 2>/dev/null | grep -q '"ok":true'; }

wait_health() {  # poll /api/health up to ~120s
  local i=0
  while [ $i -lt 40 ]; do health_ok && return 0; sleep 3; i=$((i+1)); done
  return 1
}

restart_docker() {
  log "restart_docker: quitting Docker Desktop"
  osascript -e 'quit app "Docker"' >/dev/null 2>&1
  sleep 8
  # SIGKILL survivors (leave the root-owned privileged helper vmnetd alone).
  for pat in 'Docker Desktop.app' 'com.docker.backend' 'com.docker.virtualization' 'com.docker.build' 'com.docker.dev-envs'; do
    pkill -9 -f "$pat" 2>/dev/null
  done
  sleep 3
  log "restart_docker: relaunching Docker.app"
  open -a Docker
  local i=0
  while [ $i -lt 60 ]; do daemon_ok && { log "restart_docker: daemon up after ~$((i*3))s"; return 0; }; sleep 3; i=$((i+1)); done
  log "restart_docker: daemon still down after ~180s"
  return 1
}

# --- state: "CONSEC LAST_ACTION_EPOCH" ---
consec=0; last_action=0
if [ -f "$STATE_FILE" ]; then read -r consec last_action < "$STATE_FILE" 2>/dev/null; fi
[ -z "$consec" ] && consec=0
[ -z "$last_action" ] && last_action=0
write_state() { echo "$1 $2" > "$STATE_FILE"; }

# --- classify ---
problem=""
if ! daemon_ok; then problem="daemon-wedge"
elif ! container_dns_ok; then problem="container-dns-dead"
elif ! health_ok; then problem="app-down"
fi

if [ -z "$problem" ]; then
  [ "$consec" -ne 0 ] && log "recovered/healthy (was consec=$consec)"
  write_state 0 "$last_action"
  exit 0
fi

consec=$((consec + 1))
write_state "$consec" "$last_action"
log "PROBLEM=$problem consec=$consec"

# Need a 2nd consecutive confirmation before acting (ride out transient blips).
[ "$consec" -lt "$CONSEC_THRESHOLD" ] && exit 0

# Cooldown — don't hammer restarts.
if [ $(( $(now) - last_action )) -lt "$COOLDOWN_SECS" ]; then
  log "in cooldown ($COOLDOWN_SECS s), not acting on $problem"
  exit 0
fi

case "$problem" in
  daemon-wedge|container-dns-dead)
    tg "⚠️ $CONTAINER watchdog: ${problem} confirmed (2× in a row). Restarting Docker Desktop now — other containers bounce too. All auto-return."
    if restart_docker && wait_health; then
      tg "✅ $CONTAINER recovered: Docker restarted, /api/health is 200."
    else
      tg "❌ $CONTAINER watchdog: restarted Docker but the app is NOT healthy yet — needs a manual look."
    fi
    ;;
  app-down)
    tg "⚠️ $CONTAINER watchdog: app-down confirmed (2×), Docker daemon is fine. Restarting just the $CONTAINER container."
    run_bounded 60 docker restart "$CONTAINER" >/dev/null 2>&1
    if wait_health; then
      tg "✅ $CONTAINER recovered: /api/health is 200 after a container restart."
    else
      tg "❌ $CONTAINER watchdog: container restart didn't restore health — needs a manual look."
    fi
    ;;
esac

write_state 0 "$(now)"
exit 0
