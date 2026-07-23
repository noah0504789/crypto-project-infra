# 배포 스크립트 안전 규칙

이 파일은 CLAUDE.md에서 `@import`로 항상 로드된다. `service/scripts/deploy/`, `service/docker-compose.yml`,
`service/.deploy/`를 다룰 때는 무조건 적용된다.

## 왜 조심해야 하는가
`service/scripts/deploy/*.sh`는 **운영 self-hosted runner가 그대로 실행**하는 스크립트다.
`crypto-project-backend`의 `cd.yml`은 입력값 검증(필수 변수 empty 체크, `TARGET_SCALE` 형식 검증)과
스크립트 호출까지만 하고, 실제 배포 실행 로직(헬스체크·rollback 등)은 갖지 않는다 — 이 저장소가
곧 배포 실행 로직의 유일한 소스다. 스테이징 환경이나 dry-run 모드가 없으므로, 스크립트 실행 결과가
그대로 프로덕션 컨테이너 교체로 이어진다. 자세한 배포 흐름은 `docs/DEPLOYMENT_FLOW.md` 참고.

## 수정 전 확인
- **cd.yml과 스크립트는 항상 같이 확인한다.** 스크립트 파일명, 인자 순서(`IMAGE_TAG`, `TARGET_SCALE`),
  exit code는 `crypto-project-backend/.github/workflows/cd.yml`의 `TARGET_SERVICE` case문과 맞물린
  계약이다. 스크립트만 보고 "안전하다"고 판단하지 않는다. 이 계약을 깨는 변경은 backend 저장소도
  함께 수정해야 하므로, 이 저장소만 봐서는 영향 범위를 알 수 없다는 점을 사용자에게 밝힌다.
- **health check 경로(`HEALTH_PATH`), `DEPLOYMENT_BASE_PATH`, `X-Deploy-Token` 헤더명은 외부 계약이다.**
  각 서비스(backend 저장소)의 `/internal/deployment/{ready,not-ready}` 엔드포인트와 1:1로 맞물려
  있다. 임의로 바꾸면 health check는 통과해도 실제 트래픽을 못 받는 상태가 될 수 있다.
- **rollback 경로를 건드리는 변경은 특히 주의한다.** `.deploy/*.current-image`(validated-recreate
  계열의 rollback 대상), `.deploy/*.active-slot`(blue/green 활성 슬롯) 파일 포맷이 깨지면 다음 배포
  때 스크립트가 활성 슬롯을 잘못 판단하거나 rollback 자체가 실패할 수 있다.
- **포트 범위(`BLUE_PORT_START`/`GREEN_PORT_START`)를 바꿀 때는 다른 서비스 스크립트의 포트 범위와
  수동으로 대조한다.** `bluegreen-core.sh`의 `validate_port_ranges`는 같은 서비스의 blue/green
  범위끼리 겹치는지만 검증하며, 다른 서비스 스크립트와의 충돌은 검증하지 않는다.
- **동시 배포에 대한 락(lock) 메커니즘이 없다.** 같은 서비스에 대해 두 배포가 동시에 실행되면
  active-slot 판단이나 컨테이너 상태를 놓고 레이스 컨디션이 생길 수 있다. 여러 배포를 동시에
  트리거하지 않도록 안내하거나, 락 도입이 필요한지는 변경 전 사용자와 상의한다.
- **`.deploy/` 아래 상태 파일은 스크립트가 쓰고 읽는 파일이지, 사람이 직접 편집하는 파일이 아니다.**
  수동으로 고쳐야 하는 유일한 예외는 스크립트 자체가 안내하는 초기화 상황
  (`.current-image`가 아직 없을 때 등)뿐이며, 이때도 값의 출처를 사용자에게 확인한다.

## 실행 · 검증
- 스크립트를 직접 실행(`docker run`, `docker compose up`, `./scripts/deploy/*.sh`)하지 않는다.
  실행은 곧 배포이며, 사용자의 명시적 요청 없이 하지 않는다.
- 정적 분석만으로 "고쳤다"고 말하지 않는다. 실제 실행 검증(별도 스테이징, dry-run)이 불가능한
  환경이면 그 사실을 밝히고, 기존 로직을 최대한 보존하는 최소 diff로 제안한다.
- 변경 후에는 영향받는 서비스의 배포 전략(blue/green · validated-recreate · safe-recreate)이
  무엇인지, 어떤 케이스가 새로 생기는지(스케일 변경, 첫 배포, rollback 등) 시나리오로 짚어본다.

## 민감 정보
- `*/.env`, `service/.deploy/`, `service/certs/*.p12`, `infra/mongo/mongo-keyfile` 등은 `.gitignore`로
  제외되어 있다 — 의도적으로 git 미추적이다. 이 파일들의 **값을 응답에 출력하거나 커밋하지 않는다.**
  커밋하려는 시도 자체가 이상 신호이니 사용자에게 확인한다.
