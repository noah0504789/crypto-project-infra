# monitoring/ — 관측 스택 (메트릭 전용)

Prometheus / Grafana + DB별 exporter(mysqld·redis·mongodb·kafka)의 Docker Compose.
`infra/`와 같은 `crypto-project-network`를 공유한다. 로그(Loki/Promtail)·트레이스(Tempo/OTel)는 제거됨.

## 먼저 읽을 것
- 이 스택 조작·수정 시: `.claude/rules/infra-safety.md` (상태 저장·볼륨 삭제 위험이 infra와 동일하게 적용)
- 구성·포트·scrape 대상·정합성 이슈: `docs/MONITORING.md`

## 핵심 주의
- `grafana-data` 볼륨은 `external: true` → 삭제 시 대시보드·설정 영구 손실. 볼륨 삭제 명령은 승인 없이 금지.
- exporter 자격증명: `my-primary.cnf`·`my-replica.cnf`에 mysql-exporter 비밀번호가 아직 평문으로 있고,
  `infra/.env`의 `MYSQL_EXPORTER_PASSWORD` / `monitoring/.env`의 `MONGO_EXPORTER_PASSWORD`와 값이
  일치해야 한다(→ 루트 `TODO.md`).
- 알려진 정합성 이슈(prometheus scrape 대상 ↔ blue/green 컨테이너명 불일치 등)는
  `docs/MONITORING.md` + 루트 `TODO.md` 참고. 단정 전 실제 파일 확인.
