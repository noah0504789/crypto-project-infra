# TODO

`docs/*`의 "확인 필요"(코드만으로 판단 불가한 항목)와 아직 구현되지 않은 예정 작업을 여기 한곳에
모아 관리한다. 항목을 처리했으면 결론을 관련 문서에 반영한 뒤 여기서 지운다(완료 기록은 git 히스토리·
docs에 남는다). 새 "확인 필요"·예정 작업은 개별 문서가 아니라 여기에 추가한다.

## 서비스 스택 (`service/`)

- [ ] **compose 정의 ↔ 스크립트 파라미터 드리프트.** blue/green·validated-recreate 서비스
  (config/eureka/api-gateway/oauth2-*/user/chat/websocket/market/notification)는 스크립트가 `docker run`으로
  배포하는데, `service/docker-compose.yml`에도 같은 서비스가 정의되어 포트·`mem_limit`·`JAVA_TOOL_OPTIONS`가
  중복된다. CD 배포 경로는 이 compose 정의를 쓰지 않으므로(safe-recreate=outbox-poller·market-detection만
  compose 사용) 한쪽만 바꾸면 값이 어긋난다. compose 정의를 로컬/수동 용도로 유지할지, single-source로
  정리할지 결정 필요. (출처: `docs/SERVICE.md`)

## 인프라 스택 (`infra/`)

- [ ] **Redis 클러스터 재시작 안정성(복구).** 부트스트랩(`redis-cluster-init`)은 최초 구성만 하고, 하드
  재부팅으로 컨테이너 IP가 바뀌면 `nodes.conf` 주소가 stale → 클러스터가 깨질 수 있다(스크립트는
  `known_nodes>1`이라 skip, heal 안 함). 근본 해결: compose 네트워크에 subnet + 노드별 고정
  IP(`ipv4_address`) 부여(또는 hostname endpoint 방식)로 IP를 고정 → 재부팅해도 `nodes.conf` 유효 →
  자가복구. (출처: `docs/INFRA.md`)
- [ ] **MySQL replica 깨졌을 때 heal 경로.** 재시작 시 보통 자동 재개되지만(hostname+GTID+영속 설정),
  하드 크래시로 relay log 손상/GTID 틀어짐 시 `RESET REPLICA` 후 재구성이 필요하다. bootstrap이 이 heal까지
  할지(위험 — 잘못하면 데이터 영향) 아니면 수동 런북으로 둘지 결정. (출처: `docs/INFRA.md`)
- [ ] **Vault init/unseal 절차.** `vault.hcl`에 자동 init/unseal이 없다. 운영에서 최초 기동 후
  `operator init`/`unseal`을 어떻게(누가/어디에 키 보관) 수행하는지 확인 필요. (출처: `docs/INFRA.md`)
- [ ] **기존 볼륨 비밀번호 회전.** infra 평문 제거는 **fresh 볼륨에서만** 반영된다. 이미 초기화된 mysql/mongo
  볼륨은 여전히 옛 비밀번호를 갖고 있어, 실제로 바꾸려면 수동 회전 또는 볼륨 재초기화가 필요하다
  (데이터 영향 — `.claude/rules/infra-safety.md`).
- [ ] **git 히스토리의 평문 잔존.** 과거 커밋에는 평문 비밀번호가 그대로 남아 있다. 실제 노출 위험으로
  판단되면 히스토리 정리(예: filter-repo)나 비밀번호 회전을 검토해야 한다.

## 공통 (배포 전략 공통)

- [ ] **크로스 서비스 포트 충돌.** blue/green 5개, validated-recreate 5개 서비스 모두 각 스크립트가 자신의
  포트 범위/candidate 포트만 검증하고 다른 서비스와의 충돌은 검증하지 않는다. 현재는 사람이 수동으로
  겹치지 않게 맞춘 상태다. 새 서비스 추가·기존 포트 변경 시 전체 스크립트를 훑어 수동 대조가 필요하다.
  (출처: `docs/DEPLOYMENT_FLOW.md`)
- [ ] **동시 배포에 대한 락 부재.** `cd.yml`에 `concurrency:` 키가 없어 워크플로우 레벨에서 동시 실행을
  막지 않는다. self-hosted runner가 물리적으로 job을 하나씩만 처리하는지(러너 개수, `runs-on` 라벨 매칭)는
  확인 못함. 세 전략 모두 동일하게 영향받는다. (출처: `docs/DEPLOYMENT_FLOW.md`)

## 보안 · 네트워크 노출 (X-User-Id 신뢰 모델)

배경: 하위 서비스는 게이트웨이가 넣는 `X-User-Id`를 검증 없이 신뢰한다(backend `TODO 1.8`). 게이트웨이를
거치지 않고 서비스에 직접 요청하며 `X-User-Id`를 위조하면 타인 데이터 접근이 가능하므로, 서비스 앱 포트가
외부에 노출되면 안 된다. (게이트웨이 경유 스푸핑 차단(Layer 2)은 backend 게이트웨이에서 처리 — 클라이언트가
보낸 `X-User-Id`/`X-From`을 입구에서 제거.)

- [x] **(Layer 1) blue/green 서비스 앱 포트 host-local 바인딩.** `bluegreen-core.sh`의 `-p`를
  `127.0.0.1:${host_port}:${CONTAINER_PORT}`로 변경(user/market/chat/websocket-gateway). 인터서비스는
  Docker 네트워크 + Eureka(컨테이너 `hostname:CONTAINER_PORT` 등록, host_port는 Eureka가 모름)로 통신하므로
  라우팅 영향 없고, 배포 스크립트 헬스체크(`curl localhost:${host_port}`)도 그대로 동작. 외부 직접 접근만 차단.
- [x] **(Layer 1) validated-recreate — eureka·oauth2-as·oauth2-client host-local 바인딩.**
  `deploy-eureka-server-*`·`deploy-oauth2-authorization-server-*`·`deploy-oauth2-client-*`의 앱 포트를
  `127.0.0.1` 바인딩으로 전환. 인터서비스는 Docker 네트워크/Eureka로, 헬스체크·ready는 `localhost`로 접근하므로
  영향 없음(eureka 대시보드 등 호스트 외부 직접 접근만 차단). **api-gateway(8000)는 외부 진입점이라
  의도적으로 `0.0.0.0` 유지**(스크립트에 주석). outbox-poller(safe-recreate)는 게시 포트 없음.
- [ ] **(Layer 1 잔여) config(8888) host-local 바인딩.** config-bus 워크플로우가 self-hosted runner(호스트)에서
  `${CONFIG_SERVER_URL}/actuator/busrefresh`를 curl한다. `CONFIG_SERVER_URL`(GitHub 변수)이 `http://localhost:8888`
  (또는 `127.0.0.1`)이면 `127.0.0.1` 바인딩으로 전환해도 안전하나, 호스트 IP/DNS면 busrefresh가 깨진다. 값 확인 후 전환
  (서비스는 Docker 네트워크 `configserver:http://crypto-spring-cloud-config:8888`로 접근하므로 호스트 포트 소비자는 이 워크플로우뿐).
- [ ] **(Layer 0) 호스트/네트워크 방화벽으로 서비스 포트 차단.** 현재 클라우드 미사용이라 Security Group이
  없다. 운영 호스트를 외부에 노출하거나 클라우드로 이전할 때, 게이트웨이 포트(8000)만 외부 개방하고 나머지
  서비스 포트는 방화벽(SG/`ufw`/`iptables`)으로 차단한다. Layer 1(포트 비공개)과 이중 방어.

## 전략별 확인 필요

### Validated Recreate
- [ ] **api-gateway 원격 디버그(JDWP) 포트를 `127.0.0.1`에만 바인딩하는 것으로 충분한 격리인지.** 러너
  호스트의 네트워크/방화벽 구성에 달려 있어 이 저장소만으로는 판단 불가.
  (출처: `docs/DEPLOYMENT_FLOW_VALIDATED_RECREATE.md`)

### Safe Recreate
- [ ] **outbox-poller rollback의 재검증 부재.** rollback 후 상태/로그를 출력만 하고 성공 여부를 다시
  판정하지 않는다 — rollback 자체가 실패해도 스크립트는 그대로 `exit 1`로 끝난다. (배경: outbox-poller에
  actuator 헬스 프로브가 없어 forward/rollback 모두 로그 기반이라는 건 확인됨 → `docs/DEPLOYMENT_FLOW_SAFE_RECREATE.md`.
  남은 건 rollback 후 재검증 루프를 넣을지 vs 수동 확인으로 둘지의 **스크립트 설계 결정**.)
