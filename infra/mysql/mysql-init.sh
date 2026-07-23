#!/bin/bash
# MySQL 초기화 스크립트 — fresh 볼륨에서 최초 1회만 실행된다.
# 비밀번호는 컨테이너 환경변수(= infra/.env)에서 주입한다. 평문 하드코딩 금지.
# MySQL 엔트리포인트는 .sql과 달리 .sh 파일은 실행/소스하므로 환경변수를 쓸 수 있다.

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOSQL
CREATE DATABASE IF NOT EXISTS \`user\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS \`event\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS \`market\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'user'@'%' IDENTIFIED BY '${MYSQL_USER_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`user\`.* TO 'user'@'%';

CREATE USER IF NOT EXISTS 'event'@'%' IDENTIFIED BY '${MYSQL_EVENT_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`event\`.* TO 'event'@'%';

CREATE USER IF NOT EXISTS 'market'@'%' IDENTIFIED BY '${MYSQL_MARKET_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`market\`.* TO 'market'@'%';

CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';

CREATE USER IF NOT EXISTS 'mysql-exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'mysql-exporter'@'%';

FLUSH PRIVILEGES;
EOSQL
