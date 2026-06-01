#!/usr/bin/env bash
set -euo pipefail

: "${SERVICE_NAME:?SERVICE_NAME is required}"
: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${CONTAINER_PORT:?CONTAINER_PORT is required}"
: "${BLUE_PORT_START:?BLUE_PORT_START is required}"
: "${GREEN_PORT_START:?GREEN_PORT_START is required}"
: "${JAVA_TOOL_OPTIONS:?JAVA_TOOL_OPTIONS is required}"
: "${MEM_LIMIT:?MEM_LIMIT is required}"

IMAGE_TAG="${1:-latest}"
IMAGE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"
DEFAULT_SCALE="${DEFAULT_SCALE:-1}"
HEALTH_PATH="${HEALTH_PATH:-/api/v1/actuator/health}"
DEPLOYMENT_BASE_PATH="${DEPLOYMENT_BASE_PATH:-/api/v1/internal/deployment}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"
DRAIN_SECONDS="${DRAIN_SECONDS:-15}"

ACTIVE_SLOT_FILE=".deploy/${SERVICE_NAME}.active-slot"

mkdir -p .deploy

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

container_name() {
  local slot="$1"
  local index="$2"
  echo "${SERVICE_NAME}-${slot}-${index}"
}

slot_port_start() {
  local slot="$1"

  if [[ "$slot" == "blue" ]]; then
    echo "$BLUE_PORT_START"
  elif [[ "$slot" == "green" ]]; then
    echo "$GREEN_PORT_START"
  else
    echo "0"
  fi
}

validate_active_slot_file() {
  if [[ ! -f "$ACTIVE_SLOT_FILE" ]]; then
    return 0
  fi

  local slot
  slot="$(cat "$ACTIVE_SLOT_FILE")"

  if [[ "$slot" != "blue" && "$slot" != "green" ]]; then
    log "ERROR: invalid active slot value in $ACTIVE_SLOT_FILE: $slot"
    exit 1
  fi
}

detect_active_slot() {
  validate_active_slot_file

  if [[ -f "$ACTIVE_SLOT_FILE" ]]; then
    cat "$ACTIVE_SLOT_FILE"
    return
  fi

  local blue_count
  local green_count

  blue_count="$(docker ps --filter "name=^/${SERVICE_NAME}-blue-" --format '{{.Names}}' | wc -l | tr -d ' ')"
  green_count="$(docker ps --filter "name=^/${SERVICE_NAME}-green-" --format '{{.Names}}' | wc -l | tr -d ' ')"

  if [[ "$blue_count" -gt 0 && "$green_count" -gt 0 ]]; then
    log "ERROR: both blue and green containers are running, but active-slot file does not exist."
    log "Create $ACTIVE_SLOT_FILE manually with either 'blue' or 'green'."
    exit 1
  fi

  if [[ "$blue_count" -gt 0 ]]; then
    echo "blue"
  elif [[ "$green_count" -gt 0 ]]; then
    echo "green"
  else
    echo "none"
  fi
}

opposite_slot() {
  local slot="$1"

  if [[ "$slot" == "blue" ]]; then
    echo "green"
  else
    echo "blue"
  fi
}

running_scale() {
  local slot="$1"

  if [[ "$slot" == "none" ]]; then
    echo "$DEFAULT_SCALE"
    return
  fi

  local count
  count="$(docker ps --filter "name=^/${SERVICE_NAME}-${slot}-" --format '{{.Names}}' | wc -l | tr -d ' ')"

  if [[ "$count" -eq 0 ]]; then
    echo "$DEFAULT_SCALE"
  else
    echo "$count"
  fi
}

validate_scale() {
  local scale="$1"

  if ! [[ "$scale" =~ ^[0-9]+$ ]]; then
    log "ERROR: invalid scale: $scale"
    exit 1
  fi

  if [[ "$scale" -lt 1 ]]; then
    log "ERROR: scale must be greater than 0: $scale"
    exit 1
  fi
}

validate_port_ranges() {
  local scale="$1"
  local blue_start="$BLUE_PORT_START"
  local green_start="$GREEN_PORT_START"
  local blue_end="$((blue_start + scale - 1))"
  local green_end="$((green_start + scale - 1))"

  if [[ "$blue_start" -le "$green_end" && "$green_start" -le "$blue_end" ]]; then
    log "ERROR: blue/green port ranges overlap."
    log "blue : ${blue_start}-${blue_end}"
    log "green: ${green_start}-${green_end}"
    exit 1
  fi

  log "blue port range : ${blue_start}-${blue_end}"
  log "green port range: ${green_start}-${green_end}"
}

remove_slot_containers() {
  local slot="$1"

  docker ps -a \
    --filter "name=^/${SERVICE_NAME}-${slot}-" \
    --format '{{.Names}}' |
  while IFS= read -r container; do
    if [[ -n "$container" ]]; then
      log "Removing container: $container"
      docker rm -f "$container" >/dev/null 2>&1 || true
    fi
  done
}

wait_for_health() {
  local port="$1"
  local url="http://localhost:${port}${HEALTH_PATH}"

  for attempt in {1..40}; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "Health check passed: $url"
      return 0
    fi

    log "Waiting for health: $url attempt=$attempt"
    sleep 3
  done

  log "ERROR: health check failed: $url"
  return 1
}

deployment_post() {
  local port="$1"
  local action="$2"
  local url="http://localhost:${port}${DEPLOYMENT_BASE_PATH}/${action}"

  if [[ -z "$DEPLOY_TOKEN" ]]; then
    log "DEPLOY_TOKEN is empty. Skipping deployment action: $url"
    return 0
  fi

  curl -fsS -X POST \
    -H "X-Deploy-Token: ${DEPLOY_TOKEN}" \
    "$url" >/dev/null

  log "Deployment action success: $url"
}

mark_slot_ready() {
  local slot="$1"
  local scale="$2"
  local port_start

  port_start="$(slot_port_start "$slot")"

  for ((i = 1; i <= scale; i++)); do
    deployment_post "$((port_start + i - 1))" "ready"
  done
}

mark_slot_not_ready() {
  local slot="$1"
  local scale="$2"
  local port_start

  if [[ "$slot" == "none" ]]; then
    return 0
  fi

  port_start="$(slot_port_start "$slot")"

  for ((i = 1; i <= scale; i++)); do
    deployment_post "$((port_start + i - 1))" "not-ready" || true
  done
}

stop_slot() {
  local slot="$1"

  if [[ "$slot" == "none" ]]; then
    return 0
  fi

  remove_slot_containers "$slot"
}

stop_legacy_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$SERVICE_NAME"; then
    log "Stopping legacy compose container: $SERVICE_NAME"
    docker rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

start_slot() {
  local slot="$1"
  local scale="$2"
  local port_start

  port_start="$(slot_port_start "$slot")"

  for ((i = 1; i <= scale; i++)); do
    local name
    local host_port

    name="$(container_name "$slot" "$i")"
    host_port="$((port_start + i - 1))"

    log "Starting $name with host port $host_port -> container port $CONTAINER_PORT"

    docker run -d \
      --name "$name" \
      --network "$DOCKER_NETWORK" \
      --memory "$MEM_LIMIT" \
      --label "app=${SERVICE_NAME}" \
      --label "deploy.strategy=bluegreen" \
      --label "deploy.slot=${slot}" \
      --label "deploy.index=${i}" \
      --label "deploy.managed-by=infra-script" \
      -p "${host_port}:${CONTAINER_PORT}" \
      -e "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}" \
      "$IMAGE" >/dev/null
  done
}

main() {
  log "========================================"
  log "Blue/green deploy"
  log "service       : $SERVICE_NAME"
  log "image         : $IMAGE"
  log "network       : $DOCKER_NETWORK"
  log "container port: $CONTAINER_PORT"
  log "health path   : $HEALTH_PATH"
  log "========================================"

  local active_slot
  local next_slot
  local target_scale
  local next_port_start

  active_slot="$(detect_active_slot)"

  if [[ "$active_slot" == "none" ]]; then
    next_slot="blue"
  else
    next_slot="$(opposite_slot "$active_slot")"
  fi

  target_scale="$(running_scale "$active_slot")"
  validate_scale "$target_scale"
  validate_port_ranges "$target_scale"

  next_port_start="$(slot_port_start "$next_slot")"

  log "active slot : $active_slot"
  log "next slot   : $next_slot"
  log "scale       : $target_scale"

  log "Pulling image: $IMAGE"
  docker pull "$IMAGE"

  log "Cleaning next slot before deploy: $next_slot"
  remove_slot_containers "$next_slot"

  if ! start_slot "$next_slot" "$target_scale"; then
    log "ERROR: failed to start next slot: $next_slot"
    remove_slot_containers "$next_slot"
    exit 1
  fi

  for ((i = 1; i <= target_scale; i++)); do
    if ! wait_for_health "$((next_port_start + i - 1))"; then
      log "ERROR: next slot health check failed. Keeping active slot unchanged: $active_slot"
      remove_slot_containers "$next_slot"
      exit 1
    fi
  done

  if ! mark_slot_ready "$next_slot" "$target_scale"; then
    log "ERROR: failed to mark next slot ready. Keeping active slot unchanged: $active_slot"
    remove_slot_containers "$next_slot"
    exit 1
  fi

  stop_legacy_container

  if [[ "$active_slot" != "none" ]]; then
    local active_scale
    active_scale="$(running_scale "$active_slot")"

    mark_slot_not_ready "$active_slot" "$active_scale"

    log "Draining old slot for ${DRAIN_SECONDS}s..."
    sleep "$DRAIN_SECONDS"

    stop_slot "$active_slot"
  fi

  echo "$next_slot" > "$ACTIVE_SLOT_FILE"

  log "Deploy success."
  log "active slot updated: $next_slot"
  docker ps \
    --filter "label=app=${SERVICE_NAME}" \
    --filter "label=deploy.slot=${next_slot}" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main