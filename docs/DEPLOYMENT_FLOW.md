# 배포 흐름 — 개요

이 문서는 `service/scripts/deploy/`의 실제 스크립트 코드를 읽고 정리한 것이다. `cd.yml`의
`TARGET_SERVICE` 입력값 기준으로 서비스마다 다음 세 전략 중 하나를 쓴다. 전략별 상세 흐름은
별도 문서로 분리되어 있다.

| 전략 | 대상 서비스 | 스크립트 | 상세 문서 |
| --- | --- | --- | --- |
| Blue/Green | user-service, market-service, websocket-gateway, chat-service, notification-service | `bluegreen-core.sh` + `deploy-<service>-bluegreen.sh` | [DEPLOYMENT_FLOW_BLUEGREEN.md](./DEPLOYMENT_FLOW_BLUEGREEN.md) |
| Validated Recreate | spring-cloud-config, eureka-server, api-gateway, oauth2-authorization-server, oauth2-client | `deploy-<service>-validated-recreate.sh` (서비스별 독립 스크립트, 공통 core 없음) | [DEPLOYMENT_FLOW_VALIDATED_RECREATE.md](./DEPLOYMENT_FLOW_VALIDATED_RECREATE.md) |
| Safe Recreate | outbox-poller, market-detection | `deploy-<service>-safe.sh` | [DEPLOYMENT_FLOW_SAFE_RECREATE.md](./DEPLOYMENT_FLOW_SAFE_RECREATE.md) |

## 공통 트리거 경로

세 전략 모두 트리거 경로는 같다: `crypto-project-backend`의 `cd.yml`(`workflow_dispatch`) →
self-hosted runner → `cd "$INFRA_REPO_DIR/service"` → `. ./.env` → `TARGET_SERVICE` case문 →
해당 스크립트를 `"$IMAGE_TAG"`(blue/green은 `"$TARGET_SCALE"`까지) 인자로 실행. 스크립트의
인자 순서와 exit code가 곧 cd.yml과의 계약이다 — 자세한 안전 규칙은
`.claude/rules/deploy-safety.md` 참고. 확인 필요 항목은 저장소 최상위 [`TODO.md`](../TODO.md)에서 관리한다.

## 배포 준비 상태 제어 (`/internal/deployment`) — backend 확인 완료

blue/green·validated-recreate 스크립트가 호출하는 `/internal/deployment/{ready,not-ready}`는 backend
공통 모듈(`common-actuator-webmvc`/`-webflux`, core는 `common-actuator-core`)이 제공한다. backend 코드
확인 결과:

- **상태**: `DeploymentReadiness`가 in-memory `AtomicBoolean ready`(초기 `false`)를 들고 있고,
  `POST /ready`→`true`, `POST /not-ready`→`false`, `GET /status`로 조회한다.
- **트래픽 전환 시점**: `DeploymentReadinessHealthIndicator`가 이 값을 actuator health에 반영한다 —
  `ready=false`면 `OUT_OF_SERVICE`, `true`면 `UP`. 그래서 새 컨테이너는 기동 직후 `ready=false`라
  **liveness는 통과해도 readiness는 실패** → `/ready`를 받아야 비로소 정상(UP)이 된다. 스크립트가
  liveness로 boot를 확인한 뒤 `/ready`로 승격하고, 이전 슬롯은 `/not-ready`로 내려 drain하는 이유가 이것.
- **인증(DEPLOY_TOKEN)**: `DeploymentControlAuthFilter`가 `/internal/deployment/*`에서 `X-Deploy-Token`을
  검사한다. 설정 토큰(`deployment.control.token` = `${DEPLOY_TOKEN}`)이 **비었거나 헤더와 불일치하면 401**.
  즉 backend는 토큰이 설정돼 있으면 **항상 요구**한다(서비스별 정책 차이 아님). 토큰은 CD(`cd.yml`)에서
  `secrets.DEPLOY_TOKEN`으로 늘 주입되므로, infra 스크립트마다 "토큰 없으면 skip vs 필수(`:?`)"가 갈리는
  것은 실제 정책 차이가 아니라 스크립트 작성 방식 차이다(정상 운영에선 토큰이 항상 존재).
