#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-oauth2-authorization-server"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-oauth2-authorization-server"

CONTAINER_PORT="9000"

# blue scale 3  -> 9100, 9101, 9102
# green scale 3 -> 9200, 9201, 9202
BLUE_PORT_START="9100"
GREEN_PORT_START="9200"

JAVA_TOOL_OPTIONS="-Xms256m -Xmx384m"
MEM_LIMIT="768m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

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