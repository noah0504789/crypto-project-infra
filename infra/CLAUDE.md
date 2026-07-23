# infra/ — 상태 저장 인프라 스택

MySQL(master/replica)·Redis(6-node 클러스터)·MongoDB(replica set)·Kafka(KRaft 2-broker)·Vault +
관리 UI의 Docker Compose. 백엔드가 의존하는 **상태 저장 스택**이며, `service/`와는 별개로
`crypto-project-network`(external)로만 연결된다.

## 먼저 읽을 것
- 이 스택 조작·수정 시: `.claude/rules/infra-safety.md` (필수)
- 구성·포트·부트스트랩·자격증명(.env 키 목록): `docs/INFRA.md`

## 핵심 주의
- 네트워크·데이터 볼륨이 전부 `external: true` → 최초 1회 수동 생성 필요. **볼륨 삭제
  (`docker compose down -v`, `volume rm`/`prune`)는 DB·메시지 영구 손실** — 승인 없이 금지.
- DB 비밀번호는 committed 파일에 두지 않고 `infra/.env`(git 미추적)에서 주입한다. 키 목록은
  `docs/INFRA.md` "자격증명" 표. init 스크립트(`mysql-init.sh`, `mongo-*.js`)는 **fresh 볼륨에서만** 실행.
- `mongo/mongo-keyfile`, `.env`는 `.gitignore` 대상 — 값 출력·커밋 금지.
- MySQL replica 복제 연결·Redis 클러스터 생성·Vault init/unseal은 자동화되어 있지 않다(→ 루트 `TODO.md`).
