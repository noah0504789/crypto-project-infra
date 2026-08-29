#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-outbox-poller"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-outbox-poller"
CURRENT_IMAGE_FILE=".deploy/outbox-poller.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"
# GC 를 명시한다. MEM_LIMIT 이 1792m 미만이면 JVM 이 server class 가 아니라고 판정해
# SerialGC 로 떨어진다. CPU 가 12개여도 GC 스레드는 하나뿐이라 full GC 가 초 단위로 멈춘다
# (실측 major GC 평균 6.5초, 세 서비스 중 최악). 경고가 남지 않아 지표를 보기 전까지
# 드러나지 않는다. 힙이 500m 남짓이라 region 오버헤드가 있는 G1 보다 ParallelGC 가 맞다.
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms256m -Xmx512m -XX:+UseParallelGC"}"
MEM_LIMIT="${MEM_LIMIT:-768m}"
HEALTH_PORT="${HEALTH_PORT:-9200}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health/liveness}"
HEALTHCHECK_IMAGE="${HEALTHCHECK_IMAGE:-curlimages/curl:8.12.1}"

mkdir -p .deploy

if [[ ! -s "$CURRENT_IMAGE_FILE" ]]; then
  echo "ERROR: $CURRENT_IMAGE_FILE does not exist or is empty."
  echo "Create it first with the current stable image digest."
  echo ""
  echo "Example:"
  echo "  echo \"${IMAGE_REPOSITORY}@sha256:<digest>\" > $CURRENT_IMAGE_FILE"
  exit 1
fi

PREVIOUS_IMAGE="$(cat "$CURRENT_IMAGE_FILE")"

echo "========================================"
echo "Safe recreate deploy"
echo "service        : $SERVICE"
echo "new image      : $NEW_IMAGE"
echo "previous image : $PREVIOUS_IMAGE"
echo "network        : $DOCKER_NETWORK"
echo "mem limit      : $MEM_LIMIT"
echo "health url     : http://${SERVICE}:${HEALTH_PORT}${HEALTH_PATH}"
echo "========================================"

remove_container() {
  local name="$1"

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "Removing container: $name"
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
}

run_container() {
  local image="$1"

  echo "Starting $SERVICE from image: $image"

  docker run -d \
    --name "$SERVICE" \
    --hostname "$SERVICE" \
    --network "$DOCKER_NETWORK" \
    --memory "$MEM_LIMIT" \
    --label "app=${SERVICE}" \
    --label "deploy.strategy=safe-recreate" \
    --label "deploy.managed-by=infra-script" \
    -e "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}" \
    "$image" >/dev/null
}

wait_for_liveness() {
  echo "Waiting for liveness: http://${SERVICE}:${HEALTH_PORT}${HEALTH_PATH}"

  docker run --rm \
    --network "$DOCKER_NETWORK" \
    "$HEALTHCHECK_IMAGE" \
    --fail \
    --silent \
    --show-error \
    --retry 29 \
    --retry-all-errors \
    --retry-delay 2 \
    --retry-max-time 90 \
    --connect-timeout 2 \
    --max-time 5 \
    "http://${SERVICE}:${HEALTH_PORT}${HEALTH_PATH}" >/dev/null
}

has_suspicious_logs() {
  docker logs --tail=200 "$SERVICE" 2>&1 \
    | grep -E "Application run failed|Exception encountered during context initialization|OutOfMemoryError" >/dev/null
}

show_diagnostics() {
  docker ps -a --filter "name=^/${SERVICE}$" --format "table {{.Names}}\t{{.Status}}" || true
  docker logs --tail=200 "$SERVICE" || true
}

rollback() {
  echo "Rolling back to previous image:"
  echo "$PREVIOUS_IMAGE"

  remove_container "$SERVICE"
  if ! run_container "$PREVIOUS_IMAGE"; then
    echo "CRITICAL: failed to start rollback container."
    return 1
  fi

  if ! wait_for_liveness; then
    echo "CRITICAL: rollback image failed liveness validation."
    show_diagnostics
    return 1
  fi

  if has_suspicious_logs; then
    echo "CRITICAL: rollback image produced suspicious failure logs."
    show_diagnostics
    return 1
  fi

  echo "Rollback completed and passed liveness validation."
}

fail_deployment() {
  local reason="$1"

  echo "ERROR: $reason"
  show_diagnostics

  if ! rollback; then
    echo "CRITICAL: deployment and rollback both failed. Manual recovery is required."
  fi

  exit 1
}

echo "Pulling deployment images..."
docker pull "$NEW_IMAGE"
docker pull "$HEALTHCHECK_IMAGE"

echo "Deploying new image..."
remove_container "$SERVICE"
run_container "$NEW_IMAGE"

if ! wait_for_liveness; then
  fail_deployment "$SERVICE failed liveness validation."
fi

if has_suspicious_logs; then
  fail_deployment "$SERVICE produced suspicious failure logs."
fi

echo "Deploy passed liveness validation."

CURRENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$SERVICE")"

CURRENT_DIGEST="$(
  docker image inspect "$CURRENT_IMAGE_ID" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    | grep "^${IMAGE_REPOSITORY}@sha256:" \
    | head -n 1
)"

if [[ -z "$CURRENT_DIGEST" ]]; then
  echo "ERROR: failed to resolve current image digest."
  echo "Current image id: $CURRENT_IMAGE_ID"
  echo "Repo digests:"
  docker image inspect "$CURRENT_IMAGE_ID" --format '{{range .RepoDigests}}{{println .}}{{end}}' || true

  fail_deployment "failed to resolve current image digest."
fi

echo "$CURRENT_DIGEST" > "$CURRENT_IMAGE_FILE"

echo "Updated current stable image:"
echo "$CURRENT_DIGEST"

echo "Current status:"
docker ps --filter "name=^/${SERVICE}$" --format "table {{.Names}}\t{{.Status}}"

echo "Recent logs:"
docker logs --tail=100 "$SERVICE"
