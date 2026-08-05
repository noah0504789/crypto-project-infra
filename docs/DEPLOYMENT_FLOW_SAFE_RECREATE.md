# 배포 흐름 — Safe Recreate (`deploy-<service>-safe.sh`)

전체 개요와 다른 전략은 [DEPLOYMENT_FLOW.md](./DEPLOYMENT_FLOW.md) 참고.

대상: `crypto-outbox-poller`, `crypto-market-detection`. 둘 다 외부 인바운드 트래픽을 받지 않는
백그라운드 워크로드(Kafka 컨슈머/스트림, 외부 WS 수집)라 무중단이 불필요하다. blue/green·
validated-recreate와 마찬가지로 **`docker run`으로 컨테이너를 직접 띄우며**(compose 미사용), Docker
내부 네트워크에서 Actuator liveness와 오류 로그를 확인해 성공/실패를 판단한다. 아래 단계 설명은
outbox-poller 기준이며, market-detection도 동일한 스크립트 구조다(서비스명·`IMAGE_REPOSITORY`·
`.current-image` 파일명만 다름: `.deploy/market-detection.current-image`).

> **내부 health 확인**: market-detection은 8500, outbox-poller는 9200에서
> `/actuator/health/liveness`를 제공한다. 포트는 호스트에 게시하지 않고, 배포 스크립트가
> `crypto-project-network`에 임시 curl 컨테이너를 실행해 확인한다.

> **배포 전제**: 새 이미지와 `.current-image`가 가리키는 rollback 이미지 모두 Actuator liveness를
> 제공해야 한다. 백엔드 Actuator 변경을 먼저 배포해 안정 이미지 digest를 갱신한 뒤 이 스크립트를
> 적용한다. 순서를 뒤집으면 새 이미지 실패 시 이전 이미지가 실행되더라도 rollback health 검증은 실패한다.

## 단계별 흐름

1. **사전 확인**: `.deploy/outbox-poller.current-image` 파일이 없거나 비어 있으면 즉시 `exit 1`(최초 배포 시
   사람이 현재 안정 이미지 다이제스트를 수동으로 적어둬야 함 — config/eureka/api-gateway와 동일한
   부트스트랩 요구).
2. **이미지 pull**: 새 애플리케이션 이미지와 고정 버전의 health-check curl 이미지를 기존 컨테이너 제거
   전에 pull한다. 새 이미지는 `${IMAGE_REPOSITORY}:${NEW_TAG}`로 조합한다(`NEW_TAG`는 스크립트 인자
   `$1`, 기본 `latest`). rollback은 태그가 아니라
   `.current-image`에 저장된 전체 이미지 참조(다이제스트 고정)를 그대로 쓴다.
3. **재기동**: 기존 컨테이너를 `docker rm -f`로 내린 뒤(`remove_container`) `docker run -d`로 새로
   띄운다(`run_container`: `--name`=서비스명, `--network crypto-project-network`, `--memory`,
   `-e JAVA_TOOL_OPTIONS`). 기존 컨테이너를 먼저 내리고 새로 띄우므로, blue/green과 달리 **이 구간은
   짧게라도 poller가 완전히 내려가는 다운타임이 있다.**
4. **liveness 폴링**: 동일 Docker 네트워크의 임시 curl 컨테이너가 최대 90초 동안
   `/actuator/health/liveness`의 HTTP 성공 응답을 기다린다. 성공 후에도 최근 200줄 로그에서
   `Application run failed` / `Exception encountered during context initialization` / `OutOfMemoryError`
   패턴을 보조 검사한다. health 또는 로그 검사가 실패하면 **rollback**.
5. **rollback 검증**: `.current-image`에 저장된 이전 이미지로 강제 재기동하고 동일한 liveness·로그 검사를
   다시 수행한다. rollback까지 실패하면 수동 복구가 필요하다는 CRITICAL 로그를 남기고 실패 종료한다.
6. **성공 시 다이제스트 갱신**: 현재 실행 중인 컨테이너의 이미지에서 다이제스트를 뽑아
   `.current-image`에 기록. 실패하면 rollback 후 `exit 1`.

## 실패 시 동작 요약

| 실패 지점 | poller 상태 | `.current-image` | CD 종료 코드 |
| --- | --- | --- | --- |
| 새 이미지 liveness 실패 / 의심 로그 패턴 감지 | rollback 후 liveness 재검증 | 안 바뀜 | 실패(1) |
| 새 다이제스트 조회 실패 | rollback 후 liveness 재검증 | 안 바뀜 | 실패(1) |
| rollback liveness·로그 검증 실패 | 수동 복구 필요 상태를 명시 | 안 바뀜 | 실패(1) |
| 정상 | 새 이미지로 실행 중 | 새 다이제스트로 갱신 | 성공(0) |
