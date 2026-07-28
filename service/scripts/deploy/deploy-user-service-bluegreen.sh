#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-user-service"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-user-service"

CONTAINER_PORT="8090"

# host port range
# blue scale 3  -> 8190, 8191, 8192
# green scale 3 -> 8290, 8291, 8292
BLUE_PORT_START="8190"
GREEN_PORT_START="8290"

REMOTE_DEBUG_ENABLED="${REMOTE_DEBUG_ENABLED:-false}"
REMOTE_DEBUG_PORT_OFFSET="${REMOTE_DEBUG_PORT_OFFSET:-20000}"
REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-}"
REMOTE_DEBUG_SLOT_OFFSET="${REMOTE_DEBUG_SLOT_OFFSET:-5}"
REMOTE_DEBUG_SUSPEND="${REMOTE_DEBUG_SUSPEND:-n}"

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
