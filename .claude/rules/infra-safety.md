# 인프라 스택 안전 규칙

이 파일은 `infra/`(및 같은 네트워크를 쓰는 `monitoring/`) 스택을 다룰 때 읽는다. 스택 구성 설명은
`docs/INFRA.md` 참고. Git·시크릿 관련 무조건 규칙은 `.claude/rules/git-safety.md`(별도)에 있다.

## 상태 저장 스택이라는 점을 항상 인지한다
- `infra/`의 모든 데이터 볼륨과 `crypto-project-network`는 `external: true`다. 볼륨에는 MySQL/
  MongoDB/Redis/Kafka/Vault의 **영구 데이터**가 들어 있다.
- **`docker compose down -v`, `docker volume rm`, `docker volume prune`, `docker system prune`은
  곧 데이터 영구 삭제**다. 사용자의 명시적 승인 없이 실행하지 않는다. `down`(볼륨 미삭제)조차도
  운영 중이면 다운타임이므로 승인을 받는다.
- 개별 컨테이너를 `docker rm -f`로 지우거나 `docker compose restart`하는 것도 상태/복제에 영향을
  줄 수 있다. 실행 전 영향 범위를 먼저 설명한다.

## 부트스트랩 순서·수동 단계
- 네트워크/볼륨은 compose가 만들지 않는다(external). 없으면 먼저 생성해야 한다.
- 다음은 compose 파일에 자동화되어 있지 않다(수동/외부 단계, `TODO.md` 참고):
  MySQL replica 복제 연결(`CHANGE REPLICATION SOURCE`/`START REPLICA`), Redis 클러스터 생성
  (`redis-cli --cluster create`), Vault `operator init`/`unseal`.
- 이 절차를 "자동으로 될 것"이라고 단정하지 말고, 확인되지 않았으면 `확인 필요`로 표시한다.

## 시크릿·설정 파일
- `infra/mongo/mongo-keyfile`, `infra/.env`는 `.gitignore` 대상이다 — 값을 출력하거나 커밋하지 않는다.
- Vault root token / unseal key는 어떤 경우에도 응답에 노출하지 않는다.
- `mysql-init.sql`, `mongo-user.js`의 계정/비밀번호는 로컬 dev 기준으로 하드코딩되어 있다. 운영에서
  같은 값을 쓰는지는 확인되지 않았으므로(→ `TODO.md`), 이 값을 "운영 자격증명"으로 단정하지 않는다.

## 변경 시
- 포트·복제 토폴로지·`server-id`·`replSetName`·`CLUSTER_ID`·Redis 슬롯 구성은 이미 초기화된 볼륨과
  맞물린다. 이미 데이터가 있는 볼륨에 대해 이런 값을 바꾸면 클러스터가 깨질 수 있으므로 변경 전
  영향(재초기화 필요 여부)을 먼저 분석한다.
- 스택을 직접 기동/정지(`docker compose up/down`)하지 않는다. 실행은 사용자의 명시적 요청이 있을 때만.
