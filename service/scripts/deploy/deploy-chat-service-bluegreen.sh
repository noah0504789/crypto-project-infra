#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-chat-service"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-chat-service"

CONTAINER_PORT="8080"

# blue scale 1  -> 8180
# green scale 1 -> 8280
BLUE_PORT_START="8180"
GREEN_PORT_START="8280"

REMOTE_DEBUG_ENABLED="${REMOTE_DEBUG_ENABLED:-false}"
REMOTE_DEBUG_PORT_OFFSET="${REMOTE_DEBUG_PORT_OFFSET:-20000}"
REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-}"
REMOTE_DEBUG_SLOT_OFFSET="${REMOTE_DEBUG_SLOT_OFFSET:-5}"
REMOTE_DEBUG_SUSPEND="${REMOTE_DEBUG_SUSPEND:-n}"

JAVA_TOOL_OPTIONS="-Xms256m -Xmx512m -XX:MaxDirectMemorySize=256m"
MEM_LIMIT="1024m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

if [[ "$TARGET_SCALE" != "current" && "$TARGET_SCALE" != "1" ]]; then
  echo "ERROR: crypto-chat-service currently supports only scale=current or scale=1."
  echo "Reason: controller, Kafka binder, and scheduler are bundled in one process."
  exit 1
fi

HEALTH_PATH="/api/v1/actuator/health/liveness"
DEPLOYMENT_BASE_PATH="/api/v1/internal/deployment"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SERVICE_NAME
export IMAGE_REPOSITORY
export CONTAINER_PORT
export BLUE_PORT_START
export GREEN_PORT_START
export REMOTE_DEBUG_ENABLED
export REMOTE_DEBUG_PORT_OFFSET
export REMOTE_DEBUG_PORT
export REMOTE_DEBUG_SLOT_OFFSET
export REMOTE_DEBUG_SUSPEND
export JAVA_TOOL_OPTIONS
export MEM_LIMIT
export TARGET_SCALE
export HEALTH_PATH
export DEPLOYMENT_BASE_PATH

exec "$SCRIPT_DIR/bluegreen-core.sh" "${1:-latest}"
