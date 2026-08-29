#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="crypto-websocket-gateway"
IMAGE_REPOSITORY="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}/crypto-websocket-gateway"

CONTAINER_PORT="8100"

# blue scale 3  -> 8200, 8201, 8202
# green scale 3 -> 8300, 8301, 8302
BLUE_PORT_START="8200"
GREEN_PORT_START="8300"

REMOTE_DEBUG_ENABLED="${REMOTE_DEBUG_ENABLED:-false}"
REMOTE_DEBUG_PORT_OFFSET="${REMOTE_DEBUG_PORT_OFFSET:-20000}"
REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-}"
REMOTE_DEBUG_SLOT_OFFSET="${REMOTE_DEBUG_SLOT_OFFSET:-5}"
REMOTE_DEBUG_SUSPEND="${REMOTE_DEBUG_SUSPEND:-n}"

# Netty direct buffer 상한을 명시한다. 없으면 무한 증가해 컨테이너째 OOM-kill 되고 스택이 남지 않는다.
# 힙을 512m -> 448m 로 줄여 direct 128m 자리를 만든다(총량 불변). 게이트웨이는 프록시라
# 요청 바디를 힙에 쌓지 않고, 정작 필요한 건 direct buffer 다.
# GC 를 명시한다. MEM_LIMIT 이 1792m 미만이면 JVM 이 server class 가 아니라고 판정해
# SerialGC 로 떨어진다. CPU 가 12개여도 GC 스레드는 하나뿐이라 full GC 가 초 단위로 멈춘다
# (부하 측정에서 최대 20초 관측). 경고가 남지 않아 지표를 보기 전까지 드러나지 않는다.
# 힙이 500m 미만이라 region 오버헤드가 있는 G1 보다 ParallelGC 가 맞다.
JAVA_TOOL_OPTIONS="-Xms256m -Xmx448m -XX:MaxDirectMemorySize=128m -XX:+UseParallelGC"
MEM_LIMIT="768m"

TARGET_SCALE="${TARGET_SCALE:?TARGET_SCALE is required}"

HEALTH_PATH="/actuator/health/liveness"
DEPLOYMENT_BASE_PATH="/internal/deployment"

# WebSocket은 기존 연결이 있을 수 있으므로 user-service보다 길게 둠
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"

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
export DRAIN_SECONDS

exec "$SCRIPT_DIR/bluegreen-core.sh" "${1:-latest}"
