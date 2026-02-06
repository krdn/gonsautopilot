#!/usr/bin/env bash
# GonsAutoPilot - 테스트 실행기 래퍼
# 각 테스트 종류별 실행 및 상세 결과 파싱

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# 단위 테스트
# ──────────────────────────────────────────────
run_unit_test() {
  local command="${1:-npm test}"
  local coverage_threshold="${2:-80}"
  local start_time=$SECONDS
  local result_file="/tmp/gap-unit-test-$$.json"

  # 명령어에서 기본 도구 감지
  local tool="unknown"
  if [[ "$command" =~ jest ]]; then tool="jest"
  elif [[ "$command" =~ vitest ]]; then tool="vitest"
  elif [[ "$command" == "npm test" ]]; then tool="npm"
  fi

  local output="" exit_code=0

  # jest/vitest용 JSON 리포터로 실행
  case "$tool" in
    jest|npm)
      output=$(eval "$command -- --coverage --json --outputFile=$result_file" 2>&1) || exit_code=$?
      ;;
    vitest)
      output=$(eval "$command --reporter=json --coverage" 2>&1) || exit_code=$?
      echo "$output" > "$result_file" 2>/dev/null || true
      ;;
    *)
      output=$(eval "$command" 2>&1) || exit_code=$?
      ;;
  esac

  local duration_ms=$(( (SECONDS - start_time) * 1000 ))

  # 결과 파싱
  local total=0 passed=0 failed=0 skipped=0 coverage=0

  if [[ -f "$result_file" ]]; then
    total=$(jq '.numTotalTests // 0' "$result_file" 2>/dev/null || echo "0")
    passed=$(jq '.numPassedTests // 0' "$result_file" 2>/dev/null || echo "0")
    failed=$(jq '.numFailedTests // 0' "$result_file" 2>/dev/null || echo "0")
    skipped=$(jq '.numPendingTests // 0' "$result_file" 2>/dev/null || echo "0")

    # 커버리지 파싱 (jest의 coverageSummary)
    if jq -e '.coverageMap' "$result_file" &>/dev/null; then
      coverage=$(jq '[.coverageMap | to_entries[].value.s | to_entries | map(.value) | add] |
        if length > 0 then (map(select(. > 0)) | length) / length * 100 | floor else 0 end' \
        "$result_file" 2>/dev/null || echo "0")
    fi

    rm -f "$result_file"
  else
    # JSON 파일 없으면 출력에서 파싱 시도
    if [[ -n "$output" ]]; then
      # "Tests: X passed, Y failed" 패턴 파싱
      passed=$(echo "$output" | grep -oP '(\d+) passed' | grep -oP '\d+' | head -1 || echo "0")
      failed=$(echo "$output" | grep -oP '(\d+) failed' | grep -oP '\d+' | head -1 || echo "0")
      total=$((passed + failed))

      # coverage 파싱: "All files | XX.XX |"
      coverage=$(echo "$output" | grep -oP 'All files\s*\|\s*[\d.]+' | grep -oP '[\d.]+$' | head -1 || echo "0")
    fi
  fi

  # threshold 비교
  local status="passed"
  local warnings=()

  if [[ $exit_code -ne 0 || "$failed" -gt 0 ]]; then
    status="failed"
  fi

  # 커버리지 체크 (정수 비교)
  local cov_int=${coverage%.*}
  cov_int=${cov_int:-0}
  if [[ "$status" == "passed" && "$cov_int" -lt "$coverage_threshold" ]]; then
    status="warning"
    warnings+=("커버리지 ${cov_int}%가 threshold ${coverage_threshold}% 미만")
  fi

  jq -n \
    --arg status "$status" \
    --arg tool "$tool" \
    --argjson total "${total:-0}" \
    --argjson passed "${passed:-0}" \
    --argjson failed "${failed:-0}" \
    --argjson skipped "${skipped:-0}" \
    --argjson coverage "${cov_int:-0}" \
    --argjson coverage_threshold "$coverage_threshold" \
    --argjson duration_ms "$duration_ms" \
    --argjson exit_code "$exit_code" \
    '{
      type: "unit",
      status: $status,
      tool: $tool,
      total: $total,
      passed: $passed,
      failed: $failed,
      skipped: $skipped,
      coverage: $coverage,
      coverage_threshold: $coverage_threshold,
      duration_ms: $duration_ms,
      exit_code: $exit_code
    }'
}

# ──────────────────────────────────────────────
# E2E 테스트
# ──────────────────────────────────────────────
run_e2e_test() {
  local command="${1:-npx playwright test}"
  local start_time=$SECONDS
  local result_file="/tmp/gap-e2e-test-$$.json"

  local output="" exit_code=0

  # Playwright JSON 리포터
  if [[ "$command" =~ playwright ]]; then
    output=$(eval "PLAYWRIGHT_JSON_OUTPUT_NAME=$result_file $command --reporter=json" 2>&1) || exit_code=$?
  else
    output=$(eval "$command" 2>&1) || exit_code=$?
  fi

  local duration_ms=$(( (SECONDS - start_time) * 1000 ))

  local total=0 passed=0 failed=0 skipped=0 flaky=0

  if [[ -f "$result_file" ]]; then
    # Playwright JSON 결과 파싱
    total=$(jq '.stats.expected + .stats.unexpected + .stats.flaky + .stats.skipped' "$result_file" 2>/dev/null || echo "0")
    passed=$(jq '.stats.expected // 0' "$result_file" 2>/dev/null || echo "0")
    failed=$(jq '.stats.unexpected // 0' "$result_file" 2>/dev/null || echo "0")
    skipped=$(jq '.stats.skipped // 0' "$result_file" 2>/dev/null || echo "0")
    flaky=$(jq '.stats.flaky // 0' "$result_file" 2>/dev/null || echo "0")
    rm -f "$result_file"
  else
    # 출력에서 파싱 시도
    if [[ -n "$output" ]]; then
      passed=$(echo "$output" | grep -oP '(\d+) passed' | grep -oP '\d+' | head -1 || echo "0")
      failed=$(echo "$output" | grep -oP '(\d+) failed' | grep -oP '\d+' | head -1 || echo "0")
      total=$((passed + failed))
    fi
  fi

  local status="passed"
  if [[ $exit_code -ne 0 || "$failed" -gt 0 ]]; then
    status="failed"
  fi

  jq -n \
    --arg status "$status" \
    --argjson total "${total:-0}" \
    --argjson passed "${passed:-0}" \
    --argjson failed "${failed:-0}" \
    --argjson skipped "${skipped:-0}" \
    --argjson flaky "${flaky:-0}" \
    --argjson duration_ms "$duration_ms" \
    --argjson exit_code "$exit_code" \
    '{
      type: "e2e",
      status: $status,
      total: $total,
      passed: $passed,
      failed: $failed,
      skipped: $skipped,
      flaky: $flaky,
      duration_ms: $duration_ms,
      exit_code: $exit_code
    }'
}

# ──────────────────────────────────────────────
# 성능 테스트 (Lighthouse)
# ──────────────────────────────────────────────
run_performance_test() {
  local url="${1:-http://localhost:3000}"
  local min_score="${2:-70}"
  local start_time=$SECONDS
  local result_file="/tmp/gap-lighthouse-$$.json"

  if ! command -v lighthouse &>/dev/null; then
    jq -n --argjson duration_ms "0" \
      '{ type: "performance", status: "skipped", reason: "lighthouse CLI가 설치되어 있지 않습니다 (npm i -g lighthouse)", duration_ms: $duration_ms }'
    return
  fi

  local exit_code=0
  lighthouse "$url" \
    --output=json \
    --output-path="$result_file" \
    --chrome-flags="--headless --no-sandbox --disable-gpu" \
    --only-categories=performance \
    --quiet 2>/dev/null || exit_code=$?

  local duration_ms=$(( (SECONDS - start_time) * 1000 ))

  if [[ -f "$result_file" && $exit_code -eq 0 ]]; then
    local score lcp fid cls ttfb si
    score=$(jq '.categories.performance.score * 100 | floor' "$result_file" 2>/dev/null || echo "0")
    lcp=$(jq '.audits["largest-contentful-paint"].numericValue | floor' "$result_file" 2>/dev/null || echo "0")
    fid=$(jq '.audits["max-potential-fid"].numericValue | floor' "$result_file" 2>/dev/null || echo "0")
    cls=$(jq '.audits["cumulative-layout-shift"].numericValue' "$result_file" 2>/dev/null || echo "0")
    ttfb=$(jq '.audits["server-response-time"].numericValue | floor' "$result_file" 2>/dev/null || echo "0")
    si=$(jq '.audits["speed-index"].numericValue | floor' "$result_file" 2>/dev/null || echo "0")

    rm -f "$result_file"

    local status="passed"
    local score_int=${score%.*}
    score_int=${score_int:-0}
    if [[ "$score_int" -lt "$min_score" ]]; then
      status="warning"
    fi

    jq -n \
      --arg status "$status" \
      --argjson score "$score_int" \
      --argjson min_score "$min_score" \
      --argjson lcp "${lcp:-0}" \
      --argjson fid "${fid:-0}" \
      --argjson cls "${cls:-0}" \
      --argjson ttfb "${ttfb:-0}" \
      --argjson si "${si:-0}" \
      --argjson duration_ms "$duration_ms" \
      '{
        type: "performance",
        status: $status,
        score: $score,
        min_score: $min_score,
        metrics: { lcp_ms: $lcp, fid_ms: $fid, cls: $cls, ttfb_ms: $ttfb, speed_index_ms: $si },
        duration_ms: $duration_ms
      }'
  else
    rm -f "$result_file"
    jq -n \
      --argjson duration_ms "$duration_ms" \
      '{ type: "performance", status: "failed", error: "Lighthouse 실행 실패", duration_ms: $duration_ms }'
  fi
}

# ──────────────────────────────────────────────
# 보안 테스트 (npm audit)
# ──────────────────────────────────────────────
run_security_test() {
  local block_severity="${1:-high}"
  local start_time=$SECONDS

  if [[ ! -f "package.json" ]]; then
    jq -n '{ type: "security", status: "skipped", reason: "package.json 없음", duration_ms: 0 }'
    return
  fi

  local output="" exit_code=0
  output=$(npm audit --json 2>/dev/null) || exit_code=$?

  local duration_ms=$(( (SECONDS - start_time) * 1000 ))

  if [[ -n "$output" ]]; then
    local critical high moderate low info total_vuln
    critical=$(echo "$output" | jq '.metadata.vulnerabilities.critical // 0' 2>/dev/null || echo "0")
    high=$(echo "$output" | jq '.metadata.vulnerabilities.high // 0' 2>/dev/null || echo "0")
    moderate=$(echo "$output" | jq '.metadata.vulnerabilities.moderate // 0' 2>/dev/null || echo "0")
    low=$(echo "$output" | jq '.metadata.vulnerabilities.low // 0' 2>/dev/null || echo "0")
    info=$(echo "$output" | jq '.metadata.vulnerabilities.info // 0' 2>/dev/null || echo "0")
    total_vuln=$(echo "$output" | jq '.metadata.vulnerabilities.total // 0' 2>/dev/null || echo "0")

    # 심각도에 따른 상태 결정
    local status="passed"
    local block_reason=""

    case "$block_severity" in
      critical)
        if [[ "${critical:-0}" -gt 0 ]]; then
          status="failed"
          block_reason="critical 취약점 ${critical}건 발견"
        elif [[ "${high:-0}" -gt 0 || "${moderate:-0}" -gt 0 ]]; then
          status="warning"
        fi
        ;;
      high)
        if [[ "${critical:-0}" -gt 0 || "${high:-0}" -gt 0 ]]; then
          status="failed"
          block_reason="high+ 취약점 발견 (critical: ${critical}, high: ${high})"
        elif [[ "${moderate:-0}" -gt 0 ]]; then
          status="warning"
        fi
        ;;
      moderate)
        if [[ "${critical:-0}" -gt 0 || "${high:-0}" -gt 0 || "${moderate:-0}" -gt 0 ]]; then
          status="failed"
          block_reason="moderate+ 취약점 발견"
        fi
        ;;
    esac

    jq -n \
      --arg status "$status" \
      --arg block_severity "$block_severity" \
      --arg block_reason "$block_reason" \
      --argjson critical "${critical:-0}" \
      --argjson high "${high:-0}" \
      --argjson moderate "${moderate:-0}" \
      --argjson low "${low:-0}" \
      --argjson info "${info:-0}" \
      --argjson total "${total_vuln:-0}" \
      --argjson duration_ms "$duration_ms" \
      '{
        type: "security",
        status: $status,
        block_severity: $block_severity,
        block_reason: (if $block_reason == "" then null else $block_reason end),
        vulnerabilities: {
          critical: $critical,
          high: $high,
          moderate: $moderate,
          low: $low,
          info: $info,
          total: $total
        },
        duration_ms: $duration_ms
      }'
  else
    jq -n \
      --argjson duration_ms "$duration_ms" \
      '{ type: "security", status: "skipped", reason: "npm audit 실행 실패", duration_ms: $duration_ms }'
  fi
}

# ──────────────────────────────────────────────
# 결과 출력 포맷터
# ──────────────────────────────────────────────
print_test_result() {
  local result_json="$1"

  local type status duration_ms
  type=$(echo "$result_json" | jq -r '.type')
  status=$(echo "$result_json" | jq -r '.status')
  duration_ms=$(echo "$result_json" | jq -r '.duration_ms')
  local duration_s=$(echo "scale=1; $duration_ms / 1000" | bc 2>/dev/null || echo "?")

  local icon
  case "$status" in
    passed)  icon="✅" ;;
    failed)  icon="❌" ;;
    warning) icon="⚠️" ;;
    skipped) icon="⏭️" ;;
    *)       icon="❓" ;;
  esac

  local label
  case "$type" in
    unit)        label="Unit Test" ;;
    e2e)         label="E2E Test" ;;
    performance) label="Performance" ;;
    security)    label="Security" ;;
    *)           label="$type" ;;
  esac

  echo "  │  ${icon} [${label}] ${status} (${duration_s}s)"

  # 상세 정보
  case "$type" in
    unit)
      local total passed failed coverage
      total=$(echo "$result_json" | jq '.total')
      passed=$(echo "$result_json" | jq '.passed')
      failed=$(echo "$result_json" | jq '.failed')
      coverage=$(echo "$result_json" | jq '.coverage')
      echo "  │     ${passed}/${total} passed, coverage: ${coverage}%"
      ;;
    e2e)
      local total passed failed
      total=$(echo "$result_json" | jq '.total')
      passed=$(echo "$result_json" | jq '.passed')
      failed=$(echo "$result_json" | jq '.failed')
      echo "  │     ${passed}/${total} scenarios passed"
      ;;
    performance)
      if [[ "$status" != "skipped" ]]; then
        local score lcp
        score=$(echo "$result_json" | jq '.score')
        lcp=$(echo "$result_json" | jq '.metrics.lcp_ms // 0')
        echo "  │     Score: ${score}, LCP: ${lcp}ms"
      else
        local reason
        reason=$(echo "$result_json" | jq -r '.reason // ""')
        echo "  │     ${reason}"
      fi
      ;;
    security)
      if [[ "$status" != "skipped" ]]; then
        local high moderate low
        high=$(echo "$result_json" | jq '.vulnerabilities.high // 0')
        moderate=$(echo "$result_json" | jq '.vulnerabilities.moderate // 0')
        low=$(echo "$result_json" | jq '.vulnerabilities.low // 0')
        echo "  │     high: ${high}, moderate: ${moderate}, low: ${low}"
      fi
      ;;
  esac
}

# 메인
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    unit)           run_unit_test "$@" ;;
    e2e)            run_e2e_test "$@" ;;
    performance)    run_performance_test "$@" ;;
    security)       run_security_test "$@" ;;
    print-result)   print_test_result "$@" ;;
    help)
      echo "GonsAutoPilot Test Runners"
      echo "사용법: test-runners.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  unit [command] [coverage_threshold]     단위 테스트 실행"
      echo "  e2e [command]                           E2E 테스트 실행"
      echo "  performance [url] [min_score]           성능 테스트 (Lighthouse)"
      echo "  security [block_severity]               보안 테스트 (npm audit)"
      echo "  print-result <result_json>              결과 포맷팅 출력"
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
