# TODO

`docs/DEPLOYMENT_FLOW*.md`에 흩어져 있던 "확인 필요"(코드만으로는 판단 불가능한 항목)와, 아직
구현되지 않은 예정 작업을 여기 한 곳에 모아 관리한다. 항목을 확인했으면 결론을 한 줄 추가하고
체크, 또는 결론을 관련 문서에 반영한 뒤 여기서 지운다. 새로 생기는 "확인 필요"나 예정 작업은
해당 배포 문서가 아니라 여기에 추가한다.

## 예정된 서비스 온보딩 (아직 미구현)

- [ ] **market-service compose 등록 미완료.** `service/scripts/deploy/deploy-market-service-bluegreen.sh`와
  `cd.yml`의 `crypto-market-service` case는 이미 있지만, `service/docker-compose.yml`에는 정의 자체가
  없다(compose에 정의 자체가 없다). 전략: **Blue/Green**.
  compose 등록만 추가하면 된다.
- [ ] **notification 서비스 신규 추가 예정.** 전략: **Blue/Green**. 스크립트(`deploy-notification-bluegreen.sh`
  등), `cd.yml`의 `TARGET_SERVICE` case, compose 등록 모두 아직 없다.
  기존 blue/green wrapper(예: `deploy-user-service-bluegreen.sh`)를 템플릿으로 참고.
- [ ] **market-detection 서비스 신규 추가 예정.** 전략: **Safe Recreate**. 스크립트, `cd.yml` case,
  compose 등록 모두 아직 없다. `outbox-poller` 패턴(compose에 등록 +
  `docker compose up -d --force-recreate` 기반 스크립트, HTTP 헬스체크 없음)을 템플릿으로 참고.

세 서비스가 추가되면 `CLAUDE.md` 디렉토리 표, `docs/DEPLOYMENT_FLOW.md`의 전략 비교 표,
`docs/DEPLOYMENT_FLOW_BLUEGREEN.md`/`_SAFE_RECREATE.md`의 대상 서비스 목록,
`.claude/rules/deploy-safety.md`를 함께 갱신해야 한다.

## 서비스 스택 (`service/`)

- [ ] **compose 정의 ↔ 스크립트 파라미터 드리프트.** config/eureka/api-gateway/oauth2-*/user/chat/
  websocket 서비스는 스크립트가 `docker run`으로 배포하는데, `service/docker-compose.yml`에도 같은
  서비스가 정의되어 포트·`mem_limit`·`JAVA_TOOL_OPTIONS`가 중복된다. CD 배포 경로는 이 compose 정의를
  쓰지 않으므로(outbox-poller 제외) 한쪽만 바꾸면 값이 어긋난다. compose 정의를 로컬/수동 용도로
  유지할지, single-source로 정리할지 결정 필요. (출처: `docs/SERVICE.md`)

## 모니터링 스택 (`monitoring/`)

- [x] **로그(Loki/Promtail)·트레이스(Tempo/OTel) 스택 제거.** 작업 중단분이라 compose 서비스·설정
  파일(`grafana/loki.yml`·`tempo.yml`·`promtail.yml`)·`tempo-data` 볼륨·grafana Tempo 데이터소스·
  prometheus의 관련 주석 job을 모두 삭제. 메트릭 전용으로 정리됨. (부수 효과: 옛 "otel 설정 누락",
  "grafana provisioning 경로에 비-datasource yaml 혼재" 이슈도 함께 해소.)
- [x] **Prometheus 서비스 scrape 대상 ↔ blue/green 컨테이너명 불일치.** 정적 target(`crypto-chat-service:8080`
  등)이 실제 blue/green 컨테이너명(`...-blue-1`)과 안 맞아 수집이 안 되던 문제. `docker_sd_configs`
  기반 자동 발견(`app=<서비스명>` 라벨)으로 교체 → 슬롯 전환·scale 변경에 자동 대응. 임시 컨테이너로
  발견+relabel 동작 검증 완료.
- [ ] **Prometheus docker.sock + `user: root` 보안 강화.** 자동 발견(`docker_sd`)이 컨테이너 목록을
  Docker에 질의해야 해서 `monitoring/docker-compose.yml`의 prometheus에 `/var/run/docker.sock`을 마운트하고,
  기본 사용자(nobody)로는 소켓 읽기 권한이 없어 `user: root`로 실행 중이다(권한 문제로 필요, 검증됨).
  - **위험**: root + Docker 소켓 = 사실상 호스트 Docker 전체 제어 권한. Prometheus가 뚫리면 호스트 장악 가능.
  - **`:ro` 함정**: 소켓을 `:ro`로 마운트해도 Docker API는 양방향이라 읽기 전용으로 제한되지 않는다
    (파괴적 명령도 통함). 즉 `:ro`는 실질 보호가 아니다.
  - **개선안**: 읽기 요청만 통과시키는 docker-socket-proxy를 앞에 두면 root·직접 소켓 마운트 없이
    최소 권한으로 자동 발견 가능. 도입 검토. (출처: `docs/MONITORING.md`)
- [ ] **미사용/비활성 설정 정리.** `prometheus.rules.yml`(+ `rule_files`·rules 마운트 주석 처리로 미로드)
  — 의도적 비활성인지 잔재인지 확인 후 정리. (출처: `docs/MONITORING.md`)
  - `replica-my.cnf`(미사용 중복 파일)는 삭제 완료.
  - mongo secondary exporter scrape는 주석 해제해 수집하도록 처리 완료.
  - `monitoring/.env`의 `MYSQL_EXPORTER_USER`/`_PASSWORD`는 죽은 값(어디서도 참조 안 됨, 값도 실제와 불일치)으로
    확인 후 삭제 완료(mysql exporter는 `my-*.cnf`에서 자격증명을 읽음).
- [x] **Grafana admin 자격증명 평문 제거.** compose의 `admin`/`admin` 하드코딩을 `monitoring/.env`
  (`GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD`) 주입으로 전환(de-hardcode, 값은 유지). `docker compose
  config`로 치환 검증. 운영에서 실제 비밀번호 변경은 별도.

## 인프라 스택 (`infra/`)

- [ ] **MySQL replica 복제 연결 자동화 여부.** `mysql-replica.cnf`는 `read_only`/`server-id=2`만
  설정하고, replica가 master를 바라보게 하는 `CHANGE REPLICATION SOURCE TO ... / START REPLICA`가
  저장소 파일에 없다. 최초 1회 수동으로 하는지, 외부 스크립트가 있는지 확인 필요.
  (출처: `docs/INFRA.md`)
- [ ] **Redis 클러스터 생성 자동화 여부.** compose는 6개 노드를 `cluster-enabled`로 띄우기만 하고,
  실제 슬롯 할당(`redis-cli --cluster create ...`)이 저장소에 없다. 최초 1회 수동 단계로 보이는데
  확인 필요. (출처: `docs/INFRA.md`)
- [ ] **Vault init/unseal 절차.** `vault.hcl`에 자동 init/unseal이 없다. 운영에서 최초 기동 후
  `operator init`/`unseal`을 어떻게(누가/어디에 키 보관) 수행하는지 확인 필요. (출처: `docs/INFRA.md`)
- [x] **infra committed 파일의 평문 DB 비밀번호 제거.** `mysql-init`(→`.sh`)·`mongo-*.js`·compose에서
  평문을 걷어내고 `infra/.env`(git 미추적) 주입으로 전환함. 필요한 키 목록은 `docs/INFRA.md`
  "자격증명" 표에 정리. 값은 회전하지 않고 기존과 동일하게 유지(de-hardcode만).
  `docker compose config` + 임시 컨테이너 fresh init으로 검증 완료.
- [ ] **기존 볼륨 비밀번호 회전.** 위 전환은 **fresh 볼륨에서만** 반영된다. 이미 초기화된
  mysql/mongo 볼륨은 여전히 옛 비밀번호를 갖고 있다. 값을 실제로 바꾸려면 수동 회전 또는 볼륨 재초기화가
  필요하다(데이터 영향 — `.claude/rules/infra-safety.md`).
- [ ] **git 히스토리의 평문 잔존.** 과거 커밋에는 평문 비밀번호가 그대로 남아 있다. 실제 노출 위험으로
  판단되면 히스토리 정리(예: filter-repo)나 비밀번호 회전을 검토해야 한다.
- [ ] **monitoring 쪽 평문 exporter 자격증명(별도).** `monitoring/my-primary.cnf`·`my-replica.cnf`에는
  아직 exporter 비밀번호가 평문으로 있다. infra `.env`의 `MYSQL_EXPORTER_PASSWORD`와 값이 맞물리므로,
  monitoring도 같은 방식으로 옮길지 검토 필요(이번 변경 범위는 `infra/`만).
- [ ] **하드코딩 dev 자격증명의 운영 사용 여부.** `CLAUDE.md`는 infra compose를 "로컬 개발·운영 공용"으로
  설명한다. 운영에서도 이 값(현재 `.env` 기본값)을 그대로 쓰는지, 아니면 Vault/다른 값으로 대체하는지
  확인 필요 — 운영 사용이면 보안 위험. (출처: `docs/INFRA.md`)

## 공통 (여러 전략에 걸침)

- [ ] **`ready`/`not-ready` 마킹이 애플리케이션 내부에서 정확히 무엇을 바꾸는지.** blue/green,
  validated-recreate 둘 다 호출하지만 구현은 이 저장소에 없다. `crypto-project-backend`의
  `/internal/deployment` 컨트롤러(예: Eureka self-preservation 해제, load balancer weight,
  `/actuator/health/readiness` 상태 전환 등)를 확인해야 실제 트래픽 전환 시점을 정확히 알 수 있다.
  (출처: `DEPLOYMENT_FLOW.md`)
- [ ] **크로스 서비스 포트 충돌.** blue/green 4개, validated-recreate 5개 서비스 모두 각 스크립트가
  자신의 포트 범위/candidate 포트만 검증하고 다른 서비스와의 충돌은 검증하지 않는다. 현재는 사람이
  수동으로 겹치지 않게 맞춘 상태로 보인다. 새 서비스 추가·기존 포트 변경 시 전체 스크립트를 훑어
  수동 대조가 필요하다. (출처: `DEPLOYMENT_FLOW.md`)
- [ ] **동시 배포에 대한 락 부재의 실제 운영 영향.** `cd.yml`에 `concurrency:` 키가 없음을 확인함 —
  GitHub Actions 워크플로우 레벨에서 동시 실행을 막고 있지 않다. self-hosted runner 자체가
  물리적으로 job을 하나씩만 처리하는지(러너 개수, `runs-on` 라벨 매칭 방식)는 확인 못함. 세 전략
  모두 동일하게 영향받는다. (출처: `DEPLOYMENT_FLOW.md`)

## Blue/Green

- [ ] **`stop_legacy_container`의 도입 배경.** blue/green 이전에 slot 없이 `$SERVICE_NAME` 이름으로
  compose가 직접 관리하던 컨테이너가 있었던 것으로 추정되나, git 히스토리/커밋 메시지로 교차
  확인하지 않았다. 제거해도 되는 하위호환 코드인지 사용자 확인 후 판단한다.
  (출처: `DEPLOYMENT_FLOW_BLUEGREEN.md`)

## Validated Recreate

- [ ] **`DEPLOY_TOKEN` 필수 여부가 서비스마다 다른 이유.** eureka/oauth2-authorization-server/
  oauth2-client는 토큰이 없으면 배포 자체를 막고, config/api-gateway(및 blue/green 4개 서비스)는
  토큰이 없어도 ready 마킹만 스킵하고 계속 진행한다. 의도된 정책 차이인지 비일관성인지 코드만으로
  판단 불가 — 운영 `.env`에 토큰이 항상 설정되어 있는지도 확인 못함(`.env`는 git 미추적).
  (출처: `DEPLOYMENT_FLOW_VALIDATED_RECREATE.md`)
- [ ] **api-gateway 원격 디버그(JDWP) 포트를 `127.0.0.1`에만 바인딩하는 것으로 충분한 격리인지.**
  러너 호스트의 네트워크/방화벽 구성에 달려 있어 이 저장소만으로는 판단 불가.
  (출처: `DEPLOYMENT_FLOW_VALIDATED_RECREATE.md`)

## Safe Recreate

- [ ] **outbox-poller에 HTTP 헬스체크가 없는 이유.** 백그라운드 컨슈머라 actuator 엔드포인트가
  없거나 라우팅되지 않아서인지, 단순히 다듬어지지 않은 것인지 코드만으로 알 수 없다. 로그 문자열
  매칭(`grep -E "..."`) 기반 판단은 새 예외 메시지가 추가되면 감지하지 못할 수 있다는 한계도 있다.
  (출처: `DEPLOYMENT_FLOW_SAFE_RECREATE.md`)
- [ ] **outbox-poller rollback의 재검증 부재.** rollback 후 상태/로그를 출력만 하고 성공 여부를
  다시 판정하지 않는다 — rollback 자체가 실패해도 스크립트는 그대로 `exit 1`로 끝난다. 의도적으로
  "이후는 사람이 본다"는 설계인지 확인이 필요하다. (출처: `DEPLOYMENT_FLOW_SAFE_RECREATE.md`)
