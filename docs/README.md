# 문서 인덱스 (crypto-project-infra)

이 저장소의 문서 지도다. 저장소 전체 소개는 루트 [`../README.md`](../README.md), 확인 필요·예정 작업은 [`../TODO.md`](../TODO.md)에서 단일 관리한다.

문서는 세 층으로 나뉜다.
- **`docs/`** — 사람이 읽는 스택별 구성·배포 흐름(이 폴더).
- **`<stack>/CLAUDE.md`** — 해당 스택 디렉토리에서 작업할 때 자동 로드되는 짧은 작업 규칙.
- **`.claude/rules/`** — 작업 유형별로 읽는 짧은 안전 규칙.

## 1. 스택 구성 문서 (docs/)

| 문서 | 내용 |
|---|---|
| [INFRA.md](INFRA.md) | `infra/` 스택 — MySQL·Redis·MongoDB·Kafka·Vault 구성·포트·부트스트랩·복제/클러스터 |
| [MONITORING.md](MONITORING.md) | `monitoring/` 스택 — Prometheus·Grafana·exporter, docker-socket-proxy |
| [SERVICE.md](SERVICE.md) | `service/` 스택 — 배포 서비스 목록·포트·전략·상태 파일(`.deploy/`)·자격증명 |

## 2. 배포 흐름 문서 (docs/)

| 문서 | 내용 |
|---|---|
| [DEPLOYMENT_FLOW.md](DEPLOYMENT_FLOW.md) | 배포 전략 개요(전략 비교·공통 트리거·배포 준비 상태 제어) |
| [DEPLOYMENT_FLOW_BLUEGREEN.md](DEPLOYMENT_FLOW_BLUEGREEN.md) | Blue/Green(user·market·chat·websocket-gateway·notification) |
| [DEPLOYMENT_FLOW_VALIDATED_RECREATE.md](DEPLOYMENT_FLOW_VALIDATED_RECREATE.md) | Validated Recreate(config·eureka·api-gateway·oauth2-*) |
| [DEPLOYMENT_FLOW_SAFE_RECREATE.md](DEPLOYMENT_FLOW_SAFE_RECREATE.md) | Safe Recreate(outbox-poller·market-detection) |

## 3. 스택별 작업 지침 (CLAUDE.md)

| 파일 | 적용 범위 |
|---|---|
| [../CLAUDE.md](../CLAUDE.md) | 저장소 전체 개요·작업 규칙 진입점 |
| [../infra/CLAUDE.md](../infra/CLAUDE.md) | `infra/` 작업 시 |
| [../monitoring/CLAUDE.md](../monitoring/CLAUDE.md) | `monitoring/` 작업 시 |
| [../service/CLAUDE.md](../service/CLAUDE.md) | `service/`(배포 스크립트·compose) 작업 시 |

## 4. 안전 규칙 (.claude/rules/)

자동 로드되지 않는다. 아래 작업 전에 해당 파일을 먼저 읽는다(진입점: 루트 `CLAUDE.md`의 "규칙 참조" 표).

| 규칙 | 언제 |
|---|---|
| [../.claude/rules/git-safety.md](../.claude/rules/git-safety.md) | Git 조작·민감 정보 취급 |
| [../.claude/rules/deploy-safety.md](../.claude/rules/deploy-safety.md) | 배포 스크립트·compose·`.deploy/` 수정 |
| [../.claude/rules/infra-safety.md](../.claude/rules/infra-safety.md) | `infra/`·`monitoring/` 스택 조작(상태 저장·볼륨 삭제 위험) |
