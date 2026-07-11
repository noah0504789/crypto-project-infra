#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-spring-cloud-eureka-server"
CANDIDATE_SERVICE="crypto-spring-cloud-eureka-server-candidate"

IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-spring-cloud-eureka-server"
CURRENT_IMAGE_FILE=".deploy/eureka-server.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

CONTAINER_PORT="8761"
PUBLIC_PORT="8761"
CANDIDATE_PORT="18761"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"

HEALTH_SCHEME="${HEALTH_SCHEME:-http}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health/liveness}"
CURL_INSECURE="${CURL_INSECURE:-false}"

DEPLOYMENT_BASE_PATH="${DEPLOYMENT_BASE_PATH:-/internal/deployment}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"

JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms128m -Xmx256m"}"
MEM_LIMIT="${MEM_LIMIT:-512m}"

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

  if [[ -z "$DEPLOY_TOKEN" ]]; then
    log "ERROR: DEPLOY_TOKEN is empty."
    return 1
  fi

  if curl $curl_opts \
    -X POST \
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

  container_id="$(
    docker ps -q \
      --filter "name=^/${container_name}$"
  )"

  if [[ -z "$container_id" ]]; then
    return 1
  fi

  image_id="$(
    docker inspect \
      -f '{{.Image}}' \
      "$container_id"
  )"

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

run_eureka_server_container() {
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
    -e "DEPLOY_TOKEN=${DEPLOY_TOKEN}" \
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

  log "Rolling back Eureka Server to previous image:"
  log "$previous_image"

  remove_container "$SERVICE"

  run_eureka_server_container \
    "$SERVICE" \
    "$PUBLIC_PORT" \
    "$previous_image"

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
  log "Eureka Server validated recreate deploy"
  log "service        : $SERVICE"
  log "candidate      : $CANDIDATE_SERVICE"
  log "new image      : $NEW_IMAGE"
  log "public port    : $PUBLIC_PORT"
  log "candidate port : $CANDIDATE_PORT"
  log "health url     : ${HEALTH_SCHEME}://localhost:<port>${HEALTH_PATH}"
  log "deploy url     : ${HEALTH_SCHEME}://localhost:<port>${DEPLOYMENT_BASE_PATH}/ready"
  log "curl insecure  : $CURL_INSECURE"
  log "========================================"

  if [[ -z "$DEPLOY_TOKEN" ]]; then
    log "ERROR: DEPLOY_TOKEN is empty."
    exit 1
  fi

  if [[ ! -f "$CURRENT_IMAGE_FILE" ]]; then
    log "ERROR: $CURRENT_IMAGE_FILE does not exist."
    log "Create it first with the current stable Eureka Server image digest."
    log ""
    log "Example:"
    log "  echo \"${IMAGE_REPOSITORY}@sha256:<digest>\" > $CURRENT_IMAGE_FILE"
    exit 1
  fi

  log "Pulling new image: $NEW_IMAGE"
  docker pull "$NEW_IMAGE"

  log "Cleaning old candidate container."
  remove_container "$CANDIDATE_SERVICE"

  log "Starting candidate container."

  run_eureka_server_container \
    "$CANDIDATE_SERVICE" \
    "$CANDIDATE_PORT" \
    "$NEW_IMAGE"

  if ! wait_for_health "$CANDIDATE_PORT"; then
    log "ERROR: candidate health check failed."
    log "Keeping current Eureka Server unchanged."
    log "Candidate logs:"
    docker logs --tail=150 "$CANDIDATE_SERVICE" || true

    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  if ! mark_ready "$CANDIDATE_PORT"; then
    log "ERROR: candidate failed to mark ready."
    log "Keeping current Eureka Server unchanged."
    log "Candidate logs:"
    docker logs --tail=150 "$CANDIDATE_SERVICE" || true

    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  log "Candidate is healthy and ready."

  log "Replacing public Eureka Server container on port $PUBLIC_PORT."

  remove_container "$SERVICE"

  run_eureka_server_container \
    "$SERVICE" \
    "$PUBLIC_PORT" \
    "$NEW_IMAGE"

  if ! wait_for_health "$PUBLIC_PORT"; then
    log "ERROR: new public Eureka Server failed health check."
    log "New public container logs:"
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
    log "ERROR: new public Eureka Server failed to mark ready."
    log "New public container logs:"
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

  log "New public Eureka Server is healthy and ready."

  local current_digest
  current_digest="$(resolve_running_image_digest "$SERVICE")"

  if [[ -z "$current_digest" ]]; then
    log "ERROR: failed to resolve current Eureka Server image digest."
    log "Trying rollback..."

    if ! rollback; then
      log "ERROR: rollback failed. Manual intervention required."
      remove_container "$CANDIDATE_SERVICE"
      exit 1
    fi

    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  echo "$current_digest" > "$CURRENT_IMAGE_FILE"

  log "Updated current stable image:"
  log "$current_digest"

  remove_container "$CANDIDATE_SERVICE"

  log "Deploy success."

  docker ps \
    --filter "name=^/${SERVICE}$" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main