#!/usr/bin/env bash
# GonsAutoPilot - State Store 관리 유틸리티
# pipeline.json, deployments.json, rollback-registry.json 읽기/쓰기

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../state"

PIPELINE_FILE="${STATE_DIR}/pipeline.json"
DEPLOYMENTS_FILE="${STATE_DIR}/deployments.json"
ROLLBACK_FILE="${STATE_DIR}/rollback-registry.json"

# jq 존재 확인
_require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq가 설치되어 있지 않습니다. sudo apt install jq" >&2
    exit 1
  fi
}

# ──────────────────────────────────────────────
# Pipeline 상태 관리
# ──────────────────────────────────────────────

# 새 파이프라인 생성
pipeline_create() {
  _require_jq
  local pipeline_id="$1"
  local trigger="${2:-manual}"
  local timestamp
  timestamp="$(date -Iseconds)"

  local new_pipeline
  new_pipeline=$(jq -n \
    --arg id "$pipeline_id" \
    --arg trigger "$trigger" \
    --arg started "$timestamp" \
    '{
      pipeline_id: $id,
      status: "running",
      trigger: $trigger,
      started_at: $started,
      finished_at: null,
      stages: {
        analyze: { status: "pending", started_at: null, finished_at: null, result: null },
        test:    { status: "pending", started_at: null, finished_at: null, result: null },
        build:   { status: "pending", started_at: null, finished_at: null, result: null },
        deploy:  { status: "pending", started_at: null, finished_at: null, result: null },
        verify:  { status: "pending", started_at: null, finished_at: null, result: null }
      },
      changes: { frontend: [], backend: [], config: [], database: [] },
      decisions: [],
      errors: []
    }')

  # pipeline.json에 추가하고 current 설정
  jq --argjson pipe "$new_pipeline" \
    '.pipelines += [$pipe] | .current = $pipe.pipeline_id' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"

  echo "$pipeline_id"
}

# 파이프라인 ID 생성 (YYYYMMDD-HHMMSS-gitsha)
pipeline_generate_id() {
  local date_part
  date_part="$(date +%Y%m%d-%H%M%S)"
  local git_sha
  git_sha="$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit')"
  echo "${date_part}-${git_sha}"
}

# 스테이지 상태 업데이트
pipeline_update_stage() {
  _require_jq
  local pipeline_id="$1"
  local stage="$2"
  local status="$3"
  local result="${4:-null}"
  local timestamp
  timestamp="$(date -Iseconds)"

  local time_field="started_at"
  if [[ "$status" == "passed" || "$status" == "failed" || "$status" == "skipped" ]]; then
    time_field="finished_at"
  fi

  if [[ "$result" == "null" ]]; then
    jq --arg pid "$pipeline_id" --arg stage "$stage" --arg status "$status" \
       --arg tf "$time_field" --arg ts "$timestamp" \
      '(.pipelines[] | select(.pipeline_id == $pid) | .stages[$stage]) |=
        (.status = $status | .[$tf] = $ts)' \
      "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
  else
    jq --arg pid "$pipeline_id" --arg stage "$stage" --arg status "$status" \
       --arg tf "$time_field" --arg ts "$timestamp" --argjson result "$result" \
      '(.pipelines[] | select(.pipeline_id == $pid) | .stages[$stage]) |=
        (.status = $status | .[$tf] = $ts | .result = $result)' \
      "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
  fi
}

# 파이프라인 완료 처리
pipeline_finish() {
  _require_jq
  local pipeline_id="$1"
  local status="$2"  # success | failed
  local timestamp
  timestamp="$(date -Iseconds)"

  jq --arg pid "$pipeline_id" --arg status "$status" --arg ts "$timestamp" \
    '(.pipelines[] | select(.pipeline_id == $pid)) |=
      (.status = $status | .finished_at = $ts)' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"

  # 통계 업데이트
  if [[ "$status" == "success" ]]; then
    jq '.stats.total_runs += 1 | .stats.success_count += 1 | .stats.consecutive_failures = 0' \
      "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
  else
    jq '.stats.total_runs += 1 | .stats.failure_count += 1 | .stats.consecutive_failures += 1' \
      "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
  fi
}

# AI 의사결정 기록
pipeline_add_decision() {
  _require_jq
  local pipeline_id="$1"
  local agent="$2"
  local action="$3"
  local reason="$4"
  local timestamp
  timestamp="$(date -Iseconds)"

  jq --arg pid "$pipeline_id" --arg agent "$agent" --arg action "$action" \
     --arg reason "$reason" --arg ts "$timestamp" \
    '(.pipelines[] | select(.pipeline_id == $pid) | .decisions) +=
      [{ agent: $agent, action: $action, reason: $reason, timestamp: $ts }]' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
}

# 변경 파일 목록 설정
pipeline_set_changes() {
  _require_jq
  local pipeline_id="$1"
  local changes_json="$2"  # JSON 객체: {"frontend":[], "backend":[], ...}

  jq --arg pid "$pipeline_id" --argjson changes "$changes_json" \
    '(.pipelines[] | select(.pipeline_id == $pid) | .changes) = $changes' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
}

# 현재 파이프라인 조회
pipeline_get_current() {
  _require_jq
  local current_id
  current_id=$(jq -r '.current // empty' "$PIPELINE_FILE")
  if [[ -z "$current_id" ]]; then
    echo "{}"
    return 1
  fi
  jq --arg pid "$current_id" '.pipelines[] | select(.pipeline_id == $pid)' "$PIPELINE_FILE"
}

# 파이프라인 잠금 여부 확인
pipeline_is_locked() {
  _require_jq
  jq -r '.lock.locked' "$PIPELINE_FILE"
}

# 파이프라인 잠금
pipeline_lock() {
  _require_jq
  local reason="$1"
  local timestamp
  timestamp="$(date -Iseconds)"

  jq --arg reason "$reason" --arg ts "$timestamp" \
    '.lock = { locked: true, reason: $reason, locked_at: $ts }' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
}

# 파이프라인 잠금 해제
pipeline_unlock() {
  _require_jq
  jq '.lock = { locked: false, reason: null, locked_at: null }' \
    "$PIPELINE_FILE" > "${PIPELINE_FILE}.tmp" && mv "${PIPELINE_FILE}.tmp" "$PIPELINE_FILE"
}

# 연속 실패 횟수 조회
pipeline_get_consecutive_failures() {
  _require_jq
  jq -r '.stats.consecutive_failures' "$PIPELINE_FILE"
}

# ──────────────────────────────────────────────
# 배포 이력 관리
# ──────────────────────────────────────────────

deployment_record() {
  _require_jq
  local pipeline_id="$1"
  local services_json="$2"  # {"frontend":"tag1","backend":"tag2"}
  local status="$3"         # success | failed | rolled_back
  local timestamp
  timestamp="$(date -Iseconds)"

  local entry
  entry=$(jq -n \
    --arg pid "$pipeline_id" \
    --argjson services "$services_json" \
    --arg status "$status" \
    --arg ts "$timestamp" \
    '{ pipeline_id: $pid, services: $services, status: $status, deployed_at: $ts }')

  jq --argjson entry "$entry" --arg status "$status" \
    '.deployments += [$entry] |
     if $status == "success" then .last_successful = $entry else . end' \
    "$DEPLOYMENTS_FILE" > "${DEPLOYMENTS_FILE}.tmp" && mv "${DEPLOYMENTS_FILE}.tmp" "$DEPLOYMENTS_FILE"
}

# ──────────────────────────────────────────────
# 롤백 레지스트리 관리
# ──────────────────────────────────────────────

rollback_register() {
  _require_jq
  local service="$1"
  local tag="$2"
  local status="${3:-stable}"
  local timestamp
  timestamp="$(date -Iseconds)"

  local max_history
  max_history=$(jq -r '.max_history' "$ROLLBACK_FILE")

  jq --arg svc "$service" --arg tag "$tag" --arg status "$status" \
     --arg ts "$timestamp" --argjson max "$max_history" \
    'if .services[$svc] == null then
       .services[$svc] = { current: $tag, previous: null, history: [] }
     else
       .services[$svc].previous = .services[$svc].current |
       .services[$svc].current = $tag
     end |
     .services[$svc].history = ([{ tag: $tag, deployed_at: $ts, status: $status }]
       + .services[$svc].history) | .services[$svc].history = .services[$svc].history[:$max]' \
    "$ROLLBACK_FILE" > "${ROLLBACK_FILE}.tmp" && mv "${ROLLBACK_FILE}.tmp" "$ROLLBACK_FILE"
}

rollback_get_previous() {
  _require_jq
  local service="$1"
  jq -r --arg svc "$service" '.services[$svc].previous // empty' "$ROLLBACK_FILE"
}

# ──────────────────────────────────────────────
# 메인: 서브커맨드 라우팅
# ──────────────────────────────────────────────

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    # Pipeline
    pipeline-create)      pipeline_create "$@" ;;
    pipeline-generate-id) pipeline_generate_id ;;
    pipeline-update-stage) pipeline_update_stage "$@" ;;
    pipeline-finish)      pipeline_finish "$@" ;;
    pipeline-add-decision) pipeline_add_decision "$@" ;;
    pipeline-set-changes) pipeline_set_changes "$@" ;;
    pipeline-get-current) pipeline_get_current ;;
    pipeline-is-locked)   pipeline_is_locked ;;
    pipeline-lock)        pipeline_lock "$@" ;;
    pipeline-unlock)      pipeline_unlock ;;
    pipeline-failures)    pipeline_get_consecutive_failures ;;
    # Deployment
    deployment-record)    deployment_record "$@" ;;
    # Rollback
    rollback-register)    rollback_register "$@" ;;
    rollback-get-previous) rollback_get_previous "$@" ;;
    # Help
    help)
      echo "GonsAutoPilot State Manager"
      echo "사용법: state-manager.sh <command> [args]"
      echo ""
      echo "Pipeline 명령어:"
      echo "  pipeline-create <id> [trigger]    새 파이프라인 생성"
      echo "  pipeline-generate-id              파이프라인 ID 생성"
      echo "  pipeline-update-stage <id> <stage> <status> [result_json]"
      echo "  pipeline-finish <id> <status>     파이프라인 완료 (success|failed)"
      echo "  pipeline-add-decision <id> <agent> <action> <reason>"
      echo "  pipeline-set-changes <id> <changes_json>"
      echo "  pipeline-get-current              현재 파이프라인 조회"
      echo "  pipeline-is-locked                잠금 상태 확인"
      echo "  pipeline-lock <reason>            파이프라인 잠금"
      echo "  pipeline-unlock                   잠금 해제"
      echo "  pipeline-failures                 연속 실패 횟수"
      echo ""
      echo "Deployment 명령어:"
      echo "  deployment-record <pipeline_id> <services_json> <status>"
      echo ""
      echo "Rollback 명령어:"
      echo "  rollback-register <service> <tag> [status]"
      echo "  rollback-get-previous <service>   이전 이미지 태그 조회"
      ;;
    *)
      echo "ERROR: 알 수 없는 명령어: $cmd" >&2
      exit 1
      ;;
  esac
}

# 직접 실행 시에만 메인 함수 호출 (source 시에는 함수만 로드)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
