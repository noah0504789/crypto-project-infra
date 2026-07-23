# 인프라 스택 (`infra/`)

이 문서는 `infra/docker-compose.yml`과 그 설정 파일들을 읽고 정리한 것이다. `infra/`는
백엔드 서비스가 의존하는 **상태 저장 인프라**(RDB·문서DB·캐시·메시징·시크릿)와 개발용 관리 UI를
로컬/운영에서 띄우는 Docker Compose 스택이다. 배포 스크립트가 있는 `service/`와는 별개의 스택이며,
서로 `crypto-project-network`(external)로만 연결된다.

## 사전 준비 (첫 기동 전 필수)

`infra/docker-compose.yml`의 네트워크와 볼륨은 모두 `external: true`다. 즉 compose가 자동으로
만들어주지 않으므로, **최초 1회 수동 생성이 필요**하다. 없으면 `docker compose up`이 곧바로 실패한다.

- 네트워크: `crypto-project-network` (service/·monitoring/ 스택도 같은 네트워크를 공유)
- 볼륨: `mysql-master-data`, `mysql-replica-data`, `redis-0-data`~`redis-5-data`,
  `mongo-primary-data`, `mongo-secondary0-data`, `mongo-secondary1-data`,
  `kafka-0-data`, `kafka-1-data`, `vault-data`
- 시크릿 파일: `infra/mongo/mongo-keyfile`(replica set 내부 인증용 keyfile), `infra/.env`
  (DB·mongo-express 자격증명). 둘 다 `.gitignore`로 제외되어 로컬에만 존재한다.

## 자격증명 (.env)

DB 비밀번호는 committed 파일에 평문으로 두지 않고 **`infra/.env`(git 미추적)에서 주입**한다.
compose가 `${VAR}`로 컨테이너 환경변수에 넣고, init 스크립트(`mysql-init.sh`, `mongo-*.js`)가
그 환경변수를 읽는다. `infra/.env`는 `.gitignore` 대상이라 committed 되지 않으므로, 새 환경에서는
아래 키를 직접 채워 `infra/.env`를 만들어야 한다(없으면 compose가 빈 값으로 치환 → fresh init 시
빈 비밀번호로 생성되는 footgun).

| 키 | 용도 |
| --- | --- |
| `MYSQL_ROOT_PASSWORD` | MySQL root (master/replica 공통) |
| `MYSQL_USER_DB_PASSWORD` | `user` DB 서비스 계정 |
| `MYSQL_EVENT_DB_PASSWORD` | `event` DB 서비스 계정 |
| `MYSQL_MARKET_DB_PASSWORD` | `market` DB 서비스 계정 |
| `MYSQL_REPL_PASSWORD` | 복제 계정 `repl` |
| `MYSQL_EXPORTER_PASSWORD` | 모니터링 exporter (monitoring cnf와 일치 필요) |
| `MONGO_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD` | Mongo root. mongo-express 접속에도 재사용 |
| `MONGO_CHAT_PASSWORD` | `chatuser`(chat DB) |
| `MONGO_NOTIFICATION_PASSWORD` | `notificationuser`(notification DB) |
| `MONGO_EXPORTER_PASSWORD` | 모니터링 exporter (monitoring `.env`와 일치 필요) |
| `MONGO_EXPRESS_SERVER` / `_PORT` / `_ENABLE_ADMIN` / `_AUTH_DATABASE` | mongo-express(관리 UI) 접속 설정 |

- **fresh 볼륨에서만 반영된다.** init 스크립트는 데이터 디렉토리가 비어 있을 때만 실행되므로,
  이미 초기화된 볼륨의 비밀번호는 `.env` 값을 바꿔도 자동으로 바뀌지 않는다(수동 회전 필요).
- **모니터링과 값이 맞물린다.** `MYSQL_EXPORTER_PASSWORD`는 `monitoring/my-primary.cnf`·
  `my-replica.cnf`의 exporter 비밀번호와, `MONGO_EXPORTER_PASSWORD`는 `monitoring/.env`와 일치해야
  한다. `MONGO_ROOT_USERNAME`/`PASSWORD`는 mongo-express(관리 UI) 접속에도 재사용된다.
- 과거 커밋 히스토리에는 평문 비밀번호가 남아 있다(→ `TODO.md`).

## 포트 요약

| 컴포넌트 | 호스트 포트 | 비고 |
| --- | --- | --- |
| mysql-master | 3306 | 쓰기(primary) |
| mysql-replica | 3307 | 읽기 전용 replica |
| redis-0 ~ redis-5 | 7100–7105 | 클러스터 버스 포트 17100–17105 |
| mongo-primary | 27017 | replica set `rs0` primary |
| mongo-secondary-0 / -1 | 27018 / 27019 | secondary |
| kafka-0 / kafka-1 | 10000 / 10001 | 외부 리스너(EXTERNAL). 내부는 `kafka-N:9092` |
| kafka-ui | 9090 | 관리 UI |
| vault | 18200 | TLS 미적용(`tls_disable=1`) |
| adminer | 20080 | RDB 관리 UI |
| mongo-express | 20081 | MongoDB 관리 UI |
| redis-insight | 20082 | Redis 관리 UI |

## 컴포넌트별

### MySQL (master/replica, GTID 복제)
- `mysql-master.cnf`: `server-id=1`, `log_bin`, `binlog_format=ROW`, `gtid_mode=ON`,
  `enforce_gtid_consistency=ON`, `log_replica_updates=ON`.
- `mysql-replica.cnf`: `server-id=2`, `read_only=ON` + `super_read_only=ON`(쓰기 차단), GTID ON.
- `mysql-init.sh`는 **master의 `docker-entrypoint-initdb.d`에서만** 실행된다(env 주입을 위해
  `.sql`이 아닌 `.sh`. `.sql`은 환경변수 치환이 안 됨). DB 3개(`user`, `event`, `market`)와 계정을
  생성한다: 서비스 계정(`user`/`event`/`market`), 복제 계정(`repl`, `REPLICATION SLAVE`), 모니터링
  계정(`mysql-exporter`). 비밀번호는 `.env`에서 주입한다(위 "자격증명" 참고).
- **주의**: 이 저장소 파일만으로는 replica가 master를 바라보게 하는 실제 연결
  (`CHANGE REPLICATION SOURCE TO ... / START REPLICA`)이 자동화되어 있지 않다. replica cnf는
  `read_only`만 설정할 뿐이다 → `TODO.md` 확인 필요 항목.

### Redis (6-node 클러스터)
- `redis-0`~`redis-5`, 각 `7100`~`7105`. 각 노드 `NNNN.conf`는 `cluster-enabled yes`,
  `appendonly yes`(AOF), `cluster-announce-hostname/-port/-bus-port`를 자기 노드에 맞게 설정.
- **주의**: compose는 6개 노드를 띄우기만 한다. 실제 클러스터 구성(`redis-cli --cluster create ...`,
  슬롯 할당)은 이 파일들에 없다 → 최초 1회 수동 실행 필요, `TODO.md` 확인 필요 항목.

### MongoDB (replica set `rs0`)
- primary + secondary 2대. `mongod.conf`: `replSetName=rs0`, `authorization=enabled`,
  `keyFile=/etc/mongo-keyfile`(내부 멤버 인증).
- `mongo-user.js`(primary init): `root`(admin), `chatuser`→`chat` DB, `notificationuser`→
  `notification` DB, `mongo-exporter`(모니터링) 계정을 생성한다. 비밀번호는 `process.env`(= `.env`)에서
  읽는다(mongo 6.0 mongosh 기준).
- `mongo-replica.js`(primary init): 10초 대기 후 `db.auth`(root, `.env` 값) → `rs.initiate`로 3-멤버
  replica set을 구성한다(primary priority 2, secondary 각 1). init 스크립트는 **primary에서만** 실행된다.

### Kafka (KRaft, 2-broker)
- ZooKeeper 없이 KRaft 모드. `kafka-0`(node 0), `kafka-1`(node 1)이 broker + controller 겸함.
- controller quorum: `0@kafka-0:9093,1@kafka-1:9093`. `CLUSTER_ID`는 compose에 하드코딩.
- 리스너: 내부 `PLAINTEXT://kafka-N:9092`, 컨트롤러 `9093`, 외부 `EXTERNAL://localhost:1000N`.
- `KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`(토픽 자동 생성). 복제 계수·ISR 관련 설정은 단일 클러스터
  기준(replication factor 1)으로 잡혀 있다.

### Vault
- `vault.hcl`: `file` 스토리지(`/vault/data`), 리스너 `0.0.0.0:18200` **TLS 미적용**(`tls_disable=1`),
  `ui=true`, `disable_mlock=true`. entrypoint에서 `/vault/data` 권한을 잡고 `vault server`를 실행.
- **주의**: init/unseal은 자동화되어 있지 않다. 최초 기동 후 `vault operator init`/`unseal`을
  수동으로 해야 하며, root token·unseal key는 응답/커밋에 노출하지 않는다(→ `.claude/rules/git-safety.md`).
- 백엔드는 이 Vault의 AppRole(KV v2 + Transit)로 시크릿을 로드한다(`VAULT_ROLE_ID`/`VAULT_SECRET_ID`).

### 관리 UI (개발용)
- `adminer`(20080, RDB), `mongo-express`(20081, MongoDB), `redis-insight`(20082, Redis),
  `kafka-ui`(9090, Kafka). mongo-express 접속 정보는 `infra/.env`(`MONGO_EXPRESS_*`)에서 주입된다.

## 볼륨·네트워크

- 모든 데이터 볼륨과 `crypto-project-network`는 `external: true`다. **`docker compose down -v`나
  볼륨 삭제는 곧 DB/메시지 영구 삭제**이므로 승인 없이 실행하지 않는다(→ `.claude/rules/infra-safety.md`).
- 모니터링 스택(`monitoring/`)은 별도 compose이며 같은 네트워크를 공유한다. (이 문서 범위 밖)

## 관련 규칙·문서
- 인프라 조작 안전 규칙: `.claude/rules/infra-safety.md`
- 자동화되지 않은 부트스트랩·확인 필요 항목: `TODO.md`
