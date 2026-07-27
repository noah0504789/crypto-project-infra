# crypto-project-infra

`crypto-project` 인프라 저장소. 백엔드([`crypto-project-backend`](../crypto-project-backend))가 의존하는 **상태 저장 인프라·모니터링 스택의 Docker Compose 정의**와, GitHub Actions self-hosted runner가 실행하는 **서비스 배포 스크립트**를 담는다. 애플리케이션 코드는 없다.

> ⚠️ **여기 스크립트가 실제 프로덕션 컨테이너를 기동/교체하는 유일한 경로다.** 스테이징·dry-run이 없어 실행 결과가 곧 운영 반영이다. 변경 전 [`.claude/rules/deploy-safety.md`](.claude/rules/deploy-safety.md)·[`infra-safety.md`](.claude/rules/infra-safety.md) 참고.

---

## 1. 저장소 구조

| 경로 | 내용 | 문서 |
| --- | --- | --- |
| `infra/` | 상태 저장 인프라: MySQL(master/replica) · Redis(6-node cluster) · MongoDB(replica set) · Kafka(2-broker KRaft) · Vault · 관리 UI | [docs/INFRA.md](docs/INFRA.md) |
| `monitoring/` | Prometheus + Grafana + exporter(mysqld/redis/mongodb/kafka/node) — 메트릭 전용 | [docs/MONITORING.md](docs/MONITORING.md) |
| `service/` | 백엔드 서비스 배포 스크립트(`scripts/deploy/`) + compose 정의(`docker-compose.yml`) + 런타임 상태(`.deploy/`) | [docs/SERVICE.md](docs/SERVICE.md) |

- 세 스택은 서로 `crypto-project-network`(external)로만 연결된다. 네트워크·데이터 볼륨이 **external이라 최초 1회 수동 생성**이 필요하고, 볼륨 삭제는 영구 손실이다.
- 시크릿(`*/.env`, `service/.deploy/`, 인증서, `mongo-keyfile` 등)은 `.gitignore`로 제외 — git에 올리지 않는다.

---

## 2. 배포 구조 (backend와의 연결)

`crypto-project-backend`의 `.github/workflows/cd.yml`은 입력값 검증과 스크립트 호출까지만 하고, 실제 배포 로직(헬스체크·rollback 등)은 갖지 않는다. self-hosted runner가:

1. 이 저장소에서 `git pull --ff-only`
2. `cd service && . ./.env`
3. `TARGET_SERVICE`에 따라 `service/scripts/deploy/*.sh` 실행

**스크립트 파일명·인자 순서(`IMAGE_TAG`, `TARGET_SCALE`)·exit code가 곧 `cd.yml`과의 계약**이다. 한쪽을 바꾸면 다른 저장소도 함께 고쳐야 한다.

### 배포 전략별 대상 서비스

| 전략 | 대상 | 실행 방식 | 문서 |
| --- | --- | --- | --- |
| Blue/Green | user · market · chat · websocket-gateway · notification | `docker run`(`bluegreen-core.sh` + `deploy-<svc>-bluegreen.sh`) | [DEPLOYMENT_FLOW_BLUEGREEN.md](docs/DEPLOYMENT_FLOW_BLUEGREEN.md) |
| Validated Recreate | spring-cloud-config · eureka-server · api-gateway · oauth2-authorization-server · oauth2-client | `docker run`(서비스별 독립 스크립트) | [DEPLOYMENT_FLOW_VALIDATED_RECREATE.md](docs/DEPLOYMENT_FLOW_VALIDATED_RECREATE.md) |
| Safe Recreate | outbox-poller · market-detection | `docker compose --force-recreate` | [DEPLOYMENT_FLOW_SAFE_RECREATE.md](docs/DEPLOYMENT_FLOW_SAFE_RECREATE.md) |

개요는 [DEPLOYMENT_FLOW.md](docs/DEPLOYMENT_FLOW.md). 서비스별 포트·상태 파일은 [SERVICE.md](docs/SERVICE.md).

---

## 3. 보안 · 네트워크 노출

- 하위 서비스는 게이트웨이가 넣는 `X-User-Id`를 검증 없이 신뢰하므로, 게이트웨이를 우회한 직접 접근을 막아야 한다. blue/green·validated-recreate 앱 포트는 `-p 127.0.0.1:<host>:<container>`로 **host-local 바인딩**(외부 직접 접근 차단). 외부 진입점은 api-gateway(8000)뿐.
- 남은 항목(config 바인딩, 방화벽/Security Group 등)은 [`TODO.md`](TODO.md) "보안 · 네트워크 노출" 참고.

---

## 4. 문서

| 문서 | 내용 |
| --- | --- |
| [CLAUDE.md](CLAUDE.md) | 저장소 개요·작업 규칙 진입점 |
| [docs/INFRA.md](docs/INFRA.md) | infra 스택(DB·메시징·Vault) 구성·포트·부트스트랩 |
| [docs/MONITORING.md](docs/MONITORING.md) | Prometheus/Grafana·exporter |
| [docs/SERVICE.md](docs/SERVICE.md) | 배포 서비스 목록·포트·전략·상태 파일 |
| [docs/DEPLOYMENT_FLOW.md](docs/DEPLOYMENT_FLOW.md) | 배포 전략 개요(+ 전략별 상세 3종) |
| [TODO.md](TODO.md) | 확인 필요·예정 작업 단일 관리처 |
| [.claude/rules/](.claude/rules/) | git-safety · deploy-safety · infra-safety 규칙 |

> 최초 기동 순서(external 네트워크/볼륨 생성 → infra 스택 → 서비스)와 수동 단계(Vault init/unseal 등)는 [docs/INFRA.md](docs/INFRA.md) 참고.
