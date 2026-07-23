#!/bin/sh
# Redis 클러스터 최초 1회 부트스트랩 (idempotent).
# compose의 redis-cluster-init 서비스가 실행한다. 이미 구성돼 있으면 아무것도 하지 않는다.
# 노드 목록은 REDIS_CLUSTER_NODES로 오버라이드 가능(기본 = infra의 6노드). 격리 테스트용.
set -eu

NODES="${REDIS_CLUSTER_NODES:-redis-0:7100 redis-1:7101 redis-2:7102 redis-3:7103 redis-4:7104 redis-5:7105}"
REPLICAS="${REDIS_CLUSTER_REPLICAS:-1}"

first="$(echo "$NODES" | awk '{print $1}')"
first_host="$(echo "$first" | cut -d: -f1)"
first_port="$(echo "$first" | cut -d: -f2)"

echo "[redis-cluster-init] 노드 응답 대기..."
for nodeport in $NODES; do
  host="$(echo "$nodeport" | cut -d: -f1)"
  port="$(echo "$nodeport" | cut -d: -f2)"
  n=0
  until redis-cli -h "$host" -p "$port" ping 2>/dev/null | grep -q PONG; do
    n=$((n + 1))
    [ "$n" -gt 60 ] && { echo "ERROR: $host:$port 응답 없음"; exit 1; }
    sleep 2
  done
  echo "  $host:$port OK"
done

# 이미 노드들이 서로 알고 있으면(=클러스터 구성됨) skip
known="$(redis-cli -h "$first_host" -p "$first_port" cluster info 2>/dev/null \
  | tr -d '\r' | awk -F: '/^cluster_known_nodes:/{print $2}')"
if [ "${known:-1}" -gt 1 ]; then
  echo "[redis-cluster-init] 이미 클러스터 구성됨(known_nodes=$known). skip."
  exit 0
fi

echo "[redis-cluster-init] 클러스터 생성 (replicas=$REPLICAS)..."
# shellcheck disable=SC2086
redis-cli --cluster create $NODES --cluster-replicas "$REPLICAS" --cluster-yes

# 생성 직후엔 slot 합의 수렴에 잠깐 걸리므로 cluster_state:ok 될 때까지 대기(최대 ~40s)
echo "[redis-cluster-init] cluster_state:ok 수렴 대기..."
n=0
until [ "$(redis-cli -h "$first_host" -p "$first_port" cluster info 2>/dev/null \
    | tr -d '\r' | awk -F: '/^cluster_state:/{print $2}')" = "ok" ]; do
  n=$((n + 1))
  [ "$n" -gt 20 ] && {
    echo "ERROR: cluster_state가 ok로 수렴하지 않음"
    redis-cli -h "$first_host" -p "$first_port" cluster info | tr -d '\r' | grep '^cluster_'
    exit 1
  }
  sleep 2
done

echo "[redis-cluster-init] 완료:"
redis-cli -h "$first_host" -p "$first_port" cluster info | tr -d '\r' | grep -E 'cluster_state|cluster_known_nodes|cluster_slots_assigned'
