#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-oauth2-authorization-server"
CANDIDATE_SERVICE="crypto-oauth2-authorization-server-candidate"

IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-oauth2-authorization-server"
CURRENT_IMAGE_FILE=".deploy/oauth2-authorization-server.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

CONTAINER_PORT="9000"
PUBLIC_PORT="9000"
CANDIDATE_PORT="${CANDIDATE_PORT:-9010}"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"

HEALTH_SCHEME="${HEALTH_SCHEME:-http}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health/liveness}"
CURL_INSECURE="${CURL_INSECURE:-false}"

DEPLOYMENT_BASE_PATH="${DEPLOYMENT_BASE_PATH:-/internal/deployment}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:?DEPLOY_TOKEN is required}"

JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms256m -Xmx384m"}"
MEM_LIMIT="${MEM_LIMIT:-768m}"

mkdir -p .deploy

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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

cleanup_legacy_bluegreen_containers() {
  log "Cleaning legacy blue/green containers for $SERVICE"

  for slot in blue green; do
    for index in {1..10}; do
      remove_container "${SERVICE}-${slot}-${index}"
    done
  done
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

  log "Starting $name with host port $host_port -> container port $CONTAINER_PORT"

  docker run -d \
    --name "$name" \
    --hostname "$name" \
    --network "$DOCKER_NETWORK" \
    --memory "$MEM_LIMIT" \
    --label "app=${SERVICE}" \
    --label "deploy.strategy=validated-recreate" \
    --label "deploy.managed-by=infra-script" \
    -p "${host_port}:${CONTAINER_PORT}" \
    -e "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}" \
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
  log "========================================"
  log "OAuth2 Authorization Server validated recreate deploy"
  log "service        : $SERVICE"
  log "candidate      : $CANDIDATE_SERVICE"
  log "new image      : $NEW_IMAGE"
  log "public port    : $PUBLIC_PORT"
  log "candidate port : $CANDIDATE_PORT"
  log "health url     : ${HEALTH_SCHEME}://localhost:<port>${HEALTH_PATH}"
  log "deploy url     : ${HEALTH_SCHEME}://localhost:<port>${DEPLOYMENT_BASE_PATH}/ready"
  log "========================================"

  log "Pulling new image: $NEW_IMAGE"
  docker pull "$NEW_IMAGE"

  cleanup_legacy_bluegreen_containers

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