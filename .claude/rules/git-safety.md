# Git · 안전 규칙

이 파일은 자동으로 로드되지 않는다(루트 `CLAUDE.md`의 "규칙 참조" 표 참고). Git 조작(commit/push/
merge/rebase)이나 민감 정보(`.env`/`.deploy/`/인증서 등)를 다루기 전에 먼저 읽고, 그 작업에는
아래 규칙을 무조건 적용한다.

## 파일 변경 전
- 파일을 수정하기 전에 Git 상태를 확인한다: `git status --short`.
- 사용자가 이미 작업한 내용을 명시적 승인 없이 덮어쓰거나 되돌리지 않는다.

## Git · 배포
- 사용자가 명시적으로 요청하지 않는 한 `commit`, `push`, `merge`, `rebase`, 배포 실행(`docker compose up`,
  `docker run`, `service/scripts/deploy/*.sh` 직접 실행)을 하지 않는다.
- 이 저장소의 변경은 다음 CD 실행 시 운영에 바로 반영된다는 점을 감안해, 배포 스크립트/compose 변경은
  기본적으로 먼저 분석·계획을 제시하고 승인받는다(자세한 배포 스크립트 관련 규칙은
  `.claude/rules/deploy-safety.md` 참고).

## 민감 정보 (출력·커밋 금지)
- `*/.env`, `service/.deploy/`, `service/certs/*.p12`/`*.jks`/`*.key`/`*.crt`/`*.pem`, `infra/mongo/mongo-keyfile`
  등 `.gitignore`로 제외된 파일의 값을 응답에 출력하거나 커밋하지 않는다.
- Vault Role ID/Secret ID, Deploy Token, DB 계정 등 민감한 값은 요청하지 않은 이상 추측하거나 노출하지 않는다.
