#!/usr/bin/env bash
# GonsAutoPilot - Test Agent 실행 엔진
# 설정을 읽고 필요한 테스트를 병렬로 실행하고 종합 리포트를 생성

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# 개별 테스트 실행 (백그라운드 프로세스용)
# ──────────────────────────────────────────────
_run_single_test() {
  local test_type="$1"
  local config_json="$2"
  local output_file="$3"

  source "${SCRIPT_DIR}/test-runners.sh"

  # 로그는 stderr로, JSON 결과만 stdout→파일로 보냄
  local log_file="${output_file}.log"

  case "$test_type" in
    unit)
      local cmd coverage_threshold
      cmd=$(echo "$config_json" | jq -r '.test.unit.command // "npm test"')
      coverage_threshold=$(echo "$config_json" | jq -r '.test.unit.coverage_threshold // 80')
      run_unit_test "$cmd" "$coverage_threshold" > "$output_file" 2>"$log_file"
      ;;
    e2e)
      local cmd
      cmd=$(echo "$config_json" | jq -r '.test.e2e.command // "npx playwright test"')
      run_e2e_test "$cmd" > "$output_file" 2>"$log_file"
      ;;
    performance)
      local url min_score
      url=$(echo "$config_json" | jq -r '.deploy.health_check.url // "http://localhost:3000"')
      min_score=$(echo "$config_json" | jq -r '.test.performance.min_score // 70')
      run_performance_test "$url" "$min_score" > "$output_file" 2>"$log_file"
      ;;
    security)
      local block_severity
      block_severity=$(echo "$config_json" | jq -r '.test.security.block_severity // "high"')
      run_security_test "$block_severity" > "$output_file" 2>"$log_file"
      ;;
    *)
      echo "{\"type\":\"$test_type\",\"status\":\"skipped\",\"reason\":\"알 수 없는 테스트 유형\"}" > "$output_file"
      ;;
  esac

  rm -f "$log_file"
}

# ──────────────────────────────────────────────
# 테스트 병렬 실행
# ──────────────────────────────────────────────
execute_tests() {
  local required_tests_json="$1"  # ["unit","e2e","security"] 형태의 JSON 배열
  local config_json="$2"          # 전체 설정 JSON

  local start_time=$SECONDS
  local tmp_dir="/tmp/gap-test-$$"
  mkdir -p "$tmp_dir"

  # 테스트 목록 파싱
  local tests=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && tests+=("$t")
  done < <(echo "$required_tests_json" | jq -r '.[]')

  if [[ ${#tests[@]} -eq 0 ]]; then
    jq -n '{
      overall: "skipped",
      tests: {},
      warnings: [],
      errors: [],
      total_duration_ms: 0,
      summary: { total: 0, passed: 0, failed: 0, warning: 0, skipped: 0 }
    }'
    rm -rf "$tmp_dir"
    return
  fi

  # 각 테스트를 백그라운드로 병렬 실행
  local pids=()
  for test_type in "${tests[@]}"; do
    local output_file="${tmp_dir}/${test_type}.json"
    _run_single_test "$test_type" "$config_json" "$output_file" &
    pids+=($!)
  done

  # 모든 테스트 완료 대기
  local exit_codes=()
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
    exit_codes+=($?)
  done

  local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))

  # 결과 수집
  local results="{}"
  local warnings=()
  local errors=()
  local count_passed=0 count_failed=0 count_warning=0 count_skipped=0

  for test_type in "${tests[@]}"; do
    local output_file="${tmp_dir}/${test_type}.json"

    if [[ -f "$output_file" ]]; then
      # 파일에서 유효한 JSON 추출 (마지막 유효한 JSON 객체를 사용)
      local result=""
      # jq로 직접 파일에서 JSON 파싱 시도
      if jq empty "$output_file" 2>/dev/null; then
        result=$(jq '.' "$output_file" 2>/dev/null)
      else
        # 여러 줄 중 JSON 블록만 추출
        result=$(python3 -c "
import json, sys
content = open('$output_file').read()
# JSON 시작점 찾기
idx = content.find('{')
if idx >= 0:
    try:
        obj = json.loads(content[idx:])
        print(json.dumps(obj))
    except:
        print('{}')
else:
    print('{}')
" 2>/dev/null || echo "{}")
      fi

      # JSON 유효성 검사
      if [[ -n "$result" ]] && echo "$result" | jq empty 2>/dev/null; then
        results=$(echo "$results" | jq --arg key "$test_type" --argjson val "$result" '. + {($key): $val}')

        local status
        status=$(echo "$result" | jq -r '.status')
        case "$status" in
          passed)  count_passed=$((count_passed + 1)) ;;
          failed)
            count_failed=$((count_failed + 1))
            local err_msg
            err_msg=$(echo "$result" | jq -r '.error // .block_reason // "알 수 없는 오류"')
            errors+=("${test_type}: ${err_msg}")
            ;;
          warning)
            count_warning=$((count_warning + 1))
            local warn_msg=""
            case "$test_type" in
              unit)
                warn_msg=$(echo "$result" | jq -r '"커버리지 \(.coverage)% (threshold: \(.coverage_threshold)%)"')
                ;;
              security)
                warn_msg=$(echo "$result" | jq -r '"취약점 - high:\(.vulnerabilities.high) moderate:\(.vulnerabilities.moderate)"')
                ;;
              performance)
                warn_msg=$(echo "$result" | jq -r '"점수 \(.score) (threshold: \(.min_score))"')
                ;;
            esac
            [[ -n "$warn_msg" ]] && warnings+=("${test_type}: ${warn_msg}")
            ;;
          skipped) count_skipped=$((count_skipped + 1)) ;;
        esac
      else
        results=$(echo "$results" | jq --arg key "$test_type" \
          '. + {($key): { type: $key, status: "failed", error: "결과 파싱 실패" }}')
        count_failed=$((count_failed + 1))
        errors+=("${test_type}: 결과 파싱 실패")
      fi
    else
      results=$(echo "$results" | jq --arg key "$test_type" \
        '. + {($key): { type: $key, status: "failed", error: "결과 파일 없음" }}')
      count_failed=$((count_failed + 1))
      errors+=("${test_type}: 결과 파일 없음")
    fi
  done

  # 정리
  rm -rf "$tmp_dir"

  # 전체 상태 결정
  local overall="passed"
  if [[ $count_failed -gt 0 ]]; then
    overall="failed"
  elif [[ $count_warning -gt 0 ]]; then
    overall="warning"
  elif [[ $count_skipped -eq ${#tests[@]} ]]; then
    overall="skipped"
  fi

  # warnings/errors를 JSON 배열로 변환
  local warnings_json errors_json
  if [[ ${#warnings[@]} -gt 0 ]]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  else
    warnings_json="[]"
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  else
    errors_json="[]"
  fi

  local total_tests=${#tests[@]}

  jq -n \
    --arg overall "$overall" \
    --argjson tests "$results" \
    --argjson warnings "$warnings_json" \
    --argjson errors "$errors_json" \
    --argjson total_duration_ms "$total_duration_ms" \
    --argjson total "$total_tests" \
    --argjson passed "$count_passed" \
    --argjson failed "$count_failed" \
    --argjson warning "$count_warning" \
    --argjson skipped "$count_skipped" \
    '{
      overall: $overall,
      tests: $tests,
      warnings: $warnings,
      errors: $errors,
      total_duration_ms: $total_duration_ms,
      summary: {
        total: $total,
        passed: $passed,
        failed: $failed,
        warning: $warning,
        skipped: $skipped
      }
    }'
}

# ──────────────────────────────────────────────
# 테스트 결과 출력
# ──────────────────────────────────────────────
print_report() {
  local report_json="$1"

  source "${SCRIPT_DIR}/test-runners.sh"

  local overall total_ms
  overall=$(echo "$report_json" | jq -r '.overall')
  total_ms=$(echo "$report_json" | jq '.total_duration_ms')
  local total_s
  total_s=$(echo "scale=1; $total_ms / 1000" | bc 2>/dev/null || echo "?")

  echo ""
  echo "  ┌─ 테스트 결과 (병렬 실행)"

  # 각 테스트 결과 출력
  local test_types
  test_types=$(echo "$report_json" | jq -r '.tests | keys[]')
  while IFS= read -r test_type; do
    [[ -z "$test_type" ]] && continue
    local result
    result=$(echo "$report_json" | jq ".tests.${test_type}")
    print_test_result "$result"
  done <<< "$test_types"

  echo "  │"

  # 경고 출력
  local warning_count
  warning_count=$(echo "$report_json" | jq '.warnings | length')
  if [[ "$warning_count" -gt 0 ]]; then
    echo "  ├─ 경고 ($warning_count건)"
    echo "$report_json" | jq -r '.warnings[]' | while IFS= read -r w; do
      echo "  │  ⚠️ $w"
    done
    echo "  │"
  fi

  # 에러 출력
  local error_count
  error_count=$(echo "$report_json" | jq '.errors | length')
  if [[ "$error_count" -gt 0 ]]; then
    echo "  ├─ 에러 ($error_count건)"
    echo "$report_json" | jq -r '.errors[]' | while IFS= read -r e; do
      echo "  │  ❌ $e"
    done
    echo "  │"
  fi

  # 요약
  local summary
  summary=$(echo "$report_json" | jq '.summary')
  local s_total s_passed s_failed s_warning s_skipped
  s_total=$(echo "$summary" | jq '.total')
  s_passed=$(echo "$summary" | jq '.passed')
  s_failed=$(echo "$summary" | jq '.failed')
  s_warning=$(echo "$summary" | jq '.warning')
  s_skipped=$(echo "$summary" | jq '.skipped')

  local overall_icon
  case "$overall" in
    passed)  overall_icon="✅" ;;
    failed)  overall_icon="❌" ;;
    warning) overall_icon="⚠️" ;;
    skipped) overall_icon="⏭️" ;;
    *)       overall_icon="❓" ;;
  esac

  echo "  └─ ${overall_icon} 전체: ${overall} — ${s_passed}/${s_total} passed"
  [[ "$s_warning" -gt 0 ]] && echo "     경고: ${s_warning}건"
  [[ "$s_failed" -gt 0 ]] && echo "     실패: ${s_failed}건"
  echo "     소요: ${total_s}s"
  echo ""
}

# 메인
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    execute)      execute_tests "$@" ;;
    print-report) print_report "$@" ;;
    help)
      echo "GonsAutoPilot Test Executor"
      echo "사용법: test-executor.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  execute <required_tests_json> <config_json>  테스트 병렬 실행"
      echo "  print-report <report_json>                   결과 리포트 출력"
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
