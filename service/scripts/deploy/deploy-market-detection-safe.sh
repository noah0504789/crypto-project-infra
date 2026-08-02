#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-market-detection"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-market-detection"
CURRENT_IMAGE_FILE=".deploy/market-detection.current-image"

NEW_TAG="${1:-latest}"
NEW_IMAGE="${IMAGE_REPOSITORY}:${NEW_TAG}"

DOCKER_NETWORK="${DOCKER_NETWORK:-crypto-project-network}"
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Xms256m -Xmx512m"}"
MEM_LIMIT="${MEM_LIMIT:-768m}"

mkdir -p .deploy

if [[ ! -f "$CURRENT_IMAGE_FILE" ]]; then
  echo "ERROR: $CURRENT_IMAGE_FILE does not exist."
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

rollback() {
  echo "Rolling back to previous image:"
  echo "$PREVIOUS_IMAGE"

  remove_container "$SERVICE"
  run_container "$PREVIOUS_IMAGE"

  echo "Rollback status:"
  docker ps --filter "name=^/${SERVICE}$" --format "table {{.Names}}\t{{.Status}}" || true

  echo "Rollback logs:"
  docker logs --tail=120 "$SERVICE" || true
}

echo "Pulling new image..."
docker pull "$NEW_IMAGE"

echo "Deploying new image..."
remove_container "$SERVICE"
run_container "$NEW_IMAGE"

echo "Checking container status..."
sleep 15

if ! docker ps -a --format '{{.Names}}' | grep -qx "$SERVICE"; then
  echo "ERROR: container not found."
  rollback
  exit 1
fi

STATUS="$(docker inspect -f '{{.State.Status}}' "$SERVICE")"
EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$SERVICE")"

if [[ "$STATUS" != "running" ]]; then
  echo "ERROR: $SERVICE is not running. status=$STATUS exitCode=$EXIT_CODE"
  echo "Recent logs:"
  docker logs --tail=150 "$SERVICE" || true

  rollback
  exit 1
fi

if docker logs --tail=200 "$SERVICE" | grep -E "Application run failed|Exception encountered during context initialization|OutOfMemoryError" >/dev/null; then
  echo "ERROR: suspicious failure log detected."
  docker logs --tail=200 "$SERVICE" || true

  rollback
  exit 1
fi

echo "Deploy looks successful."

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

  rollback
  exit 1
fi

echo "$CURRENT_DIGEST" > "$CURRENT_IMAGE_FILE"

echo "Updated current stable image:"
echo "$CURRENT_DIGEST"

echo "Current status:"
docker ps --filter "name=^/${SERVICE}$" --format "table {{.Names}}\t{{.Status}}"

echo "Recent logs:"
docker logs --tail=100 "$SERVICE"
