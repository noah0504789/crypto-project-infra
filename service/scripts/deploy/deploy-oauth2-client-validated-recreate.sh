#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-oauth2-client"
CANDIDATE_SERVICE="crypto-oauth2-client-candidate"

IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-oauth2-client"
CURRENT_IMAGE_FILE=".deploy/oauth2-client.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

CONTAINER_PORT="8900"
PUBLIC_PORT="8900"
CANDIDATE_PORT="${CANDIDATE_PORT:-8930}"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"

HEALTH_SCHEME="${HEALTH_SCHEME:-http}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health/liveness}"
CURL_INSECURE="${CURL_INSECURE:-false}"

DEPLOYMENT_BASE_PATH="${DEPLOYMENT_BASE_PATH:-/internal/deployment}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:?DEPLOY_TOKEN is required}"

BASE_JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms128m -Xmx256m"}"
MEM_LIMIT="${MEM_LIMIT:-768m}"

# 원격 디버깅 설정
# REMOTE_DEBUG_PORT를 직접 지정하면 계산된 값보다 우선한다.
REMOTE_DEBUG_ENABLED="${REMOTE_DEBUG_ENABLED:-false}"
REMOTE_DEBUG_PORT_OFFSET="${REMOTE_DEBUG_PORT_OFFSET:-20000}"
REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-$((PUBLIC_PORT + REMOTE_DEBUG_PORT_OFFSET))}"
REMOTE_DEBUG_SUSPEND="${REMOTE_DEBUG_SUSPEND:-n}"

if [[ "$REMOTE_DEBUG_ENABLED" == "true" ]]; then
  EFFECTIVE_JAVA_TOOL_OPTIONS="${BASE_JAVA_TOOL_OPTIONS} -agentlib:jdwp=transport=dt_socket,server=y,suspend=${REMOTE_DEBUG_SUSPEND},address=*:${REMOTE_DEBUG_PORT}"
else
  EFFECTIVE_JAVA_TOOL_OPTIONS="$BASE_JAVA_TOOL_OPTIONS"
fi

mkdir -p .deploy

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

validate_boolean() {
  local variable_name="$1"
  local value="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log "ERROR: ${variable_name} must be either true or false. value=${value}"
    exit 1
  fi
}

validate_port() {
  local variable_name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log "ERROR: ${variable_name} must be a number. value=${value}"
    exit 1
  fi

  if ((value < 1 || value > 65535)); then
    log "ERROR: ${variable_name} must be between 1 and 65535. value=${value}"
    exit 1
  fi
}

curl_base_opts() {
  if [[ "$CURL_INSECURE" == "true" ]]; then
    echo "-kfsS"
  else
    echo "-fsS"
  fi
}

wait_for_health() {
  local port="$1"
  local url="${HEALTH_SCHEME}://localhost:${port}${HEALTH_PATH}"
  local curl_opts
  curl_opts="$(curl_base_opts)"

  for attempt in {1..40}; do
    if curl $curl_opts "$url" >/dev/null 2>&1; then
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
  local url="${HEALTH_SCHEME}://localhost:${port}${DEPLOYMENT_BASE_PATH}/${action}"
  local curl_opts
  curl_opts="$(curl_base_opts)"

  if curl $curl_opts -X POST \
    -H "X-Deploy-Token: ${DEPLOY_TOKEN}" \
    "$url" >/dev/null; then
    log "Deployment action success: $url"
    return 0
  fi

  log "Deployment action failed: $url"
  return 1
}

mark_ready() {
  local port="$1"
  deployment_post "$port" "ready"
}

remove_container() {
  local name="$1"

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    log "Removing container: $name"
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
}

resolve_running_image_digest() {
  local container_name="$1"
  local container_id
  local image_id
  local digest

  container_id="$(docker ps -q --filter "name=^/${container_name}$")"

  if [[ -z "$container_id" ]]; then
    return 1
  fi

  image_id="$(docker inspect -f '{{.Image}}' "$container_id")"

  digest="$(
    docker image inspect "$image_id" \
      --format '{{range .RepoDigests}}{{println .}}{{end}}' \
      | grep "^${IMAGE_REPOSITORY}@sha256:" \
      | head -n 1
  )"

  if [[ -z "$digest" ]]; then
    return 1
  fi

  echo "$digest"
}

run_container() {
  local name="$1"
  local host_port="$2"
  local image="$3"

  local -a docker_port_options=(
    -p "${host_port}:${CONTAINER_PORT}"
  )

  # Candidate와 운영 컨테이너는 동시에 실행될 수 있다.
  # 따라서 호스트 디버깅 포트는 실제 운영 컨테이너에만 연결한다.
  #
  # 127.0.0.1로 바인딩하여 외부 네트워크에서 JDWP 포트에
  # 직접 접근하지 못하도록 제한한다.
  if [[ "$REMOTE_DEBUG_ENABLED" == "true" && "$name" == "$SERVICE" ]]; then
    docker_port_options+=(
      -p "127.0.0.1:${REMOTE_DEBUG_PORT}:${REMOTE_DEBUG_PORT}"
    )
  fi

  log "Starting $name with host port $host_port -> container port $CONTAINER_PORT"

  if [[ "$REMOTE_DEBUG_ENABLED" == "true" ]]; then
    if [[ "$name" == "$SERVICE" ]]; then
      log "Remote debug enabled: 127.0.0.1:${REMOTE_DEBUG_PORT}"
    else
      log "Remote debug enabled inside candidate container without host port exposure."
    fi
  fi

  docker run -d \
    --name "$name" \
    --hostname "$name" \
    --network "$DOCKER_NETWORK" \
    --memory "$MEM_LIMIT" \
    --label "app=${SERVICE}" \
    --label "deploy.strategy=validated-recreate" \
    --label "deploy.managed-by=infra-script" \
    --label "remote-debug.enabled=${REMOTE_DEBUG_ENABLED}" \
    --label "remote-debug.port=${REMOTE_DEBUG_PORT}" \
    "${docker_port_options[@]}" \
    -e "JAVA_TOOL_OPTIONS=${EFFECTIVE_JAVA_TOOL_OPTIONS}" \
    "$image" >/dev/null
}

rollback() {
  if [[ ! -f "$CURRENT_IMAGE_FILE" ]]; then
    log "ERROR: rollback image file does not exist: $CURRENT_IMAGE_FILE"
    return 1
  fi

  local previous_image
  previous_image="$(cat "$CURRENT_IMAGE_FILE")"

  if [[ -z "$previous_image" ]]; then
    log "ERROR: rollback image is empty."
    return 1
  fi

  log "Rolling back $SERVICE to previous image:"
  log "$previous_image"

  remove_container "$SERVICE"

  run_container "$SERVICE" "$PUBLIC_PORT" "$previous_image"

  if ! wait_for_health "$PUBLIC_PORT"; then
    log "ERROR: rollback container failed health check."
    docker logs --tail=150 "$SERVICE" || true
    return 1
  fi

  if ! mark_ready "$PUBLIC_PORT"; then
    log "ERROR: rollback container failed to mark ready."
    docker logs --tail=150 "$SERVICE" || true
    return 1
  fi

  log "Rollback success."
}

main() {
  validate_boolean "REMOTE_DEBUG_ENABLED" "$REMOTE_DEBUG_ENABLED"
  validate_port "CONTAINER_PORT" "$CONTAINER_PORT"
  validate_port "PUBLIC_PORT" "$PUBLIC_PORT"
  validate_port "CANDIDATE_PORT" "$CANDIDATE_PORT"

  if [[ "$REMOTE_DEBUG_ENABLED" == "true" ]]; then
    validate_port "REMOTE_DEBUG_PORT" "$REMOTE_DEBUG_PORT"

    if [[ "$REMOTE_DEBUG_PORT" == "$PUBLIC_PORT" ||
          "$REMOTE_DEBUG_PORT" == "$CANDIDATE_PORT" ]]; then
      log "ERROR: remote debug port conflicts with an application port."
      log "remote debug port : $REMOTE_DEBUG_PORT"
      log "public port       : $PUBLIC_PORT"
      log "candidate port    : $CANDIDATE_PORT"
      exit 1
    fi
  fi

  log "========================================"
  log "OAuth2 Client validated recreate deploy"
  log "service        : $SERVICE"
  log "candidate      : $CANDIDATE_SERVICE"
  log "new image      : $NEW_IMAGE"
  log "public port    : $PUBLIC_PORT"
  log "candidate port : $CANDIDATE_PORT"
  log "health url     : ${HEALTH_SCHEME}://localhost:<port>${HEALTH_PATH}"
  log "deploy url     : ${HEALTH_SCHEME}://localhost:<port>${DEPLOYMENT_BASE_PATH}/ready"
  log "remote debug   : $REMOTE_DEBUG_ENABLED"

  if [[ "$REMOTE_DEBUG_ENABLED" == "true" ]]; then
    log "debug rule     : public port + ${REMOTE_DEBUG_PORT_OFFSET}"
    log "debug port     : 127.0.0.1:${REMOTE_DEBUG_PORT}"
    log "debug suspend  : $REMOTE_DEBUG_SUSPEND"
  fi

  log "========================================"

  log "Pulling new image: $NEW_IMAGE"
  docker pull "$NEW_IMAGE"

  log "Cleaning old candidate container."
  remove_container "$CANDIDATE_SERVICE"

  log "Starting candidate container."
  run_container "$CANDIDATE_SERVICE" "$CANDIDATE_PORT" "$NEW_IMAGE"

  if ! wait_for_health "$CANDIDATE_PORT"; then
    log "ERROR: candidate health check failed. Keeping current $SERVICE unchanged."
    docker logs --tail=150 "$CANDIDATE_SERVICE" || true
    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  log "Candidate looks healthy."

  log "Replacing public $SERVICE container on port $PUBLIC_PORT."

  if docker ps -q --filter "name=^/${SERVICE}$" | grep -q .; then
    local current_digest
    if current_digest="$(resolve_running_image_digest "$SERVICE")"; then
      echo "$current_digest" > "$CURRENT_IMAGE_FILE"
      log "Stored previous stable image:"
      log "$current_digest"
    else
      log "WARN: failed to resolve previous image digest. Rollback may be unavailable."
    fi
  fi

  remove_container "$SERVICE"

  run_container "$SERVICE" "$PUBLIC_PORT" "$NEW_IMAGE"

  if ! wait_for_health "$PUBLIC_PORT"; then
    log "ERROR: new public $SERVICE failed health check."
    docker logs --tail=150 "$SERVICE" || true

    log "Trying rollback..."
    if ! rollback; then
      log "ERROR: rollback failed. Manual intervention required."
      remove_container "$CANDIDATE_SERVICE"
      exit 1
    fi

    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  if ! mark_ready "$PUBLIC_PORT"; then
    log "ERROR: new public $SERVICE failed to mark ready."
    docker logs --tail=150 "$SERVICE" || true

    log "Trying rollback..."
    if ! rollback; then
      log "ERROR: rollback failed. Manual intervention required."
      remove_container "$CANDIDATE_SERVICE"
      exit 1
    fi

    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  log "New public $SERVICE is healthy and ready."

  local new_digest
  new_digest="$(resolve_running_image_digest "$SERVICE")"

  if [[ -n "$new_digest" ]]; then
    echo "$new_digest" > "$CURRENT_IMAGE_FILE"
    log "Updated current stable image:"
    log "$new_digest"
  else
    log "WARN: failed to resolve new image digest."
  fi

  remove_container "$CANDIDATE_SERVICE"

  log "Deploy success."
  docker ps \
    --filter "name=^/${SERVICE}$" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main