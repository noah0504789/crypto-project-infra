#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-spring-cloud-config"
CANDIDATE_SERVICE="crypto-spring-cloud-config-candidate"

IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-spring-cloud-config"
CURRENT_IMAGE_FILE=".deploy/spring-cloud-config.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

CONTAINER_PORT="8888"
PUBLIC_PORT="8888"
CANDIDATE_PORT="8898"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"
HEALTH_SCHEME="${HEALTH_SCHEME:-http}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health/liveness}"
CURL_INSECURE="${CURL_INSECURE:-false}"

DEPLOYMENT_BASE_PATH="${DEPLOYMENT_BASE_PATH:-/internal/deployment}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"

JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms256m -Xmx384m"}"
MEM_LIMIT="${MEM_LIMIT:-512m}"

CONFIG_REPO_URI="${CONFIG_REPO_URI:-}"
CONFIG_REPO_ROOT="${CONFIG_REPO_ROOT:-git-config-repo}"

VAULT_ROLE_ID="${VAULT_ROLE_ID:-}"
VAULT_SECRET_ID="${VAULT_SECRET_ID:-}"

KAFKA_BROKERS="${KAFKA_BROKERS:-kafka-0:9092,kafka-1:9092}"

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

require_environment() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    log "ERROR: required environment variable is empty: $name"
    exit 1
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
    log "DEPLOY_TOKEN is empty. Skipping deployment action: $url"
    return 0
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

run_config_server_container() {
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
    -e "CONFIG_REPO_URI=${CONFIG_REPO_URI}" \
    -e "CONFIG_REPO_ROOT=${CONFIG_REPO_ROOT}" \
    -e "VAULT_ROLE_ID=${VAULT_ROLE_ID}" \
    -e "VAULT_SECRET_ID=${VAULT_SECRET_ID}" \
    -e "KAFKA_BROKERS=${KAFKA_BROKERS}" \
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

  log "Rolling back Spring Cloud Config to previous image:"
  log "$previous_image"

  remove_container "$SERVICE"

  run_config_server_container \
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
  log "Spring Cloud Config validated recreate deploy"
  log "service          : $SERVICE"
  log "candidate        : $CANDIDATE_SERVICE"
  log "new image        : $NEW_IMAGE"
  log "public port      : $PUBLIC_PORT"
  log "candidate port   : $CANDIDATE_PORT"
  log "health url       : ${HEALTH_SCHEME}://localhost:<port>${HEALTH_PATH}"
  log "deploy url       : ${HEALTH_SCHEME}://localhost:<port>${DEPLOYMENT_BASE_PATH}/ready"
  log "curl insecure    : $CURL_INSECURE"
  log "config repo root : $CONFIG_REPO_ROOT"
  log "Kafka brokers    : $KAFKA_BROKERS"
  log "========================================"

  require_environment "CONFIG_REPO_URI" "$CONFIG_REPO_URI"
  require_environment "VAULT_ROLE_ID" "$VAULT_ROLE_ID"
  require_environment "VAULT_SECRET_ID" "$VAULT_SECRET_ID"

  if [[ ! -f "$CURRENT_IMAGE_FILE" ]]; then
    log "ERROR: $CURRENT_IMAGE_FILE does not exist."
    log "Create it first with the current stable Spring Cloud Config image digest."
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
  run_config_server_container \
    "$CANDIDATE_SERVICE" \
    "$CANDIDATE_PORT" \
    "$NEW_IMAGE"

  if ! wait_for_health "$CANDIDATE_PORT"; then
    log "ERROR: candidate health check failed."
    log "Keeping current Spring Cloud Config unchanged."
    log "Candidate logs:"
    docker logs --tail=150 "$CANDIDATE_SERVICE" || true
    remove_container "$CANDIDATE_SERVICE"
    exit 1
  fi

  log "Candidate looks healthy."

  log "Replacing public Spring Cloud Config container on port $PUBLIC_PORT."

  remove_container "$SERVICE"

  run_config_server_container \
    "$SERVICE" \
    "$PUBLIC_PORT" \
    "$NEW_IMAGE"

  if ! wait_for_health "$PUBLIC_PORT"; then
    log "ERROR: new public Spring Cloud Config failed health check."
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
    log "ERROR: new public Spring Cloud Config failed to mark ready."
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

  log "New public Spring Cloud Config is healthy and ready."

  local current_digest
  current_digest="$(resolve_running_image_digest "$SERVICE")"

  if [[ -z "$current_digest" ]]; then
    log "ERROR: failed to resolve current Spring Cloud Config image digest."
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