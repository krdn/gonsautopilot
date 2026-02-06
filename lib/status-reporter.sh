#!/usr/bin/env bash
# GonsAutoPilot - 상태 리포트 + 통계 엔진
# 파이프라인 상태 조회, 배포 이력, 성공률 통계

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../state"

# ──────────────────────────────────────────────
# 현재/마지막 파이프라인 상태 포맷팅 출력
# ──────────────────────────────────────────────
print_pipeline_status() {
  local pipeline_file="${STATE_DIR}/pipeline.json"

  if [[ ! -f "$pipeline_file" ]]; then
    echo "  상태 파일이 없습니다."
    return 1
  fi

  local current
  current=$(jq -r '.current // empty' "$pipeline_file")

  if [[ -z "$current" ]]; then
    echo ""
    echo "  실행된 파이프라인이 없습니다."
    echo "  → /gonsautopilot 으로 파이프라인을 시작하세요."
    echo ""
    return 0
  fi

  # 파이프라인 정보 추출
  local pipeline
  pipeline=$(jq --arg pid "$current" '.pipelines[] | select(.pipeline_id == $pid)' "$pipeline_file")

  if [[ -z "$pipeline" || "$pipeline" == "null" ]]; then
    echo "  파이프라인 #${current}을 찾을 수 없습니다."
    return 1
  fi

  local status trigger started finished
  status=$(echo "$pipeline" | jq -r '.status // "unknown"')
  trigger=$(echo "$pipeline" | jq -r '.trigger // "manual"')
  started=$(echo "$pipeline" | jq -r '.started_at // "N/A"')
  finished=$(echo "$pipeline" | jq -r '.finished_at // "진행 중"')

  # 상태 아이콘
  local status_icon
  case "$status" in
    running) status_icon="🔄" ;;
    success) status_icon="✅" ;;
    failed)  status_icon="❌" ;;
    *)       status_icon="❓" ;;
  esac

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  GonsAutoPilot — Pipeline Status"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "  Pipeline:  #${current}"
  echo "  상태:      ${status_icon} ${status}"
  echo "  트리거:    ${trigger}"
  echo "  시작:      ${started}"
  echo "  완료:      ${finished}"
  echo ""

  # Stages 출력
  echo "  ┌─ Stages"
  local stages=("analyze" "test" "build" "deploy" "verify")
  for stage_name in "${stages[@]}"; do
    local stage_status
    stage_status=$(echo "$pipeline" | jq -r --arg s "$stage_name" \
      '.stages[]? | select(.name == $s) | .status // "pending"' 2>/dev/null)
    [[ -z "$stage_status" ]] && stage_status="pending"

    local icon
    case "$stage_status" in
      passed|success) icon="✅" ;;
      failed)         icon="❌" ;;
      running)        icon="🔄" ;;
      warning)        icon="⚠️" ;;
      skipped)        icon="⏭️" ;;
      *)              icon="⏳" ;;
    esac

    printf "  │  %-10s %s %s\n" "${stage_name}:" "$icon" "$stage_status"
  done
  echo "  │"

  # Changes 출력
  local changes
  changes=$(echo "$pipeline" | jq '.changes // null')
  if [[ "$changes" != "null" ]]; then
    echo "  ├─ Changes"
    local categories=("frontend" "backend" "shared" "config" "database" "test" "other")
    for cat in "${categories[@]}"; do
      local count
      count=$(echo "$changes" | jq --arg c "$cat" '.categories[$c] // [] | length')
      [[ "$count" -gt 0 ]] && printf "  │  %-10s %s files\n" "${cat}:" "$count"
    done
    echo "  │"
  fi

  # Decisions 출력
  local decisions
  decisions=$(echo "$pipeline" | jq '.decisions // []')
  local decision_count
  decision_count=$(echo "$decisions" | jq 'length')
  if [[ "$decision_count" -gt 0 ]]; then
    echo "  ├─ Decisions"
    echo "$decisions" | jq -r '.[] | "  │  - \(.action): \(.reason)"' 2>/dev/null
    echo "  │"
  fi

  # Stats 출력
  local stats
  stats=$(jq '.stats' "$pipeline_file")
  local s_total s_success s_failure s_consecutive
  s_total=$(echo "$stats" | jq '.total_runs // 0')
  s_success=$(echo "$stats" | jq '.success_count // 0')
  s_failure=$(echo "$stats" | jq '.failure_count // 0')
  s_consecutive=$(echo "$stats" | jq '.consecutive_failures // 0')

  echo "  └─ Stats"
  echo "     총 실행: ${s_total} | 성공: ${s_success} | 실패: ${s_failure} | 연속 실패: ${s_consecutive}"
  echo ""

  # 잠금 상태
  local lock
  lock=$(jq '.lock' "$pipeline_file")
  local locked
  locked=$(echo "$lock" | jq -r '.locked // false')
  if [[ "$locked" == "true" ]]; then
    local lock_reason lock_at
    lock_reason=$(echo "$lock" | jq -r '.reason // "알 수 없음"')
    lock_at=$(echo "$lock" | jq -r '.locked_at // "N/A"')
    echo "  🔒 파이프라인 잠금 상태"
    echo "     이유: ${lock_reason}"
    echo "     잠금 시각: ${lock_at}"
    echo "     해제: /gonsautopilot:unlock 실행"
    echo ""
  fi

  echo "═══════════════════════════════════════════════════════"
  echo ""
}

# ──────────────────────────────────────────────
# 배포 이력 조회
# ──────────────────────────────────────────────
print_deployment_history() {
  local limit="${1:-10}"
  local deploy_file="${STATE_DIR}/deployments.json"

  if [[ ! -f "$deploy_file" ]]; then
    echo "  배포 이력이 없습니다."
    return 0
  fi

  local total
  total=$(jq '.deployments | length' "$deploy_file")

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  GonsAutoPilot — Deployment History"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "  총 배포: ${total}건 (최근 ${limit}건 표시)"
  echo ""

  if [[ "$total" -eq 0 ]]; then
    echo "  배포 이력이 없습니다."
    echo ""
    echo "═══════════════════════════════════════════════════════"
    return 0
  fi

  # 최근 N건 출력
  echo "  ┌─ 최근 배포"
  jq -r --argjson limit "$limit" \
    '.deployments | sort_by(.deployed_at) | reverse | .[:$limit] | .[] |
    "  │ \(if .status == "success" then "✅" else "❌" end) \(.deployed_at // "N/A") | \(.service // "?") → \(.tag // "?") | Pipeline #\(.pipeline_id // "?")"' \
    "$deploy_file" 2>/dev/null || echo "  │ (파싱 오류)"

  echo "  │"

  # 마지막 성공 배포
  local last_success
  last_success=$(jq -r '.last_successful // "없음"' "$deploy_file")
  echo "  └─ 마지막 성공: ${last_success}"
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo ""
}

# ──────────────────────────────────────────────
# 성공률 통계
# ──────────────────────────────────────────────
print_statistics() {
  local pipeline_file="${STATE_DIR}/pipeline.json"
  local deploy_file="${STATE_DIR}/deployments.json"

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  GonsAutoPilot — Statistics"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  # 파이프라인 통계
  if [[ -f "$pipeline_file" ]]; then
    local stats
    stats=$(jq '.stats' "$pipeline_file")

    local total success failure
    total=$(echo "$stats" | jq '.total_runs // 0')
    success=$(echo "$stats" | jq '.success_count // 0')
    failure=$(echo "$stats" | jq '.failure_count // 0')

    local success_rate="0"
    if [[ $total -gt 0 ]]; then
      success_rate=$(echo "scale=1; $success * 100 / $total" | bc 2>/dev/null || echo "?")
    fi

    echo "  ┌─ 파이프라인"
    echo "  │ 총 실행:    ${total}회"
    echo "  │ 성공:       ${success}회"
    echo "  │ 실패:       ${failure}회"
    echo "  │ 성공률:     ${success_rate}%"
    echo "  │"

    # 파이프라인 목록에서 추가 통계
    local pipeline_count
    pipeline_count=$(jq '.pipelines | length' "$pipeline_file")
    if [[ $pipeline_count -gt 0 ]]; then
      # 스테이지별 실패 횟수
      echo "  ├─ 스테이지별 실패"
      local stage_names=("analyze" "test" "build" "deploy" "verify")
      for stage in "${stage_names[@]}"; do
        local stage_failures
        stage_failures=$(jq --arg s "$stage" \
          '[.pipelines[].stages[]? | select(.name == $s and .status == "failed")] | length' \
          "$pipeline_file" 2>/dev/null || echo "0")
        [[ "$stage_failures" -gt 0 ]] && echo "  │  ${stage}: ${stage_failures}회"
      done
      echo "  │"
    fi
  else
    echo "  파이프라인 데이터 없음"
    echo ""
  fi

  # 배포 통계
  if [[ -f "$deploy_file" ]]; then
    local deploy_total deploy_success deploy_failed
    deploy_total=$(jq '.deployments | length' "$deploy_file")
    deploy_success=$(jq '[.deployments[] | select(.status == "success")] | length' "$deploy_file" 2>/dev/null || echo "0")
    deploy_failed=$((deploy_total - deploy_success))

    local deploy_rate="0"
    if [[ $deploy_total -gt 0 ]]; then
      deploy_rate=$(echo "scale=1; $deploy_success * 100 / $deploy_total" | bc 2>/dev/null || echo "?")
    fi

    echo "  └─ 배포"
    echo "     총 배포:    ${deploy_total}회"
    echo "     성공:       ${deploy_success}회"
    echo "     실패:       ${deploy_failed}회"
    echo "     성공률:     ${deploy_rate}%"
  else
    echo "  └─ 배포 데이터 없음"
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo ""
}

# ──────────────────────────────────────────────
# 롤백 레지스트리 상태
# ──────────────────────────────────────────────
print_rollback_status() {
  local registry_file="${STATE_DIR}/rollback-registry.json"

  if [[ ! -f "$registry_file" ]]; then
    echo "  롤백 레지스트리가 없습니다."
    return 0
  fi

  echo ""
  echo "  ┌─ 롤백 가능 서비스"

  local services
  services=$(jq -r '.services | keys[]' "$registry_file" 2>/dev/null)

  if [[ -z "$services" ]]; then
    echo "  │ (등록된 서비스 없음)"
  else
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      local current previous
      current=$(jq -r --arg s "$svc" '.services[$s].current // "N/A"' "$registry_file")
      previous=$(jq -r --arg s "$svc" '.services[$s].previous // "없음"' "$registry_file")
      echo "  │ ${svc}: 현재 ${current} ← 이전 ${previous}"
    done <<< "$services"
  fi

  echo "  └─"
  echo ""
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-status}"
  shift || true

  case "$cmd" in
    status)          print_pipeline_status ;;
    deployments)     print_deployment_history "$@" ;;
    statistics|stats) print_statistics ;;
    rollback-status) print_rollback_status ;;
    full)
      print_pipeline_status
      print_rollback_status
      print_statistics
      ;;
    help)
      echo "GonsAutoPilot Status Reporter"
      echo "사용법: status-reporter.sh <command>"
      echo ""
      echo "명령어:"
      echo "  status          현재 파이프라인 상태"
      echo "  deployments [n] 배포 이력 (최근 n건)"
      echo "  statistics      성공률 통계"
      echo "  rollback-status 롤백 가능 서비스"
      echo "  full            전체 리포트"
      ;;
    *)
      echo "ERROR: 알 수 없는 명령어: $cmd" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
