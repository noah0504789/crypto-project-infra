# 배포 흐름 — Blue/Green (`bluegreen-core.sh`)

전체 개요와 다른 전략은 [DEPLOYMENT_FLOW.md](./DEPLOYMENT_FLOW.md) 참고.

대상 서비스: `crypto-user-service`, `crypto-market-service`, `crypto-websocket-gateway`,
`crypto-chat-service`, `crypto-notification-service`. 각 서비스는 `deploy-<service>-bluegreen.sh`
wrapper에서 포트/헬스체크 경로 등 파라미터만 export하고 `bluegreen-core.sh`를 그대로 실행(`exec`)한다.

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
| `REMOTE_DEBUG_ENABLED` | `true`면 각 JVM에 JDWP agent를 추가(기본 `false`) | `false` |
| `REMOTE_DEBUG_PORT_OFFSET` | Blue 디버그 시작 포트 = 컨테이너 서비스 포트 + offset | `20000` |
| `REMOTE_DEBUG_PORT` | 지정 시 계산값 대신 Blue 첫 인스턴스 포트로 사용 | 미지정 |
| `REMOTE_DEBUG_SLOT_OFFSET` | Green 시작 포트에 더할 슬롯 간격 | `5` |
| `REMOTE_DEBUG_SUSPEND` | `y`면 디버거 연결 전까지 JVM 시작 보류 | `n` |

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
     `deploy.slot`, `deploy.index`, `deploy.managed-by=infra-script`, `remote-debug.enabled`,
     `remote-debug.port`)을 붙여 추적 가능하게 함.
   - **앱 포트는 `127.0.0.1:${host_port}:${CONTAINER_PORT}`로 host-local 바인딩**한다(외부 인터페이스에
     노출 안 함). 인터서비스 통신은 Docker 네트워크 + Eureka(`hostname:CONTAINER_PORT`)로 이뤄지고,
     헬스체크는 `localhost:${host_port}`라 그대로 동작한다. 외부에서 게이트웨이를 우회해 서비스에 직접
     요청하며 `X-User-Id`를 위조하는 것을 막기 위함(backend `TODO 1.8`, 루트 `TODO.md` 보안 절).
   - 원격 디버그를 활성화하면 각 컨테이너의 `JAVA_TOOL_OPTIONS`에
     `-agentlib:jdwp=transport=dt_socket,server=y,suspend=...,address=*:<debug-port>`를 추가하고,
     호스트에는 `127.0.0.1:<debug-port>:<debug-port>`로만 바인딩한다. 같은 호스트에서 실행하는
     디버거는 SSH 터널 없이 `localhost:<debug-port>`로 연결할 수 있다.
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
   - blue/green 도입 이전에 compose가 `$SERVICE_NAME` 단일 컨테이너로 관리하던 방식의 잔재를 청소하는
     안전장치다(그 방식은 한때 compose의 `legacy` 프로필로 남아 있다가 제거됨 — 커밋
     "블루그린 컨테이너: 기존방식으로 올릴때는 profile을 legacy로"). 프로필 제거 후에는 일반
     `docker compose up`으로도 그 단일 컨테이너가 뜰 수 있어 이 청소 로직은 여전히 유효하다.

8. **이전 슬롯 drain 후 정지**
   - 활성 슬롯이 `none`이 아니면: 이전 슬롯을 `not-ready`로 마킹(`|| true`로 실패 무시) →
     `DRAIN_SECONDS`만큼 sleep → 이전 슬롯 컨테이너 전부 `docker rm -f`(실패 무시).
   - **이 단계부터는 실패해도 스크립트가 종료되지 않는다.** 즉 이전 컨테이너 제거가 실패해도
     CD는 성공으로 끝날 수 있고, orphan 컨테이너가 남을 수 있다 — 로그를 봐야 발견 가능.

9. **활성 슬롯 갱신**: `.deploy/${SERVICE_NAME}.active-slot`에 `next_slot` 기록.

10. **결과 출력**: 새 슬롯 라벨 기준으로 `docker ps` 테이블 출력.

## 원격 디버그 (JDWP)

validated-recreate와 동일하게 서비스의 컨테이너 포트에 `REMOTE_DEBUG_PORT_OFFSET`을 더해
Blue 첫 인스턴스의 디버그 포트를 계산한다. Blue/Green은 두 슬롯과 여러 인스턴스가 동시에
실행될 수 있으므로 Green에는 `REMOTE_DEBUG_SLOT_OFFSET`을 추가하고, 각 슬롯 안에서는 scale
인덱스만큼 순차 증가시킨다. `REMOTE_DEBUG_PORT`를 직접 지정하면 그 값을 Blue 첫 인스턴스에
사용한다. 예를 들어 user-service에 `REMOTE_DEBUG_PORT=5005`를 지정하면 Blue는 `5005...`,
Green은 `5010...`을 사용한다.

기본 offset `20000`에서의 예:

| 서비스 | blue debug 포트 시작 | green debug 포트 시작 |
| --- | ---: | ---: |
| chat-service | 28080 | 28085 |
| user-service | 28090 | 28095 |
| websocket-gateway | 28100 | 28105 |
| market-service | 28200 | 28205 |
| notification-service | 28300 | 28305 |

scale이 3이면 시작 포트부터 3개를 순차 사용한다. 기본 슬롯 간격이 5이므로 scale이 5를
초과하면 Blue/Green 범위가 겹쳐 배포 전에 차단된다. 스크립트는 활성화 시 포트 형식·범위,
Blue/Green debug 범위 중첩 및 앱 포트 범위와의 충돌을 이미지 pull 전에 검증한다.

JDWP는 인증 기능이 없으므로 호스트의 외부 인터페이스에는 공개하지 않는다. IntelliJ와 서비스
호스트가 다를 때만 SSH 터널을 사용한다.

## 실패 시 동작 요약

| 실패 지점 | 활성 슬롯 | `.active-slot` 파일 | CD 종료 코드 |
| --- | --- | --- | --- |
| 다음 슬롯 기동 실패 | 유지 | 안 바뀜 | 실패(1) |
| 헬스체크 실패 | 유지 | 안 바뀜 | 실패(1) |
| ready 마킹 실패 | 유지 | 안 바뀜 | 실패(1) |
| 레거시/이전 슬롯 정리 실패 | 이미 next_slot으로 전환됨 | next_slot으로 갱신 | 성공(0) — 로그 확인 필요 |
