#!/usr/bin/env bash
# GonsAutoPilot - Monitor Agent 실행 엔진
# 배포 후 검증: 스모크 테스트 → 30초 와치독 → 이상 시 롤백 → 에스컬레이션

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# 스모크 테스트
# 핵심 엔드포인트 접근 + 응답 시간 측정
# ──────────────────────────────────────────────
run_smoke_test() {
  local config_json="$1"

  source "${SCRIPT_DIR}/docker-utils.sh"

  local health_url response_time_max
  health_url=$(echo "$config_json" | jq -r '.deploy.health_check.url // "http://localhost:3000/health"')
  response_time_max=$(echo "$config_json" | jq -r '.verify.smoke_test.response_time_max // 3000')

  # 추가 엔드포인트 (설정에 정의된 경우)
  local endpoints
  endpoints=$(echo "$config_json" | jq -r '.verify.smoke_test.endpoints // [] | .[]' 2>/dev/null)

  # 결과를 JSON으로 생성 (파일 기반 수집)
  local tmp_dir="/tmp/gap-smoke-$$"
  mkdir -p "$tmp_dir"

  # 헬스 엔드포인트
  local health_result_json
  health_result_json=$(_smoke_test_single "$health_url" "$response_time_max")
  echo "$health_result_json" > "$tmp_dir/health.json"

  # 추가 엔드포인트
  local idx=0
  if [[ -n "$endpoints" ]]; then
    while IFS= read -r endpoint; do
      [[ -z "$endpoint" ]] && continue
      local ep_result
      ep_result=$(_smoke_test_single "$endpoint" "$response_time_max")
      echo "$ep_result" > "$tmp_dir/ep_${idx}.json"
      idx=$((idx + 1))
    done <<< "$endpoints"
  fi

  # 결과 수집
  local test_results="[]"
  local count_passed=0 count_failed=0 count_warning=0

  for f in "$tmp_dir"/*.json; do
    [[ -f "$f" ]] || continue
    local result
    result=$(jq '.' "$f" 2>/dev/null || echo '{}')
    test_results=$(echo "$test_results" | jq --argjson r "$result" '. + [$r]')

    local status
    status=$(echo "$result" | jq -r '.status')
    case "$status" in
      passed)  count_passed=$((count_passed + 1)) ;;
      failed)  count_failed=$((count_failed + 1)) ;;
      warning) count_warning=$((count_warning + 1)) ;;
    esac
  done

  rm -rf "$tmp_dir"

  local overall="passed"
  if [[ $count_failed -gt 0 ]]; then
    overall="failed"
  elif [[ $count_warning -gt 0 ]]; then
    overall="warning"
  fi

  jq -n \
    --arg overall "$overall" \
    --argjson results "$test_results" \
    --argjson passed "$count_passed" \
    --argjson failed "$count_failed" \
    --argjson warning "$count_warning" \
    '{
      type: "smoke_test",
      overall: $overall,
      results: $results,
      summary: {
        total: ($passed + $failed + $warning),
        passed: $passed,
        failed: $failed,
        warning: $warning
      }
    }'
}

# 단일 URL 스모크 테스트
_smoke_test_single() {
  local url="$1"
  local max_time_ms="$2"
  local max_time_s
  max_time_s=$(echo "scale=0; $max_time_ms / 1000" | bc 2>/dev/null || echo "3")
  [[ "$max_time_s" -lt 1 ]] && max_time_s=3

  local response
  response=$(curl -s -o /dev/null -w '{"status_code":%{http_code},"time_ms":%{time_total},"size_bytes":%{size_download}}' \
    --max-time "$max_time_s" "$url" 2>/dev/null) || response='{"status_code":0,"time_ms":0,"size_bytes":0}'

  local status_code time_ms
  status_code=$(echo "$response" | jq -r '.status_code')
  # time_total은 초 단위 소수 → ms로 변환
  time_ms=$(echo "$response" | jq '(.time_ms * 1000) | floor')

  local status="passed"
  local detail=""

  if [[ "$status_code" == "0" ]]; then
    status="failed"
    detail="연결 실패 또는 타임아웃"
  elif [[ "$status_code" =~ ^5 ]]; then
    status="failed"
    detail="서버 에러 (HTTP ${status_code})"
  elif [[ "$status_code" =~ ^4 ]]; then
    status="warning"
    detail="클라이언트 에러 (HTTP ${status_code})"
  elif [[ $time_ms -gt $max_time_ms ]]; then
    status="warning"
    detail="응답 시간 초과 (${time_ms}ms > ${max_time_ms}ms)"
  fi

  jq -n \
    --arg url "$url" \
    --argjson status_code "$status_code" \
    --argjson time_ms "$time_ms" \
    --arg status "$status" \
    --arg detail "$detail" \
    '{
      url: $url,
      status_code: $status_code,
      time_ms: $time_ms,
      status: $status,
      detail: $detail
    }'
}

# ──────────────────────────────────────────────
# 30초 와치독 모니터링
# 배포 후 지정 시간 동안 서비스를 지속 감시
# ──────────────────────────────────────────────
run_watchdog() {
  local config_json="$1"
  local compose_file="$2"
  local services_json="$3"   # ["frontend","backend"]

  source "${SCRIPT_DIR}/docker-utils.sh"

  local health_url duration error_rate_max latency_spike_ratio
  health_url=$(echo "$config_json" | jq -r '.deploy.health_check.url // "http://localhost:3000/health"')
  duration=$(echo "$config_json" | jq -r '.verify.watchdog.duration // 30')
  error_rate_max=$(echo "$config_json" | jq -r '.verify.watchdog.error_rate_max // 0.01')
  latency_spike_ratio=$(echo "$config_json" | jq -r '.verify.watchdog.latency_spike_ratio // 2.0')

  local target_host target_user
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')

  local interval=5  # 5초마다 체크
  local checks=$((duration / interval))
  [[ $checks -lt 1 ]] && checks=1

  echo "와치독 시작: ${duration}초간 ${checks}회 체크 (${interval}초 간격)" >&2

  local total_requests=0
  local error_count=0
  local total_latency_ms=0
  local max_latency_ms=0
  local container_restarts_start=0
  local container_restarts_end=0
  local issues=()

  # 서비스 목록 파싱
  local services=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && services+=("$s")
  done < <(echo "$services_json" | jq -r '.[]' 2>/dev/null)

  # 초기 컨테이너 재시작 횟수 기록
  for svc in "${services[@]}"; do
    local restarts
    restarts=$(ssh "${target_user}@${target_host}" \
      "docker inspect --format='{{.RestartCount}}' \$(docker compose -f '$compose_file' ps -q '$svc' 2>/dev/null | head -1)" 2>/dev/null || echo "0")
    container_restarts_start=$((container_restarts_start + restarts))
  done

  # 모니터링 루프
  for i in $(seq 1 "$checks"); do
    total_requests=$((total_requests + 1))

    # HTTP 체크
    local response
    response=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "$health_url" 2>/dev/null) || response="000 0"

    local code latency_s
    code=$(echo "$response" | awk '{print $1}')
    latency_s=$(echo "$response" | awk '{print $2}')
    local latency_ms
    latency_ms=$(echo "$latency_s * 1000" | bc 2>/dev/null | cut -d. -f1)
    [[ -z "$latency_ms" ]] && latency_ms=0

    total_latency_ms=$((total_latency_ms + latency_ms))
    [[ $latency_ms -gt $max_latency_ms ]] && max_latency_ms=$latency_ms

    # 5xx 에러 체크
    if [[ "$code" =~ ^5 ]]; then
      error_count=$((error_count + 1))
      issues+=("체크 $i: HTTP ${code} 에러")
      echo "  ⚠️ 체크 $i/${checks}: HTTP ${code}" >&2
    elif [[ "$code" == "000" ]]; then
      error_count=$((error_count + 1))
      issues+=("체크 $i: 연결 실패")
      echo "  ⚠️ 체크 $i/${checks}: 연결 실패" >&2
    else
      echo "  ✓ 체크 $i/${checks}: HTTP ${code} (${latency_ms}ms)" >&2
    fi

    [[ $i -lt $checks ]] && sleep "$interval"
  done

  # 종료 후 컨테이너 재시작 횟수 확인
  for svc in "${services[@]}"; do
    local restarts
    restarts=$(ssh "${target_user}@${target_host}" \
      "docker inspect --format='{{.RestartCount}}' \$(docker compose -f '$compose_file' ps -q '$svc' 2>/dev/null | head -1)" 2>/dev/null || echo "0")
    container_restarts_end=$((container_restarts_end + restarts))
  done

  local new_restarts=$((container_restarts_end - container_restarts_start))
  if [[ $new_restarts -gt 0 ]]; then
    issues+=("컨테이너 재시작 감지: ${new_restarts}회")
  fi

  # 통계 계산
  local avg_latency_ms=0
  [[ $total_requests -gt 0 ]] && avg_latency_ms=$((total_latency_ms / total_requests))

  local error_rate="0"
  if [[ $total_requests -gt 0 ]]; then
    error_rate=$(echo "scale=4; $error_count / $total_requests" | bc 2>/dev/null || echo "0")
  fi

  # 롤백 필요 여부 판단
  local needs_rollback=false
  local rollback_reason=""

  # 5xx 에러 발생
  if [[ $error_count -gt 0 ]]; then
    needs_rollback=true
    rollback_reason="HTTP 5xx 에러 ${error_count}건 감지"
  fi

  # 컨테이너 재시작 감지
  if [[ $new_restarts -gt 0 ]]; then
    needs_rollback=true
    rollback_reason="컨테이너 재시작 ${new_restarts}회 감지 (crash loop 의심)"
  fi

  # 에러율 초과
  local error_rate_exceeded
  error_rate_exceeded=$(echo "$error_rate > $error_rate_max" | bc 2>/dev/null || echo "0")
  if [[ "$error_rate_exceeded" == "1" ]]; then
    needs_rollback=true
    rollback_reason="에러율 ${error_rate} > 최대 ${error_rate_max}"
  fi

  local overall="passed"
  if [[ "$needs_rollback" == "true" ]]; then
    overall="failed"
  elif [[ ${#issues[@]} -gt 0 ]]; then
    overall="warning"
  fi

  # issues를 JSON 배열로
  local issues_json
  if [[ ${#issues[@]} -gt 0 ]]; then
    issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
  else
    issues_json="[]"
  fi

  jq -n \
    --arg overall "$overall" \
    --argjson total_checks "$total_requests" \
    --argjson error_count "$error_count" \
    --arg error_rate "$error_rate" \
    --argjson avg_latency_ms "$avg_latency_ms" \
    --argjson max_latency_ms "$max_latency_ms" \
    --argjson container_restarts "$new_restarts" \
    --argjson duration "$duration" \
    --argjson needs_rollback "$needs_rollback" \
    --arg rollback_reason "$rollback_reason" \
    --argjson issues "$issues_json" \
    '{
      type: "watchdog",
      overall: $overall,
      duration_sec: $duration,
      total_checks: $total_checks,
      error_count: $error_count,
      error_rate: $error_rate,
      avg_latency_ms: $avg_latency_ms,
      max_latency_ms: $max_latency_ms,
      container_restarts: $container_restarts,
      needs_rollback: $needs_rollback,
      rollback_reason: $rollback_reason,
      issues: $issues
    }'
}

# ──────────────────────────────────────────────
# 배포 후 검증 (스모크 + 와치독 통합)
# ──────────────────────────────────────────────
execute_verify() {
  local pipeline_id="$1"
  local tags_json="$2"       # {"frontend":"app:tag","backend":"app:tag"}
  local config_json="$3"

  source "${SCRIPT_DIR}/docker-utils.sh"
  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true
  source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true

  local start_time=$SECONDS

  local target_host target_user compose_file
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')
  compose_file=$(echo "$config_json" | jq -r '.deploy.compose_file // "docker-compose.prod.yml"')

  local auto_rollback
  auto_rollback=$(echo "$config_json" | jq -r '.safety.auto_rollback // true')

  local services_json
  services_json=$(echo "$tags_json" | jq 'keys')

  # ── Step 1: 스모크 테스트 ──
  echo "" >&2
  echo "  ┌─ 스모크 테스트" >&2

  local smoke_result
  smoke_result=$(run_smoke_test "$config_json")

  local smoke_status
  smoke_status=$(echo "$smoke_result" | jq -r '.overall')

  # 스모크 결과 출력
  echo "$smoke_result" | jq -r '.results[]? | "  │ \(if .status == "passed" then "✅" elif .status == "warning" then "⚠️" else "❌" end) \(.url) → HTTP \(.status_code) (\(.time_ms)ms)"' >&2

  if [[ "$smoke_status" == "failed" ]]; then
    echo "  └─ ❌ 스모크 테스트 실패" >&2

    # 자동 롤백
    if [[ "$auto_rollback" == "true" ]]; then
      echo "" >&2
      echo "  ┌─ 자동 롤백 실행" >&2
      _auto_rollback "$pipeline_id" "$tags_json" "$config_json" "스모크 테스트 실패" >&2
      echo "  └─ 롤백 완료" >&2
    fi

    local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))
    jq -n \
      --argjson smoke "$smoke_result" \
      --argjson total_duration_ms "$total_duration_ms" \
      '{
        overall: "failed",
        stage: "smoke_test",
        smoke_test: $smoke,
        watchdog: null,
        rollback_triggered: true,
        rollback_reason: "스모크 테스트 실패",
        total_duration_ms: $total_duration_ms
      }'
    return 1
  fi

  echo "  └─ ✅ 스모크 테스트 통과" >&2

  # ── Step 2: 30초 와치독 ──
  echo "" >&2
  echo "  ┌─ 와치독 모니터링" >&2

  local watchdog_result
  watchdog_result=$(run_watchdog "$config_json" "$compose_file" "$services_json")

  local watchdog_status needs_rollback rollback_reason
  watchdog_status=$(echo "$watchdog_result" | jq -r '.overall')
  needs_rollback=$(echo "$watchdog_result" | jq -r '.needs_rollback')
  rollback_reason=$(echo "$watchdog_result" | jq -r '.rollback_reason // ""')

  # 와치독 요약 출력
  local w_checks w_errors w_avg_ms w_restarts
  w_checks=$(echo "$watchdog_result" | jq '.total_checks')
  w_errors=$(echo "$watchdog_result" | jq '.error_count')
  w_avg_ms=$(echo "$watchdog_result" | jq '.avg_latency_ms')
  w_restarts=$(echo "$watchdog_result" | jq '.container_restarts')

  echo "  │ 체크: ${w_checks}회, 에러: ${w_errors}건, 평균 응답: ${w_avg_ms}ms, 재시작: ${w_restarts}회" >&2

  if [[ "$needs_rollback" == "true" ]]; then
    echo "  └─ ❌ 와치독 이상 감지: $rollback_reason" >&2

    # 자동 롤백
    if [[ "$auto_rollback" == "true" ]]; then
      echo "" >&2
      echo "  ┌─ 자동 롤백 실행" >&2
      _auto_rollback "$pipeline_id" "$tags_json" "$config_json" "$rollback_reason" >&2
      echo "  └─ 롤백 완료" >&2
    fi

    # 에스컬레이션 체크
    _check_escalation "$pipeline_id" "$config_json" "$rollback_reason"

    local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))
    jq -n \
      --argjson smoke "$smoke_result" \
      --argjson watchdog "$watchdog_result" \
      --arg rollback_reason "$rollback_reason" \
      --argjson total_duration_ms "$total_duration_ms" \
      '{
        overall: "failed",
        stage: "watchdog",
        smoke_test: $smoke,
        watchdog: $watchdog,
        rollback_triggered: true,
        rollback_reason: $rollback_reason,
        total_duration_ms: $total_duration_ms
      }'
    return 1
  fi

  echo "  └─ ✅ 와치독 통과" >&2

  local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))
  jq -n \
    --argjson smoke "$smoke_result" \
    --argjson watchdog "$watchdog_result" \
    --argjson total_duration_ms "$total_duration_ms" \
    '{
      overall: "passed",
      smoke_test: $smoke,
      watchdog: $watchdog,
      rollback_triggered: false,
      rollback_reason: "",
      total_duration_ms: $total_duration_ms
    }'
}

# ──────────────────────────────────────────────
# 자동 롤백 실행 (내부 함수)
# ──────────────────────────────────────────────
_auto_rollback() {
  local pipeline_id="$1"
  local tags_json="$2"
  local config_json="$3"
  local reason="$4"

  source "${SCRIPT_DIR}/docker-utils.sh"
  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true
  source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true

  local target_host target_user compose_file
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')
  compose_file=$(echo "$config_json" | jq -r '.deploy.compose_file // "docker-compose.prod.yml"')

  local services
  services=$(echo "$tags_json" | jq -r 'keys[]')

  while IFS= read -r service; do
    [[ -z "$service" ]] && continue

    local old_tag
    old_tag=$(rollback_get_previous "$service" 2>/dev/null || echo "")

    if [[ -n "$old_tag" && "$old_tag" != "null" ]]; then
      local current_tag
      current_tag=$(echo "$tags_json" | jq -r --arg k "$service" '.[$k] // "unknown"')

      echo "  │ ↩️ $service: $current_tag → $old_tag" >&2
      rollback_service "$compose_file" "$service" "$old_tag" "$target_host" "$target_user" >/dev/null 2>&1 || true

      # 알림
      notify_rollback "$pipeline_id" "$service" "$current_tag" "$old_tag" 2>/dev/null || true
    else
      echo "  │ ⚠️ $service: 이전 이미지 없음 (롤백 불가)" >&2
    fi
  done <<< "$services"
}

# ──────────────────────────────────────────────
# 에스컬레이션 체크 (내부 함수)
# ──────────────────────────────────────────────
_check_escalation() {
  local pipeline_id="$1"
  local config_json="$2"
  local reason="$3"

  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true
  source "${SCRIPT_DIR}/notify.sh" 2>/dev/null || true

  local max_failures
  max_failures=$(echo "$config_json" | jq -r '.safety.max_consecutive_failures // 3')

  local consecutive
  consecutive=$(pipeline_get_consecutive_failures 2>/dev/null || echo "0")

  if [[ $consecutive -ge $max_failures ]]; then
    echo "" >&2
    echo "  🚨 연속 ${consecutive}회 실패! 파이프라인 잠금 + 에스컬레이션" >&2
    pipeline_lock "연속 ${consecutive}회 실패: ${reason}" 2>/dev/null || true
    notify_escalation "$pipeline_id" "$consecutive" "$reason" 2>/dev/null || true
  elif [[ $consecutive -ge 2 ]]; then
    echo "" >&2
    echo "  ⚠️ 연속 ${consecutive}회 실패. (${max_failures}회 도달 시 잠금)" >&2
  fi
}

# ──────────────────────────────────────────────
# 검증 결과 출력
# ──────────────────────────────────────────────
print_verify_report() {
  local report_json="$1"

  local overall total_ms
  overall=$(echo "$report_json" | jq -r '.overall')
  total_ms=$(echo "$report_json" | jq '.total_duration_ms')
  local total_s
  total_s=$(echo "scale=1; $total_ms / 1000" | bc 2>/dev/null || echo "?")

  echo ""
  echo "  ┌─ 배포 후 검증 결과"

  # 스모크 테스트
  local smoke_status
  smoke_status=$(echo "$report_json" | jq -r '.smoke_test.overall // "N/A"')
  local smoke_icon
  case "$smoke_status" in
    passed)  smoke_icon="✅" ;;
    failed)  smoke_icon="❌" ;;
    warning) smoke_icon="⚠️" ;;
    *)       smoke_icon="❓" ;;
  esac
  local smoke_total smoke_passed
  smoke_total=$(echo "$report_json" | jq '.smoke_test.summary.total // 0')
  smoke_passed=$(echo "$report_json" | jq '.smoke_test.summary.passed // 0')
  echo "  │ ${smoke_icon} 스모크 테스트: ${smoke_passed}/${smoke_total} passed"

  # 와치독
  local watchdog
  watchdog=$(echo "$report_json" | jq '.watchdog')
  if [[ "$watchdog" != "null" ]]; then
    local wd_status wd_checks wd_errors wd_avg wd_duration
    wd_status=$(echo "$watchdog" | jq -r '.overall')
    wd_checks=$(echo "$watchdog" | jq '.total_checks')
    wd_errors=$(echo "$watchdog" | jq '.error_count')
    wd_avg=$(echo "$watchdog" | jq '.avg_latency_ms')
    wd_duration=$(echo "$watchdog" | jq '.duration_sec')

    local wd_icon
    case "$wd_status" in
      passed)  wd_icon="✅" ;;
      failed)  wd_icon="❌" ;;
      warning) wd_icon="⚠️" ;;
      *)       wd_icon="❓" ;;
    esac
    echo "  │ ${wd_icon} 와치독 (${wd_duration}초): 체크 ${wd_checks}회, 에러 ${wd_errors}건, 평균 ${wd_avg}ms"
  else
    echo "  │ ⏭️ 와치독: 미실행 (스모크 테스트 실패로 스킵)"
  fi

  echo "  │"

  # 롤백 정보
  local rollback_triggered
  rollback_triggered=$(echo "$report_json" | jq -r '.rollback_triggered')
  if [[ "$rollback_triggered" == "true" ]]; then
    local rollback_reason
    rollback_reason=$(echo "$report_json" | jq -r '.rollback_reason')
    echo "  │ ↩️ 자동 롤백: ${rollback_reason}"
    echo "  │"
  fi

  # 요약
  local overall_icon
  case "$overall" in
    passed)  overall_icon="✅" ;;
    failed)  overall_icon="❌" ;;
    warning) overall_icon="⚠️" ;;
    *)       overall_icon="❓" ;;
  esac

  echo "  └─ ${overall_icon} 전체: ${overall} (소요: ${total_s}s)"
  echo ""
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    smoke-test)     run_smoke_test "$@" ;;
    watchdog)       run_watchdog "$@" ;;
    verify)         execute_verify "$@" ;;
    print-report)   print_verify_report "$@" ;;
    help)
      echo "GonsAutoPilot Monitor Executor"
      echo "사용법: monitor-executor.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  smoke-test <config_json>                         스모크 테스트"
      echo "  watchdog <config_json> <compose_file> <services_json>  와치독"
      echo "  verify <pipeline_id> <tags_json> <config_json>   전체 검증"
      echo "  print-report <report_json>                       결과 출력"
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
