#!/usr/bin/env bash
set -euo pipefail

SERVICE="crypto-outbox-poller"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-outbox-poller"
CURRENT_IMAGE_FILE=".deploy/outbox-poller.current-image"

NEW_TAG="${1:-latest}"

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
echo "new tag        : $NEW_TAG"
echo "previous image : $PREVIOUS_IMAGE"
echo "========================================"

rollback() {
  echo "Rolling back to previous image:"
  echo "$PREVIOUS_IMAGE"

  OUTBOX_POLLER_IMAGE="$PREVIOUS_IMAGE" \
  OUTBOX_POLLER_IMAGE_TAG="" \
  docker compose up -d --force-recreate "$SERVICE"

  echo "Rollback status:"
  docker compose ps "$SERVICE" || true

  echo "Rollback logs:"
  docker compose logs --tail=120 "$SERVICE" || true
}

echo "Pulling new image..."
OUTBOX_POLLER_IMAGE_TAG="$NEW_TAG" \
OUTBOX_POLLER_IMAGE="" \
docker compose pull "$SERVICE"

echo "Deploying new image..."
OUTBOX_POLLER_IMAGE_TAG="$NEW_TAG" \
OUTBOX_POLLER_IMAGE="" \
docker compose up -d --force-recreate "$SERVICE"

echo "Checking container status..."
sleep 15

CONTAINER_ID="$(docker compose ps -q "$SERVICE")"

if [[ -z "$CONTAINER_ID" ]]; then
  echo "ERROR: container id not found."
  rollback
  exit 1
fi

STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_ID")"
EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_ID")"

if [[ "$STATUS" != "running" ]]; then
  echo "ERROR: $SERVICE is not running. status=$STATUS exitCode=$EXIT_CODE"
  echo "Recent logs:"
  docker logs --tail=150 "$CONTAINER_ID" || true

  rollback
  exit 1
fi

if docker logs --tail=200 "$CONTAINER_ID" | grep -E "Application run failed|Exception encountered during context initialization|OutOfMemoryError" >/dev/null; then
  echo "ERROR: suspicious failure log detected."
  docker logs --tail=200 "$CONTAINER_ID" || true

  rollback
  exit 1
fi

echo "Deploy looks successful."

CURRENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER_ID")"

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
docker compose ps "$SERVICE"

echo "Recent logs:"
docker compose logs --tail=100 "$SERVICE"