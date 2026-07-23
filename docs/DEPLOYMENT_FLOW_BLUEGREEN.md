# 배포 흐름 — Blue/Green (`bluegreen-core.sh`)

전체 개요와 다른 전략은 [DEPLOYMENT_FLOW.md](./DEPLOYMENT_FLOW.md) 참고.

대상 서비스: `crypto-user-service`, `crypto-market-service`, `crypto-websocket-gateway`,
`crypto-chat-service`. 각 서비스는 `deploy-<service>-bluegreen.sh` wrapper에서 포트/헬스체크
경로 등 파라미터만 export하고 `bluegreen-core.sh`를 그대로 실행(`exec`)한다.

## 파라미터 (wrapper가 고정 export하는 값)

| 변수 | 의미 | 예 (user-service) |
| --- | --- | --- |
| `SERVICE_NAME` | 컨테이너 이름 접두사, `.deploy/*.active-slot` 파일명 | `crypto-user-service` |
| `IMAGE_REPOSITORY` | `${DOCKERHUB_USERNAME}/<image>` | — |
| `CONTAINER_PORT` | 컨테이너 내부 포트 | `8090` |
| `BLUE_PORT_START` / `GREEN_PORT_START` | 슬롯별 호스트 포트 시작값. scale만큼 순차 증가 | `8190` / `8290` |
| `HEALTH_PATH` | liveness 체크 경로 (서비스마다 다름, gateway류는 서블릿 경로 없음) | `/api/v1/actuator/health/liveness` |
| `DEPLOYMENT_BASE_PATH` | `ready`/`not-ready` 액션을 보낼 내부 API prefix | `/api/v1/internal/deployment` |
| `DRAIN_SECONDS` | 이전 슬롯 정지 전 대기 시간(기본 15초, websocket-gateway만 30초) | — |
| `TARGET_SCALE` | cd.yml 입력값(`current` 또는 양의 정수) | — |

`crypto-chat-service`는 컨트롤러·Kafka 바인더·스케줄러가 한 프로세스에 묶여 있어
`TARGET_SCALE`이 `current` 또는 `1`이 아니면 스크립트가 즉시 에러로 종료한다(멀티 인스턴스 미지원).

## 단계별 흐름

1. **활성 슬롯 감지** (`detect_active_slot`)
   - `.deploy/${SERVICE_NAME}.active-slot` 파일이 있으면 그 값(`blue`/`green`)을 그대로 신뢰한다.
   - 파일이 없으면 실행 중인 `${SERVICE_NAME}-blue-*` / `${SERVICE_NAME}-green-*` 컨테이너 개수로
     추정한다. 둘 다 실행 중인데 파일이 없으면 에러 종료(사람이 파일을 수동으로 만들어야 함).
   - 둘 다 없으면 `none` → 다음 슬롯은 무조건 `blue`(최초 배포).

2. **다음 슬롯 결정 및 스케일 계산**
   - `next_slot` = 현재 슬롯의 반대(`blue`↔`green`), 최초 배포면 `blue`.
   - `TARGET_SCALE=current`면 현재 활성 슬롯의 실행 중인 컨테이너 수를 그대로 쓰되, 0이면 1로 올림
     (최초 배포에서 `current`를 넘겨도 최소 1대는 뜨도록).
   - 계산된 scale로 blue/green 포트 범위가 겹치지 않는지 검증(`validate_port_ranges`) — 같은
     서비스 내부 검증만 하고, 다른 서비스와의 포트 충돌은 검증하지 않는다.

3. **이미지 pull**: `docker pull "$IMAGE"`.

4. **다음 슬롯 정리 후 기동** (`remove_slot_containers` → `start_slot`)
   - 다음 슬롯에 남아있을 수 있는 이전 컨테이너를 먼저 강제 제거(`docker rm -f`, 실패 무시).
   - `docker run -d`로 scale만큼 컨테이너를 새로 기동. 라벨(`app`, `deploy.strategy=bluegreen`,
     `deploy.slot`, `deploy.index`, `deploy.managed-by=infra-script`)을 붙여 추적 가능하게 함.
   - 기동 실패 시: 다음 슬롯 정리 후 `exit 1`. **활성 슬롯은 그대로 유지**, `.active-slot` 파일도
     안 바뀜 — 배포 실패해도 기존 서비스는 계속 트래픽을 받는다.

5. **헬스체크** (`wait_for_health`)
   - 다음 슬롯의 각 인스턴스에 대해 `HEALTH_PATH`를 최대 40회(3초 간격, 최대 2분) 폴링.
   - 실패 시: 다음 슬롯 제거 후 `exit 1`. 활성 슬롯 불변.

6. **다음 슬롯 ready 마킹** (`mark_slot_ready` → `deployment_post ... ready`)
   - `DEPLOY_TOKEN`이 비어 있으면 이 단계는 조용히 스킵된다(로그만 남기고 성공 취급).
   - 토큰이 있으면 `X-Deploy-Token` 헤더로 `POST {DEPLOYMENT_BASE_PATH}/ready` 호출.
   - 실패 시: 다음 슬롯 제거 후 `exit 1`. 활성 슬롯 불변.
   - **여기까지 통과하면 배포는 "성공"으로 커밋된 것으로 취급된다.** 이후 단계 실패는 파이프라인을
     실패시키지 않는다(아래 8번 참고).

7. **레거시 compose 컨테이너 정리** (`stop_legacy_container`)
   - 슬롯 접미사 없이 `$SERVICE_NAME` 이름 그대로인 컨테이너가 남아 있으면 강제 제거.
   - blue/green 도입 이전 방식(compose가 슬롯 없이 단일 컨테이너로 관리하던 상태)의 잔재로 보인다 —
     정확한 도입 배경은 저장소 최상위 [`TODO.md`](../TODO.md) 참고.

8. **이전 슬롯 drain 후 정지**
   - 활성 슬롯이 `none`이 아니면: 이전 슬롯을 `not-ready`로 마킹(`|| true`로 실패 무시) →
     `DRAIN_SECONDS`만큼 sleep → 이전 슬롯 컨테이너 전부 `docker rm -f`(실패 무시).
   - **이 단계부터는 실패해도 스크립트가 종료되지 않는다.** 즉 이전 컨테이너 제거가 실패해도
     CD는 성공으로 끝날 수 있고, orphan 컨테이너가 남을 수 있다 — 로그를 봐야 발견 가능.

9. **활성 슬롯 갱신**: `.deploy/${SERVICE_NAME}.active-slot`에 `next_slot` 기록.

10. **결과 출력**: 새 슬롯 라벨 기준으로 `docker ps` 테이블 출력.

## 실패 시 동작 요약

| 실패 지점 | 활성 슬롯 | `.active-slot` 파일 | CD 종료 코드 |
| --- | --- | --- | --- |
| 다음 슬롯 기동 실패 | 유지 | 안 바뀜 | 실패(1) |
| 헬스체크 실패 | 유지 | 안 바뀜 | 실패(1) |
| ready 마킹 실패 | 유지 | 안 바뀜 | 실패(1) |
| 레거시/이전 슬롯 정리 실패 | 이미 next_slot으로 전환됨 | next_slot으로 갱신 | 성공(0) — 로그 확인 필요 |
