#!/usr/bin/env bash
#
# DockerHub 의 <sha7> 태그를 보호 목록 기준으로 정리한다.
#
#   보존: latest + .deploy/*.current-image 가 가리키는 현재 배포본 + 최근 N개
#   제외: .current-image 가 없는 서비스는 통째로 건너뛴다(무엇이 떠 있는지 모르므로)
#
# "최신 N개" 만으로 자르면 안 된다. 빌드는 머지마다, 배포는 가끔이라 현재 배포본이
# 20번째 이후에 있는 경우가 흔하다(실측: api-gateway 23번째, eureka 26번째).
#
# 사용 (service/.env 에 DOCKERHUB_TOKEN 을 넣어두면 인자 없이 실행된다):
#   ./scripts/cleanup-dockerhub-tags.sh          # dry-run
#   ./scripts/cleanup-dockerhub-tags.sh --apply  # 실제 삭제
#
# PAT 은 Read, Write & Delete 스코프가 필요하다.
# .env 에 두지 않고 일회성으로 줄 때는 셸 히스토리에 남지 않게 입력받는다:
#   read -s -p 'PAT: ' DOCKERHUB_TOKEN; export DOCKERHUB_TOKEN
#
# macOS 기본 bash 는 3.2 라 bash 4+ 문법(mapfile 등)을 쓰지 않는다.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 배포 스크립트와 같은 방식으로 service/.env 를 읽는다(git 미추적).
# 이미 환경변수로 준 값이 있으면 그쪽을 우선한다.
if [[ -f "${SERVICE_DIR}/.env" ]]; then
  _prev_user="${DOCKERHUB_USERNAME:-}"
  _prev_token="${DOCKERHUB_TOKEN:-}"
  set -a
  # shellcheck disable=SC1091
  . "${SERVICE_DIR}/.env"
  set +a
  [[ -n "$_prev_user" ]] && DOCKERHUB_USERNAME="$_prev_user"
  [[ -n "$_prev_token" ]] && DOCKERHUB_TOKEN="$_prev_token"
fi

: "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required (service/.env 또는 환경변수)}"
: "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required (service/.env 에 Read/Write/Delete PAT 추가)}"

KEEP_RECENT="${KEEP_RECENT:-10}"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

DEPLOY_DIR="${SERVICE_DIR}/.deploy"

if [[ ! -d "$DEPLOY_DIR" ]]; then
  echo "ERROR: $DEPLOY_DIR 가 없다. 배포 호스트에서 실행해야 한다." >&2
  exit 1
fi

TOKEN="$(curl -sf -H 'Content-Type: application/json' -X POST \
  -d "{\"username\":\"${DOCKERHUB_USERNAME}\",\"password\":\"${DOCKERHUB_TOKEN}\"}" \
  https://hub.docker.com/v2/users/login/ | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"

[[ -n "$TOKEN" ]] || { echo "ERROR: DockerHub 로그인 실패" >&2; exit 1; }

$APPLY || echo "=== DRY RUN (실제 삭제하려면 --apply) ==="

total_del=0
for f in "$DEPLOY_DIR"/*.current-image; do
  [[ -e "$f" ]] || continue

  line="$(cat "$f")"
  image="${line%%@*}"
  name="${image##*/}"
  protected_digest="${line##*@}"

  tags_json="$(curl -sf "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${name}/tags/?page_size=100")" || {
    echo "$name: 조회 실패, 건너뜀"; continue
  }

  # 보존 규칙을 한곳에서 계산한다: latest / 현재 배포본 / 최근 N개
  # mapfile 은 bash 4+ 전용이라 macOS 기본 bash 3.2 에서 깨진다. while read 로 대체.
  to_delete=()
  while IFS= read -r tag; do
    [[ -n "$tag" ]] && to_delete+=("$tag")
  done < <(echo "$tags_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
protected, keep_recent = '$protected_digest', $KEEP_RECENT
for i, r in enumerate(d.get('results', [])):
    if r['name'] == 'latest' or r.get('digest') == protected or i < keep_recent:
        continue
    print(r['name'])
")

  echo "${name}: 삭제 대상 ${#to_delete[@]:-0}개 (보호 다이제스트 ${protected_digest:7:12}…)"
  total_del=$((total_del + ${#to_delete[@]}))

  $APPLY || continue

  [[ ${#to_delete[@]} -eq 0 ]] && continue

  for tag in "${to_delete[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: JWT ${TOKEN}" \
      "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${name}/tags/${tag}/")"
    case "$code" in
      204) ;;
      *) echo "  WARN ${tag}: HTTP ${code}" ;;
    esac
  done
  echo "  삭제 완료"
done

echo
echo "합계 ${total_del}개"
$APPLY || echo "(dry-run — 아무것도 지우지 않았다)"
