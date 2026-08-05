# 배포 대상 서비스 스택 (`service/`)

이 문서는 `service/`의 구조(무엇이 있고 어떻게 배포되는지)를 정리한다. **실제 배포 단계별 흐름**은
`docs/DEPLOYMENT_FLOW.md`(개요) + 전략별 문서에 있으니 중복하지 않는다. 이 문서는 "서비스 목록·
포트·배포 방식·상태 파일·자격증명" 같은 구조 지도에 집중한다.

`service/`는 `crypto-project-backend`의 self-hosted runner가 `cd.yml`에서 호출하는 배포 스크립트와,
백엔드 서비스 compose 정의를 담는다. 모든 컨테이너는 `crypto-project-network`(external)에 붙는다.

## 서비스 목록

| 서비스 | 컨테이너 포트 | 전략 | 배포 실행 | compose 정의 |
| --- | --- | --- | --- | --- |
| crypto-spring-cloud-config | 8888 | validated-recreate | `docker run` | 있음 |
| crypto-spring-cloud-eureka-server | 8761 | validated-recreate | `docker run` | 있음 |
| crypto-spring-cloud-api-gateway | 8000 | validated-recreate | `docker run` | 있음(TLS keystore·remote-debug) |
| crypto-oauth2-authorization-server | 9000 | validated-recreate | `docker run` | 있음 |
| crypto-oauth2-client | 8900 | validated-recreate | `docker run` | 있음 |
| crypto-user-service | 8090 | blue/green | `docker run` | 있음 |
| crypto-market-service | 8200 | blue/green | `docker run` | 있음 |
| crypto-chat-service | 8080 | blue/green (scale=1 고정) | `docker run` | 있음 |
| crypto-websocket-gateway | 8100 | blue/green | `docker run` | 있음 |
| crypto-notification-service | 8300 | blue/green | `docker run` | 있음 |
| crypto-outbox-poller | (인바운드 없음) | safe-recreate | `docker run` | 있음(로컬/수동용) |
| crypto-market-detection | (인바운드 없음, actuator 8500 미게시) | safe-recreate | `docker run` | 있음(로컬/수동용) |

blue/green 호스트 포트 범위(스크립트 `*_PORT_START`, 스케일만큼 순차 증가, 서로 겹치지 않게 수동 배정):
chat `8180`/`8280`, user `8190`/`8290`, websocket-gateway `8200`/`8300`, market `8210`/`8310`, notification `8220`/`8320`(blue/green).

## 배포 실행 방식 — CD는 전부 `docker run`, compose는 로컬/수동 전용

compose 파일에 여러 서비스가 정의돼 있지만, **CD 배포 경로는 세 전략 모두 `docker run`으로 직접**
컨테이너를 띄운다. compose 파일을 참조하는 배포 스크립트는 없다.

- blue/green(user/market/chat/websocket-gateway/notification)·validated-recreate(config/eureka/api-gateway/
  oauth2-*)·safe-recreate(outbox-poller/market-detection) 스크립트 전부 `docker run`이다.
- 그래서 compose의 이미지 태그 변수(`CONFIG_SERVER_IMAGE_TAG`/`EUREKA_SERVER_IMAGE_TAG`/
  `OUTBOX_POLLER_IMAGE_TAG` 등)는 **CD에서 쓰이지 않는다**(compose 파일 안에서만 참조). CD가 실제로
  쓰는 이미지 태그는 스크립트 인자(`IMAGE_TAG`)로 들어온다.
- 결과적으로 **모든 서비스의 compose 정의(포트·`mem_limit`·`JAVA_TOOL_OPTIONS`)는 wrapper
  스크립트의 값과 중복**된다. 한쪽만 바꾸면 드리프트가 생긴다(→ 루트 `TODO.md`). compose 정의는
  주로 로컬/수동 `docker compose up` 편의를 위한 것으로 보인다(확정 아님 — 필요 시 확인).

전략별 실제 단계는 `docs/DEPLOYMENT_FLOW_BLUEGREEN.md` / `_VALIDATED_RECREATE.md` /
`_SAFE_RECREATE.md` 참고.

## `.deploy/` — 배포 런타임 상태 (git 미추적)

스크립트가 읽고 쓰는 상태 파일. `.gitignore` 대상이라 fresh clone에는 없다. 사람이 직접 편집하지
않는다(초기 부트스트랩 제외 — 아래).

- **blue/green** → `.deploy/<전체 서비스명>.active-slot` (예: `crypto-user-service.active-slot`),
  값은 `blue` 또는 `green`.
- **blue/green** → `.deploy/<전체 서비스명>.current-image` — 배포 성공 후 그 슬롯의 이미지
  다이제스트를 `bluegreen-core.sh`가 기록한다. **배포 중 롤백용이 아니다**(blue/green 은 새 슬롯이
  health check 를 통과할 때까지 옛 슬롯을 유지하므로 실패 시 '전환하지 않음'이 곧 롤백이며, 별도
  rollback 함수가 없다). 이 파일은 **무엇이 떠 있는지 아는 용도**다 — 이미지 태그를 정리할 때
  운영본을 보호하고, 나중에 되돌릴 기준점이 된다. 태그(`:latest`)는 머지마다 옮겨가 기준이 못 된다.
  다이제스트를 얻을 수 없으면(로컬 빌드 등) 경고만 남기고 배포는 계속한다.
- **validated-recreate / safe-recreate** → `.deploy/<짧은 이름>.current-image` (예:
  `api-gateway.current-image`, `spring-cloud-config.current-image`, `outbox-poller.current-image`),
  값은 rollback 대상 이미지 다이제스트. **최초 배포 전에 수동 생성이 필요**하다(스크립트가 없으면
  에러로 안내).
- 네이밍이 두 갈래다: blue/green 은 전체 서비스명(`crypto-user-service.*`), validated/safe-recreate 는 짧은 이름(`api-gateway.current-image`).
- oauth2-authorization-server·oauth2-client는 과거 blue/green이었다가 validated-recreate로 전환돼서,
  로컬 `.deploy/`에 옛 `crypto-oauth2-*.active-slot`와 현재 `oauth2-*.current-image`가 함께 남아 있을
  수 있다(옛 slot 파일은 현재 미사용 잔재).

## 이미지 태그 정리 (`scripts/cleanup-dockerhub-tags.sh`)

main 머지마다 서비스별 `<sha7>` 태그가 하나씩 쌓인다(실측 40~70개). 정리하되 **현재 배포본을 지우면 안 된다.**

**"최신 N개만 남기기"는 쓸 수 없다.** 빌드는 머지마다, 배포는 가끔이라 현재 배포본이 목록 뒤쪽에 있다 — 실측에서 api-gateway 는 23번째, eureka-server 는 26번째였다. 5개로 자르면 운영 이미지가 사라진다.

보호 기준은 나이가 아니라 **`.deploy/*.current-image` 의 다이제스트**다.

```
보존: latest + current-image 가 가리키는 배포본 + 최근 N개(기본 10)
제외: .current-image 가 없는 서비스는 통째로 건너뛴다 (무엇이 떠 있는지 모른다)
```

`.deploy/` 를 읽어야 하므로 **배포 호스트에서 실행**한다. GitHub Actions 로는 못 옮긴다(그 상태 파일이 저장소에 없다).

자격증명은 배포 스크립트와 같이 `service/.env` 에서 읽는다(git 미추적). `DOCKERHUB_USERNAME` 은 이미 있으므로 **Read/Write/Delete 스코프 PAT 을 `DOCKERHUB_TOKEN` 으로 추가**하면 인자 없이 실행된다. 환경변수로 준 값이 `.env` 보다 우선한다.

기본은 dry-run 이고 `--apply` 를 줘야 실제로 지운다. macOS 기본 bash 3.2 에서도 동작한다(`mapfile` 등 bash 4+ 문법 미사용).

## 자격증명 · 설정 (`service/.env`, git 미추적)

스크립트/compose가 참조하는 키:

| 키 | 용도 |
| --- | --- |
| `DOCKERHUB_USERNAME` | 이미지 레포 접두사(`<user>/crypto-...`) |
| `DEPLOY_TOKEN` | `/internal/deployment/{ready,not-ready}` 호출용 `X-Deploy-Token` 헤더 |
| `VAULT_ROLE_ID` / `VAULT_SECRET_ID` | Spring Cloud Config가 Vault AppRole로 시크릿 로드 |
| `REMOTE_DEBUG_ENABLED` / `REMOTE_DEBUG_PORT_OFFSET` | validated-recreate·blue/green 원격 디버그(JDWP) 옵션 |
| `REMOTE_DEBUG_SLOT_OFFSET` | blue/green의 Green 디버그 포트 슬롯 간격(기본 5) |

- `DEPLOY_TOKEN` 필수 여부는 스크립트마다 다르다(→ `docs/DEPLOYMENT_FLOW_VALIDATED_RECREATE.md`, `TODO.md`).
- 값은 `.gitignore` 대상 — 출력·커밋 금지(→ `.claude/rules/git-safety.md`).

## `certs/`

- `certs/keystore.p12`(TLS keystore)는 api-gateway가 `-v ./certs/keystore.p12:/certs/keystore.p12:ro`로
  마운트한다. api-gateway validated-recreate 스크립트는 이 파일이 없으면 배포를 중단한다.
- `*.p12`는 `.gitignore` 대상, `certs/.gitkeep`만 커밋된다.

## 관련 문서·규칙
- 배포 스크립트 수정 안전 규칙: `.claude/rules/deploy-safety.md`
- 배포 흐름: `docs/DEPLOYMENT_FLOW.md`(개요) + 전략별 문서
- 확인 필요·예정 작업: 루트 `TODO.md`
