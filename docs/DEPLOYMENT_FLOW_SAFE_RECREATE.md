# 배포 흐름 — Safe Recreate (`deploy-<service>-safe.sh`)

전체 개요와 다른 전략은 [DEPLOYMENT_FLOW.md](./DEPLOYMENT_FLOW.md) 참고.

대상: `crypto-outbox-poller`, `crypto-market-detection`. 둘 다 외부 인바운드 트래픽을 받지 않는
백그라운드 워크로드(Kafka 컨슈머/스트림, 외부 WS 수집)라 무중단이 불필요하다. blue/green·
validated-recreate와 마찬가지로 **`docker run`으로 컨테이너를 직접 띄우며**(compose 미사용), HTTP
헬스체크는 전혀 없다 — 컨테이너 상태와 로그 문자열만으로 성공/실패를 판단한다. 아래 단계 설명은
outbox-poller 기준이며, market-detection도 동일한 스크립트 구조다(서비스명·`IMAGE_REPOSITORY`·
`.current-image` 파일명만 다름: `.deploy/market-detection.current-image`).

> **market-detection 참고**: `config.name`에 `monitoring`이 있어 actuator/probes 자체는 뜨지만
> (`server.port 8500`), safe-recreate 스크립트는 HTTP 헬스를 폴링하지 않고 outbox-poller와 동일하게
> 컨테이너 `State.Status` + 시작 로그 패턴으로만 판단한다. 8500은 호스트에 게시하지 않는다(인바운드 없음).

**왜 HTTP 헬스체크가 없나 (backend 확인 완료)**: outbox-poller의 주 워크로드는 Kafka 스트림 컨슈머다.
웹 서버(port 9200, DLQ 제어 REST `/dlq-poller/start,stop`)는 있지만 **actuator 헬스 프로브가 설정돼
있지 않다**(remote config `git-config-repo/dynamic/outbox-poller.yml`에 `server.port`만, `management`/
liveness 설정 없음. `common-actuator`도 미포함). 그래서 다른 서비스처럼 `/actuator/health/liveness`로
폴링할 대상이 없어, 안전 재기동은 컨테이너 `State.Status` + 시작 로그 패턴으로 판단한다.

## 단계별 흐름

1. **사전 확인**: `.deploy/outbox-poller.current-image` 파일이 없으면 즉시 `exit 1`(최초 배포 시
   사람이 현재 안정 이미지 다이제스트를 수동으로 적어둬야 함 — config/eureka/api-gateway와 동일한
   부트스트랩 요구).
2. **새 이미지 pull**: `docker pull "$NEW_IMAGE"`. 새 이미지는 `${IMAGE_REPOSITORY}:${NEW_TAG}`로
   조합한다(`NEW_TAG`는 스크립트 인자 `$1`, 기본 `latest`). rollback은 태그가 아니라
   `.current-image`에 저장된 전체 이미지 참조(다이제스트 고정)를 그대로 쓴다.
3. **재기동**: 기존 컨테이너를 `docker rm -f`로 내린 뒤(`remove_container`) `docker run -d`로 새로
   띄운다(`run_container`: `--name`=서비스명, `--network crypto-project-network`, `--memory`,
   `-e JAVA_TOOL_OPTIONS`). 기존 컨테이너를 먼저 내리고 새로 띄우므로, blue/green과 달리 **이 구간은
   짧게라도 poller가 완전히 내려가는 다운타임이 있다.**
4. **고정 15초 대기 후 단발성 상태 확인** (폴링 아님): 컨테이너 존재 여부 → `docker inspect`로
   `State.Status`가 `running`인지 → 최근 200줄 로그에서 `Application run failed` /
   `Exception encountered during context initialization` / `OutOfMemoryError` 패턴이 있는지 확인.
   셋 중 하나라도 걸리면 **rollback**.
5. **rollback**: `.current-image`에 저장된 이전 이미지로 강제 재기동 후 상태/로그만 출력(재검증
   루프 없이 여기서 끝 — rollback 자체의 성공 여부를 다시 확인하지 않는다).
6. **성공 시 다이제스트 갱신**: 현재 실행 중인 컨테이너의 이미지에서 다이제스트를 뽑아
   `.current-image`에 기록. 실패하면 rollback 후 `exit 1`.

## 실패 시 동작 요약

| 실패 지점 | poller 상태 | `.current-image` | CD 종료 코드 |
| --- | --- | --- | --- |
| 컨테이너 미존재 / not running / 의심 로그 패턴 감지 | rollback 시도(재검증 없음) | 안 바뀜 | 실패(1) |
| 새 다이제스트 조회 실패 | rollback 시도 | 안 바뀜 | 실패(1) |
| 정상 | 새 이미지로 실행 중 | 새 다이제스트로 갱신 | 성공(0) |
