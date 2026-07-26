# service/ — 백엔드 배포 스택

`crypto-project-backend`의 self-hosted runner가 `cd.yml`에서 호출하는 배포 스크립트와 compose
정의가 있다. **여기 스크립트가 실제 프로덕션 컨테이너를 기동/교체하는 유일한 실행 경로**다.

## 먼저 읽을 것
- 스크립트(`scripts/deploy/`)·`docker-compose.yml`·`.deploy/` 수정 시: `.claude/rules/deploy-safety.md` (필수)
- 서비스 구조(목록·포트·배포 방식·상태 파일): `docs/SERVICE.md`
- 배포 흐름 상세: `docs/DEPLOYMENT_FLOW.md`(개요) → 전략별 `_BLUEGREEN` / `_VALIDATED_RECREATE` / `_SAFE_RECREATE.md`

## 핵심 주의
- 스크립트 파일명·인자 순서(`IMAGE_TAG`, `TARGET_SCALE`)·exit code는 backend `cd.yml`의
  `TARGET_SERVICE` case문과 맞물린 계약이다. 바꾸면 backend 저장소도 같이 고쳐야 하고, 이 저장소만
  봐서는 깨졌는지 알 수 없다.
- `.deploy/`는 스크립트가 읽고 쓰는 런타임 상태(`*.active-slot` / `*.current-image`, git 미추적).
  사람이 직접 편집하는 파일이 아니다.
- **CD 배포가 `docker compose`를 쓰는 건 safe-recreate(outbox-poller·market-detection)뿐.** 나머지
  (blue/green·validated-recreate)는 스크립트가 `docker run`으로 직접 띄운다 — compose의 blue/green·
  validated-recreate 서비스 정의와 `*_IMAGE_TAG` 변수는 CD에서 안 쓰이고 스크립트 값과 중복된다(드리프트 주의).
- 스크립트 직접 실행 = 배포. 사용자의 명시적 요청 없이 실행하지 않는다.
