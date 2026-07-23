# CLAUDE.md

## 저장소 개요
crypto-project 인프라 저장소. `crypto-project-backend`가 GitHub Actions self-hosted runner에서
실행하는 배포 스크립트와, 로컬/운영 인프라(DB·메시징·Vault) 및 모니터링 스택의 Docker Compose 정의를 담는다.
이 저장소 자체에는 애플리케이션 코드가 없다 — **여기 있는 스크립트가 실제 프로덕션 컨테이너를 기동/교체하는 유일한 경로**다.

### backend와의 연결 (중요)
`crypto-project-backend/.github/workflows/cd.yml`은 입력값 검증(필수 변수 empty 체크, `TARGET_SCALE` 형식 검증)과
스크립트 호출까지만 하고, 실제 배포 실행 로직(헬스체크·rollback 등)은 갖지 않는다. self-hosted runner가:
1. `$INFRA_REPO_DIR`(이 저장소)에서 `git pull --ff-only`
2. `cd service && . ./.env`
3. `TARGET_SERVICE` 입력값에 따라 `service/scripts/deploy/*.sh` 중 하나를 그대로 실행

이 스크립트의 인자·필수 환경변수·exit code가 곧 cd.yml과의 계약이다. 스크립트 이름을 바꾸거나
인자 순서(`IMAGE_TAG`, `TARGET_SCALE`)를 바꾸면 cd.yml도 같이 수정해야 하며, 그 변경은
**crypto-project-backend 저장소**에 있으므로 이 저장소만 봐서는 깨졌는지 알 수 없다.
전략별(Blue/Green · Validated Recreate · Safe Recreate) 실제 배포 단계는 `docs/DEPLOYMENT_FLOW.md`(개요)와
`docs/DEPLOYMENT_FLOW_BLUEGREEN.md` / `_VALIDATED_RECREATE.md` / `_SAFE_RECREATE.md`에 정리되어 있다.

## 디렉토리 구조
| 경로 | 내용 |
| --- | --- |
| `infra/` | MySQL(master/replica), Redis(6-node), MongoDB(replica set), Kafka(2-broker+KRaft), Vault, adminer/redis-insight/mongo-express. 로컬 개발·운영 공용 인프라 compose. 상세는 `docs/INFRA.md`. **네트워크·볼륨이 external이라 최초 1회 수동 생성 필요, 데이터 볼륨 삭제는 영구 손실** — `.claude/rules/infra-safety.md` 참고. |
| `monitoring/` | Prometheus/Grafana + DB별 exporter(mysqld/redis/mongodb/kafka). 메트릭 전용(로그·트레이스 스택 제거됨). 상세는 `docs/MONITORING.md`. |
| `service/docker-compose.yml` | 백엔드 서비스 compose 정의. **CD 배포가 compose를 실제로 쓰는 건 outbox-poller(safe-recreate)뿐** — 나머지는 스크립트가 `docker run`으로 직접 띄운다(compose 정의는 로컬/수동 용도, 스크립트 값과 중복되어 드리프트 주의). market-service는 compose 미등록. 구조 상세는 `docs/SERVICE.md`. |
| `service/scripts/deploy/` | 배포 스크립트. 전략 3종(Blue/Green, Validated Recreate, Safe Recreate)이 섞여 있다. 서비스 구조는 `docs/SERVICE.md`, 배포 흐름은 `docs/DEPLOYMENT_FLOW.md`(개요)부터. |
| `service/.deploy/` | **배포 런타임 상태**(git 미추적, `.gitignore`). `*.active-slot`(현재 blue/green), `*.current-image`(rollback용 이미지 다이제스트). 스크립트가 쓰고 읽는 파일이며 사람이 직접 편집하는 파일이 아니다. |
| `service/certs/`, `infra/mongo/mongo-keyfile` 등 | 인증서/키파일. `.gitignore`로 제외, 로컬에만 존재. |
| `*/.env` | 각 compose 스택의 환경변수(Vault AppRole, Deploy Token, DB 계정 등). git 미추적. |

각 스택 디렉토리(`service/`, `infra/`, `monitoring/`)에는 로컬 `CLAUDE.md`가 있다. 해당 디렉토리의
파일을 다룰 때 자동 로드되어 스코프별 주의·문서/규칙 포인터를 제공한다(이 루트 파일은 저장소 전체 개요).

## 규칙 참조 (작업 유형별 — 필요 시 해당 파일을 읽는다)
자동으로 로드되지 않는다. 아래 작업을 할 때 해당 규칙 파일을 먼저 읽는다.

| 작업 | 읽을 규칙 |
| --- | --- |
| Git 조작(commit/push/merge/rebase), 민감 정보(`.env`/`.deploy/`/인증서 등) 취급 | `.claude/rules/git-safety.md` |
| 배포 스크립트(`service/scripts/deploy/`), `service/docker-compose.yml`, `service/.deploy/` 수정 | `.claude/rules/deploy-safety.md` |
| 인프라·모니터링 스택(`infra/`, `monitoring/`) 조작·수정 (상태 저장, 볼륨 삭제 위험) | `.claude/rules/infra-safety.md` |

## 의사소통
- 한국어로 설명한다. `원인 → 수정 → 영향 범위(backend cd.yml 포함) → 검증 방법(또는 검증 불가 사유)` 순서를 따른다.
- 코드만으로 확인할 수 없는 부분(예: 실제 러너 환경, Vault 정책, 운영 DNS/방화벽)은 추측하지 않고 `확인 필요`로 표시한다.
- `확인 필요` 항목은 개별 문서에 흩어놓지 않고 저장소 최상위 `TODO.md`에 모아서 관리한다(출처 문서를 함께 남긴다).
