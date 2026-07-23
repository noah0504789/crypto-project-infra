#!/bin/sh
# MySQL replica 복제 연결 최초 1회 부트스트랩 (idempotent, GTID).
# compose의 mysql-replica-init 서비스가 실행한다. 이미 복제 중이면 아무것도 하지 않는다.
# 접속/복제 자격증명은 컨테이너 환경변수(= infra/.env)에서 주입한다.
set -eu

MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-master}"
MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
REPLICA_HOST="${MYSQL_REPLICA_HOST:-mysql-replica}"
REPLICA_PORT="${MYSQL_REPLICA_PORT:-3306}"
REPL_USER="${MYSQL_REPL_USER:-repl}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
: "${MYSQL_REPL_PASSWORD:?MYSQL_REPL_PASSWORD is required}"

wait_mysql() {
  h="$1"; p="$2"; n=0
  until mysqladmin ping -h "$h" -P "$p" -uroot -p"$MYSQL_ROOT_PASSWORD" --silent 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -gt 90 ] && { echo "ERROR: $h:$p 응답 없음"; exit 1; }
    sleep 2
  done
  echo "  $h:$p OK"
}

replica_status_field() {
  mysql -h "$REPLICA_HOST" -P "$REPLICA_PORT" -uroot -p"$MYSQL_ROOT_PASSWORD" \
    -e "SHOW REPLICA STATUS\G" 2>/dev/null \
    | awk -F': ' -v k="$1:" '$1 ~ k {gsub(/^[ \t]+/,"",$2); print $2}'
}

echo "[mysql-replica-init] master/replica 대기..."
wait_mysql "$MASTER_HOST" "$MASTER_PORT"
wait_mysql "$REPLICA_HOST" "$REPLICA_PORT"

# 이미 복제 중이면 skip
if [ "$(replica_status_field Replica_IO_Running)" = "Yes" ]; then
  echo "[mysql-replica-init] 이미 복제 중(Replica_IO_Running=Yes). skip."
  exit 0
fi

echo "[mysql-replica-init] 복제 설정 (GTID auto-position)..."
mysql -h "$REPLICA_HOST" -P "$REPLICA_PORT" -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MASTER_PORT},
  SOURCE_USER='${REPL_USER}',
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

echo "[mysql-replica-init] 복제 상태 확인..."
n=0
while :; do
  io="$(replica_status_field Replica_IO_Running)"
  sqlr="$(replica_status_field Replica_SQL_Running)"
  [ "$io" = "Yes" ] && [ "$sqlr" = "Yes" ] && break
  n=$((n + 1))
  if [ "$n" -gt 20 ]; then
    echo "ERROR: 복제가 시작되지 않음 (IO=$io SQL=$sqlr)"
    echo "  IO error : $(replica_status_field Last_IO_Error)"
    echo "  SQL error: $(replica_status_field Last_SQL_Error)"
    exit 1
  fi
  sleep 2
done
echo "[mysql-replica-init] 복제 정상 (Replica_IO_Running=Yes, Replica_SQL_Running=Yes)."
