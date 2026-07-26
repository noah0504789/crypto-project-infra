# 배포 흐름 — Validated Recreate (`deploy-*-validated-recreate.sh`)

전체 개요와 다른 전략은 [DEPLOYMENT_FLOW.md](./DEPLOYMENT_FLOW.md) 참고.

대상: `crypto-spring-cloud-config`, `crypto-spring-cloud-eureka-server`,
`crypto-spring-cloud-api-gateway`, `crypto-oauth2-authorization-server`, `crypto-oauth2-client`.
Blue/Green과 달리 **공통 core 스크립트가 없다** — 5개 스크립트가 각자 독립적으로 같은 패턴을
구현하고 있으며, 아래 표에서 보듯 세부 동작이 서비스마다 조금씩 다르다.

## 공통 큰 그림

후보(candidate) 컨테이너를 별도 포트에 띄워 검증한 뒤, 통과하면 운영(public) 컨테이너를 교체한다.
운영 교체 후에도 실패하면 이전 이미지로 자동 rollback을 시도한다. Blue/Green처럼 두 슬롯을 계속
유지하는 게 아니라, candidate는 검증 후 항상 제거되고 운영 컨테이너 하나만 남는다.

## 서비스별 차이

| 항목 | config | eureka | api-gateway | oauth2-authorization-server | oauth2-client |
| --- | --- | --- | --- | --- | --- |
| Health scheme | http | http | **https** (`CURL_INSECURE` 기본 true) | http | http |
| `DEPLOY_TOKEN` 필수 여부 | 선택 (없으면 ready 마킹 스킵, 성공 취급) | **필수** (main() 시작 시 명시적 체크로 exit 1) | 선택 (스킵) | **필수** (`:?` 파라미터 확장, 스크립트 로드 시점에 실패) | **필수** (`:?`) |
| `.deploy/*.current-image` 사전 존재 요구 | **필수** (없으면 최초부터 exit 1, 수동 부트스트랩 필요) | **필수** | **필수** | 불필요 (운영 컨테이너가 있으면 교체 직전에 자동으로 캡처) | 불필요 (동일) |
| 특이 기능 | candidate 포트 8898 | candidate 포트 18761 · candidate도 ready 마킹까지 검증(다른 스크립트는 candidate 헬스체크만) | keystore(TLS) 마운트 필수 | candidate 포트 9010 | candidate 포트 8930 |

## 원격 디버그 (JDWP)

원래 api-gateway에만 있던 원격 디버그 옵션을 **5개 validated-recreate 스크립트 전부에 동일하게
적용**했다(api-gateway가 원본 패턴). 각 스크립트는 아래 환경변수를 읽는다.

| 변수 | 기본값 | 의미 |
| --- | --- | --- |
| `REMOTE_DEBUG_ENABLED` | `false` | `true`면 JVM에 JDWP agent 옵션을 붙인다. |
| `REMOTE_DEBUG_PORT_OFFSET` | `20000` | 디버그 포트 = `PUBLIC_PORT + offset` 로 계산. |
| `REMOTE_DEBUG_PORT` | `PUBLIC_PORT + OFFSET` | 직접 지정하면 계산값보다 우선. |
| `REMOTE_DEBUG_SUSPEND` | `n` | `y`면 디버거 접속 전까지 JVM 시작을 보류. |

`REMOTE_DEBUG_ENABLED`/`REMOTE_DEBUG_PORT_OFFSET`는 `service/.env`에 키가 있다(값은 git 미추적).

동작 요약:
- `enabled=true`면 `EFFECTIVE_JAVA_TOOL_OPTIONS`에
  `-agentlib:jdwp=transport=dt_socket,server=y,suspend=...,address=*:<port>`가 추가되어 컨테이너에 주입된다.
- **호스트 디버그 포트는 운영(public) 컨테이너에만, `127.0.0.1`로만 바인딩**한다. candidate
  컨테이너에는 호스트 포트를 노출하지 않는다(컨테이너 내부에서만 agent가 뜬다). 외부 네트워크에서
  JDWP 포트에 직접 붙지 못하게 하려는 의도.
- `main()` 시작 시 `validate_boolean`/`validate_port`로 값을 검증하고, 디버그 포트가 `PUBLIC_PORT`
  또는 `CANDIDATE_PORT`와 충돌하면 배포를 시작하지 않고 종료한다.
- 컨테이너에 `remote-debug.enabled`/`remote-debug.port` 라벨이 붙는다.

## 앱 포트 바인딩 (외부 노출 차단)

- **eureka·oauth2-authorization-server·oauth2-client**: 앱 포트를 `-p 127.0.0.1:${host_port}:${CONTAINER_PORT}`로
  host-local 바인딩한다. 인터서비스는 Docker 네트워크/Eureka로, 헬스체크·ready는 `localhost`로 접근하므로
  영향 없고, 게이트웨이를 우회한 외부 직접 접근만 차단한다(하위 서비스의 `X-User-Id` 무검증 신뢰 → backend `TODO 1.8`).
- **api-gateway**: 외부 진입점이라 **의도적으로 `0.0.0.0` 유지**(스크립트 주석). 여기를 `127.0.0.1`로 묶으면 외부 접근 불가.
- **config**: 아직 `0.0.0.0`. config-bus 워크플로우가 `CONFIG_SERVER_URL`로 busrefresh를 호출하므로, 그 값이
  localhost 기반인지 확인 후 전환한다(루트 `TODO.md` "보안 · 네트워크 노출").

## 단계별 흐름 (공통 뼈대, config 기준)

1. **사전 검증**: `CONFIG_REPO_URI`/`VAULT_ROLE_ID`/`VAULT_SECRET_ID` 등 필수 환경변수 확인(서비스마다
   다름), `.deploy/*.current-image` 존재 확인(config/eureka/api-gateway만 필수).
2. **새 이미지 pull**.
3. **candidate 컨테이너 정리 후 기동**: 후보 컨테이너를 candidate 포트로 `docker run`.
4. **candidate 헬스체크**: 실패 시 candidate 제거하고 `exit 1` — **운영 컨테이너는 손대지 않은
   상태**라 이 단계 실패는 운영에 영향이 없다.
5. **(oauth2 계열만) 교체 직전 현재 운영 이미지 다이제스트 캡처**: 운영 컨테이너가 떠 있으면
   `resolve_running_image_digest`로 다이제스트를 읽어 `.current-image` 파일에 미리 써둔다(이번
   배포의 rollback 대상 확정). 실패해도 경고만 남기고 진행한다.
6. **운영 컨테이너 교체**: 기존 `$SERVICE` 컨테이너 제거 → 새 이미지로 재기동(같은 public 포트).
7. **운영 헬스체크**: 실패 시 **rollback 시도** — `.current-image`의 이전 이미지로 운영 컨테이너를
   다시 교체하고 재검증. rollback까지 실패하면 "수동 개입 필요" 메시지와 함께 `exit 1`(운영이
   내려간 상태로 남을 수 있음).
8. **운영 ready 마킹** (`deployment_post ... ready`): 실패 시 7번과 동일하게 rollback 시도.
9. **현재 이미지 다이제스트 갱신**: 새로 뜬 운영 컨테이너의 다이제스트를 `.current-image`에 기록
   (다음 배포의 rollback 대상이 됨). config/eureka/api-gateway는 이 단계 실패 시에도 rollback을
   시도한다(다이제스트를 못 구했다는 것은 운영 컨테이너 상태가 의심스럽다는 뜻으로 취급).
10. **candidate 컨테이너 제거**, 결과 출력.

## 실패 시 동작 요약

| 실패 지점 | 운영 컨테이너 상태 | `.current-image` | CD 종료 코드 |
| --- | --- | --- | --- |
| candidate 헬스체크 실패 | 기존 이미지로 계속 서비스 중(무변화) | 안 바뀜 | 실패(1) |
| 운영 교체 후 헬스체크/ready 실패, rollback 성공 | 이전 이미지로 복구됨 | 안 바뀜(rollback 성공 시) | 실패(1) — 배포는 실패지만 서비스는 복구됨 |
| 운영 교체 후 헬스체크/ready 실패, rollback도 실패 | **불확실 — 수동 개입 필요** | 불확실 | 실패(1) |
| 새 다이제스트 조회 실패 (config/eureka/api-gateway) | rollback 시도 → 위 두 케이스와 동일 | — | 실패(1) |
