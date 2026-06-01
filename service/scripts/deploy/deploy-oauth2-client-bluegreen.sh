#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-oauth2-client"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-oauth2-client"

CONTAINER_PORT="8900"

# blue scale 3  -> 8990, 8991, 8992
# green scale 3 -> 9090, 9091, 9092
BLUE_PORT_START="8910"
GREEN_PORT_START="8920"

JAVA_TOOL_OPTIONS="-Xms128m -Xmx256m"
MEM_LIMIT="768m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

HEALTH_PATH="/actuator/health/liveness"
DEPLOYMENT_BASE_PATH="/internal/deployment"

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