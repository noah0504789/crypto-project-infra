#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-websocket-gateway"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-websocket-gateway"

CONTAINER_PORT="8100"

# blue scale 3  -> 8200, 8201, 8202
# green scale 3 -> 8300, 8301, 8302
BLUE_PORT_START="8200"
GREEN_PORT_START="8300"

JAVA_TOOL_OPTIONS="-Xms256m -Xmx512m"
MEM_LIMIT="768m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

HEALTH_PATH="/api/v1/actuator/health/liveness"
DEPLOYMENT_BASE_PATH="/api/v1/internal/deployment"

# WebSocket은 기존 연결이 있을 수 있으므로 user-service보다 길게 둠
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SERVICE_NAME
export IMAGE_REPOSITORY
export CONTAINER_PORT
export BLUE_PORT_START
export GREEN_PORT_START
export JAVA_TOOL_OPTIONS
export MEM_LIMIT
export TARGET_SCALE
export HEALTH_PATH
export DEPLOYMENT_BASE_PATH
export DRAIN_SECONDS

exec "$SCRIPT_DIR/bluegreen-core.sh" "${1:-latest}"