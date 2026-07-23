# 배포 흐름 — 개요

이 문서는 `service/scripts/deploy/`의 실제 스크립트 코드를 읽고 정리한 것이다. `cd.yml`의
`TARGET_SERVICE` 입력값 기준으로 서비스마다 다음 세 전략 중 하나를 쓴다. 전략별 상세 흐름은
별도 문서로 분리되어 있다.

| 전략 | 대상 서비스 | 스크립트 | 상세 문서 |
| --- | --- | --- | --- |
| Blue/Green | user-service, market-service, websocket-gateway, chat-service | `bluegreen-core.sh` + `deploy-<service>-bluegreen.sh` | [DEPLOYMENT_FLOW_BLUEGREEN.md](./DEPLOYMENT_FLOW_BLUEGREEN.md) |
| Validated Recreate | spring-cloud-config, eureka-server, api-gateway, oauth2-authorization-server, oauth2-client | `deploy-<service>-validated-recreate.sh` (서비스별 독립 스크립트, 공통 core 없음) | [DEPLOYMENT_FLOW_VALIDATED_RECREATE.md](./DEPLOYMENT_FLOW_VALIDATED_RECREATE.md) |
| Safe Recreate | outbox-poller | `deploy-outbox-poller-safe.sh` | [DEPLOYMENT_FLOW_SAFE_RECREATE.md](./DEPLOYMENT_FLOW_SAFE_RECREATE.md) |

## 공통 트리거 경로

세 전략 모두 트리거 경로는 같다: `crypto-project-backend`의 `cd.yml`(`workflow_dispatch`) →
self-hosted runner → `cd "$INFRA_REPO_DIR/service"` → `. ./.env` → `TARGET_SERVICE` case문 →
해당 스크립트를 `"$IMAGE_TAG"`(blue/green은 `"$TARGET_SCALE"`까지) 인자로 실행. 스크립트의
인자 순서와 exit code가 곧 cd.yml과의 계약이다 — 자세한 안전 규칙은
`.claude/rules/deploy-safety.md` 참고. 확인 필요 항목은 저장소 최상위 [`TODO.md`](../TODO.md)에서 관리한다.
