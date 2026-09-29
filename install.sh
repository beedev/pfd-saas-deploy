#!/bin/bash
# pfd-saas one-line installer — pulls the pre-built image from GHCR
# and runs it.
#
# Designed to be curl|bashed:
#   curl -fsSL https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/install.sh | bash
#
# Or download + inspect first (recommended):
#   curl -fsSLo install.sh https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/install.sh
#   less install.sh
#   bash install.sh
#
# Env overrides (all optional):
#   PORT=3000              host port to bind to (auto-bumps if taken)
#   IMAGE_TAG=latest       image tag (or pin to a version, e.g. v0.7.0)
#   CONTAINER_NAME=pfd-saas
#   VOLUME_NAME=pfd_saas_data
#   AUTH_URL=...           override the auth callback URL (set when
#                           running behind a proxy)
#
# What this does:
#   1. Verifies Docker is running.
#   2. Picks a free port.
#   3. Pulls the image (~600 MB, one-time).
#   4. Stops any prior container with the same name (data in the
#      named volume is preserved).
#   5. Runs the container with the persistent volume.
#   6. Waits for /api/health to return 200.
#   7. Opens the browser (macOS only) and prints next steps.

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/beedev/pfd-saas}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
CONTAINER_NAME="${CONTAINER_NAME:-pfd-saas}"
VOLUME_NAME="${VOLUME_NAME:-pfd_saas_data}"
PORT="${PORT:-3000}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-120}"

# ─── Color (NO_COLOR=1 disables) ──────────────────────────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

step()    { printf "${BLUE}[%s]${NC} %s\n" "$1" "$2"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$1"; }
fail()    { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

# ─── 1. Docker ────────────────────────────────────────────────────────
step "1/5" "Checking Docker..."
command -v docker >/dev/null 2>&1 || fail "Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop"
docker info >/dev/null 2>&1 || fail "Docker daemon not reachable. Open Docker Desktop and wait until it's ready."
success "Docker is ready"

# ─── 2. Port check ────────────────────────────────────────────────────
step "2/5" "Checking port $PORT..."
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    PORT=$((PORT + 1))
  done
  warn "Original port was in use. Falling back to $PORT."
fi
success "Will bind on host port $PORT"

# ─── 3. Pull image ────────────────────────────────────────────────────
step "3/5" "Pulling $IMAGE (this is fast on a warm cache, ~600MB first time)..."
docker pull "$IMAGE"
success "Image ready"

# ─── 4. Stop existing container ───────────────────────────────────────
step "4/5" "Cleaning up any existing $CONTAINER_NAME container..."
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  success "Removed previous container (data in volume $VOLUME_NAME preserved)"
else
  success "No previous container"
fi

# ─── 5. Run + wait for health ─────────────────────────────────────────
step "5/5" "Starting $CONTAINER_NAME on port $PORT..."
EFFECTIVE_AUTH_URL="${AUTH_URL:-http://localhost:$PORT}"
CONTAINER_ID=$(docker run -d \
  -v "$VOLUME_NAME:/data" \
  -p "$PORT:3000" \
  -e "AUTH_URL=$EFFECTIVE_AUTH_URL" \
  --name "$CONTAINER_NAME" \
  "$IMAGE")
success "Container started (${CONTAINER_ID:0:12})"

printf "  Waiting for health (up to ${HEALTH_TIMEOUT_SEC}s)"
for i in $(seq 1 "$HEALTH_TIMEOUT_SEC"); do
  if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    printf "\n"
    success "App is healthy"
    break
  fi
  printf "."
  if [ "$i" = "$HEALTH_TIMEOUT_SEC" ]; then
    printf "\n"
    fail "App never became healthy. Inspect with: docker logs $CONTAINER_NAME"
  fi
  sleep 1
done

# ─── Summary ──────────────────────────────────────────────────────────
URL="http://localhost:$PORT"
printf "\n${BOLD}${GREEN}━━━ pfd-saas is running ━━━${NC}\n\n"
printf "  Open:     ${BOLD}%s${NC}\n" "$URL"
printf "  Logs:     docker logs -f %s\n" "$CONTAINER_NAME"
printf "  Stop:     docker stop %s\n" "$CONTAINER_NAME"
printf "  Restart:  docker start %s\n" "$CONTAINER_NAME"
printf "  Upgrade:  curl -fsSL https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/install.sh | bash\n"
printf "  Wipe:     docker stop %s && docker rm %s && docker volume rm %s\n" \
  "$CONTAINER_NAME" "$CONTAINER_NAME" "$VOLUME_NAME"
printf "\n"

if command -v open >/dev/null 2>&1 && [ "$(uname)" = "Darwin" ]; then
  open "$URL"
fi
