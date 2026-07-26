#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-notification-service"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-notification-service"

CONTAINER_PORT="8300"

# host port range
# blue scale 3  -> 8220, 8221, 8222
# green scale 3 -> 8320, 8321, 8322
BLUE_PORT_START="8220"
GREEN_PORT_START="8320"

JAVA_TOOL_OPTIONS="-Xms128m -Xmx256m"
MEM_LIMIT="512m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

# Use liveness for boot check.
# /actuator/health and /actuator/health/readiness return 503 before deployment ready is approved.
HEALTH_PATH="/api/v1/actuator/health/liveness"
DEPLOYMENT_BASE_PATH="/api/v1/internal/deployment"

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

exec "$SCRIPT_DIR/bluegreen-core.sh" "${1:-latest}"
