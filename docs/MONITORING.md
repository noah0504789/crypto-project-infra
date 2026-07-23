# 모니터링 스택 (`monitoring/`)

이 문서는 `monitoring/docker-compose.yml`과 설정 파일들을 읽고 정리한다. **메트릭 전용** 관측 스택이며,
`infra/`·`service/`와 같은 `crypto-project-network`(external)를 공유하는 **별도 compose**다.

> 로그(Loki/Promtail)·트레이스(Tempo/OTel Collector) 스택은 제거되었다(작업 중단분 정리). 현재는
> Prometheus(메트릭) + Grafana(시각화) + exporter들만 남아 있다. 다시 도입하려면 별도 작업이 필요하다.

## 사전 준비 (첫 기동 전)
- 네트워크 `crypto-project-network`, 볼륨 `grafana-data`는 `external: true` → 최초 1회 수동 생성 필요.
- exporter들이 `infra/`의 서비스명(`mysql-master`, `redis-0`, `mongo-primary`, `kafka-0` 등)으로 접속하므로,
  **`infra/` 스택이 같은 네트워크에 떠 있어야** 의미가 있다.

## 포트 요약

| 컴포넌트 | 호스트 포트 | 비고 |
| --- | --- | --- |
| prometheus | 19090 → 9090 | TSDB retention 24h, 익명 볼륨(명시 볼륨 없음) |
| grafana | 3000 | admin 계정은 `monitoring/.env`에서 주입 |

> exporter(node/mysqld/redis/mongodb/kafka)는 호스트 포트를 열지 않고 내부 네트워크에서만 스크레이프된다.

## 구성요소

### Prometheus (메트릭 수집)
- `prometheus.yml`의 scrape 대상. `scrape_interval` 10s, retention 24h.
- **인프라 job(정적 target)**: `node`(node-exporter:9100), `mysql`(primary/replica exporter:9104),
  `redis-cluster`(redis-exporter-0~5:9121), `mongo`(primary exporter만), `kafka`(kafka-exporter:9308).
  컨테이너 이름이 고정이라 정적 target으로 충분하다.
- **서비스 job(자동 발견)**: `crypto-chat-service`·`crypto-websocket-gateway`는 blue/green이라 컨테이너
  이름이 배포마다 바뀐다(`...-blue-1` ↔ `...-green-1`, scale에 따라 개수도 변동). 그래서 정적 target
  대신 **Docker 서비스 디스커버리(`docker_sd_configs`)** 로 `app=<서비스명>` 라벨이 붙은 컨테이너를
  자동 발견해 스크레이프한다(라벨은 `bluegreen-core.sh`가 부여). 슬롯 전환·scale 변경에 자동 대응한다.
  - **소켓 접근(docker-socket-proxy 경유)**: docker_sd는 Docker API로 컨테이너 목록·네트워크를 질의해야
    한다. Prometheus에 소켓을 직접 물리는 대신 **`docker-socket-proxy`**(읽기 전용: `CONTAINERS`/`NETWORKS`만
    허용, `POST=0`)를 앞에 두고 Prometheus는 `tcp://docker-socket-proxy:2375`로 조회한다. 덕분에
    Prometheus에 `docker.sock` 직접 마운트·`user: root`가 필요 없다(검증 완료). 소켓을 직접 다루는 건
    이 작은 전용 프록시 하나뿐이다.
- **비활성(주석)**: `crypto-outbox-poller` scrape job(주석 처리).

### Grafana
- `3000`, admin 계정(`GF_SECURITY_ADMIN_USER`/`_PASSWORD`)은 `monitoring/.env`
  (`GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD`, git 미추적)에서 주입한다. `./grafana` 디렉토리를
  datasource provisioning 경로로 마운트하며, `datasources.yaml`에 Prometheus(기본) 데이터소스만 정의한다.

### Exporter들
- `node-exporter`: 호스트 지표(`/`를 ro 마운트), CPU/mem/fs/loadavg/netdev/stat만 수집.
- `mysql-primary-exporter`(→`mysql-master:3306`)·`mysql-replica-exporter`(→`mysql-replica:3306`):
  `mysqld_exporter`. 접속은 `--mysqld.address`/`--mysqld.username`(= `${MYSQL_EXPORTER_USER}`) 플래그 +
  `MYSQLD_EXPORTER_PASSWORD`(= `${MYSQL_EXPORTER_PASSWORD}`) 환경변수로 주입한다(`monitoring/.env`,
  평문 파일 없음). 비밀번호는 infra의 `MYSQL_EXPORTER_PASSWORD`(mysql-exporter 계정 비번)와 일치해야 한다.
- `redis-exporter-0~5`: redis 노드별 1개, `--is-cluster`.
- `mongodb-exporter-primary`/`-secondary-0`/`-1`: `MONGODB_URI`에 `${MONGO_EXPORTER_USER}`/
  `${MONGO_EXPORTER_PASSWORD}` 주입(→ `monitoring/.env`, env 기반이라 평문 하드코딩 아님).
  primary·secondary 3개 모두 Prometheus가 수집한다.
- `kafka-exporter`: `kafka-0:9092`·`kafka-1:9092` 대상.

## 볼륨·네트워크
- `grafana-data`(대시보드/설정)는 `external: true` → 삭제 시 영구 손실. 볼륨 삭제 명령은 승인 없이
  금지(→ `.claude/rules/infra-safety.md`).
- 프로메테우스 TSDB는 익명 볼륨(명시 볼륨 없음) → 컨테이너 재생성 시 메트릭 유실 가능(확인 필요 수준).

## 관련 규칙·문서
- 스택 조작 안전 규칙(infra와 공통): `.claude/rules/infra-safety.md`
- infra 스택(exporter가 접속하는 대상): `docs/INFRA.md`
- 확인 필요·미완성 항목: 루트 `TODO.md`
