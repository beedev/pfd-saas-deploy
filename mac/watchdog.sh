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
# cooldown. Alerts before + after every recovery action via Telegram.
#
# 2026-10-02 — the "Docker window keeps popping up" fix:
#   * HOST OFFLINE IS NOT A DOCKER PROBLEM. The container-DNS probe also fails
#     when the Mac itself has no internet (Wi-Fi drop, ISP/router down, just
#     woke from sleep). Restarting Docker can't fix that, so before treating
#     container DNS as dead we check the Mac's own DNS for the same name; if the
#     Mac can't resolve it either, we log "host offline" and do nothing.
#     (The prod log showed 44 restarts, most in 15-min loops, each one next to
#     "telegram FAILED to send" from the host — i.e. no internet.)
#   * BACKOFF: if a recovery didn't help (the problem is back on the next run),
#     the cooldown doubles each time — 15 min, 30, 60 … capped at 6 h — and
#     resets to 15 min once everything is healthy.
#   * NEVER STEAL FOCUS: Docker is relaunched with `open -g` (background), so
#     its window doesn't jump to the front.
# Runs from a LaunchAgent every 5 min. All state + logs live under this dir
# (NOT ~/Desktop — LaunchAgents exit 78 on Desktop paths, see project memory).

set -u

# LaunchAgents get a bare PATH — make docker/open/osascript/perl resolvable.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="$HOME/pfd-watchdog"
ENV_FILE="$DIR/watchdog.env"
STATE_FILE="$DIR/state"
LOG_FILE="$DIR/watchdog.log"
CONSEC_THRESHOLD=2          # consecutive fails before acting
COOLDOWN_SECS=900           # base min seconds between recovery actions
MAX_COOLDOWN_SECS=21600     # backoff cap (6 h)
PROBE_HOST="www.google.com"  # a neutral name both the Mac and the container must resolve (override in watchdog.env)

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
  # Telegram is optional: with no bot configured (e.g. a second Mac) we only log.
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "note: $msg"; return 0
  fi
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$msg" >/dev/null 2>&1 \
    && log "telegram sent: $msg" || log "telegram FAILED to send: $msg"
}

# --- health probes (each bounded so a wedge can't hang the watchdog) ---
daemon_ok()        { run_bounded 12 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }
container_dns_ok() { run_bounded 12 docker exec "$CONTAINER" node -e "require('dns').lookup('$PROBE_HOST',e=>process.exit(e?1:0))" >/dev/null 2>&1; }
# The Mac's own DNS (dscacheutil asks the system resolver, like any app would).
host_dns_ok()      { run_bounded 8 dscacheutil -q host -a name "$PROBE_HOST" 2>/dev/null | grep -q '^ip'; }
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
  log "restart_docker: relaunching Docker.app (in the background)"
  open -g -a Docker
  local i=0
  while [ $i -lt 60 ]; do daemon_ok && { log "restart_docker: daemon up after ~$((i*3))s"; return 0; }; sleep 3; i=$((i+1)); done
  log "restart_docker: daemon still down after ~180s"
  return 1
}

# --- state: "CONSEC LAST_ACTION_EPOCH FAILED_RECOVERIES HEALTHY_SINCE_ACTION" ---
# (older 2-field state files read fine: the new fields default to 0 / 1)
consec=0; last_action=0; failed=0; healthy_since=1
if [ -f "$STATE_FILE" ]; then read -r consec last_action failed healthy_since < "$STATE_FILE" 2>/dev/null; fi
[ -z "$consec" ] && consec=0
[ -z "$last_action" ] && last_action=0
[ -z "${failed:-}" ] && failed=0
[ -z "${healthy_since:-}" ] && healthy_since=1
write_state() { echo "$1 $2 $3 $4" > "$STATE_FILE"; }

# cooldown = base × 2^failed, capped
cooldown_secs() {
  local c=$COOLDOWN_SECS i=0
  while [ $i -lt "$failed" ] && [ $c -lt $MAX_COOLDOWN_SECS ]; do c=$((c * 2)); i=$((i + 1)); done
  [ $c -gt $MAX_COOLDOWN_SECS ] && c=$MAX_COOLDOWN_SECS
  echo $c
}

# --- classify ---
problem=""
if ! daemon_ok; then problem="daemon-wedge"
elif ! container_dns_ok; then
  if host_dns_ok; then problem="container-dns-dead"
  else
    # The Mac itself can't resolve the name: an internet outage, not Docker.
    [ "$consec" -ne 0 ] && log "host offline — not a Docker problem; resetting (was consec=$consec)"
    write_state 0 "$last_action" "$failed" "$healthy_since"
    exit 0
  fi
elif ! health_ok; then problem="app-down"
fi

if [ -z "$problem" ]; then
  [ "$consec" -ne 0 ] && log "recovered/healthy (was consec=$consec)"
  [ "$failed" -ne 0 ] && log "backoff reset (was $failed failed recoveries)"
  write_state 0 "$last_action" 0 1
  exit 0
fi

consec=$((consec + 1))
write_state "$consec" "$last_action" "$failed" "$healthy_since"
log "PROBLEM=$problem consec=$consec"

# Need a 2nd consecutive confirmation before acting (ride out transient blips).
[ "$consec" -lt "$CONSEC_THRESHOLD" ] && exit 0

# Cooldown — don't hammer restarts; it grows while recoveries don't help.
cd_secs=$(cooldown_secs)
if [ $(( $(now) - last_action )) -lt "$cd_secs" ]; then
  log "in cooldown ($cd_secs s, $failed failed recoveries), not acting on $problem"
  exit 0
fi
# Acting again with no healthy run since the last action = that recovery didn't help.
if [ "$last_action" -ne 0 ] && [ "$healthy_since" -eq 0 ]; then
  failed=$((failed + 1))
  log "last recovery did not help — backoff now $(cooldown_secs) s ($failed failed)"
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

write_state 0 "$(now)" "$failed" 0
exit 0
