#!/usr/bin/env bash
# GonsAutoPilot - Deploy Agent 실행 엔진
# Pre-deploy gate → 이미지 전송 → 카나리 배포 → 결과 보고

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# 배포 실행 (메인 오케스트레이션)
# ──────────────────────────────────────────────
execute_deploy() {
  local pipeline_id="$1"
  local tags_json="$2"      # {"frontend":"app-front:abc","backend":"app-back:abc"}
  local config_json="$3"

  source "${SCRIPT_DIR}/docker-utils.sh"
  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true

  local start_time=$SECONDS

  local target_host target_user compose_file
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')
  compose_file=$(echo "$config_json" | jq -r '.deploy.compose_file // "docker-compose.prod.yml"')

  local health_url health_timeout health_retries
  health_url=$(echo "$config_json" | jq -r '.deploy.health_check.url // "http://localhost:3000/health"')
  health_timeout=$(echo "$config_json" | jq -r '.deploy.health_check.timeout // 60')
  health_retries=$(echo "$config_json" | jq -r '.deploy.health_check.retries // 3')

  local deploy_results="{}"
  local overall="success"
  local errors=()
  local deployed_services=()
  local rolled_back_services=()

  # 1단계: Pre-deploy gate
  echo "  ┌─ Pre-deploy Gate 체크" >&2
  local first_tag
  first_tag=$(echo "$tags_json" | jq -r 'to_entries[0].value // ""')

  local gate_result
  gate_result=$(pre_deploy_gate "$pipeline_id" "$first_tag" "$target_host" "$target_user" 2>/dev/null) || gate_result='{"overall":"failed"}'

  local gate_status
  gate_status=$(echo "$gate_result" | jq -r '.overall')

  # gate 결과 출력
  echo "$gate_result" | jq -r '.checks[]? | "  │ \(if .status == "passed" then "✅" elif .status == "warning" then "⚠️" else "❌" end) \(.check): \(.detail)"' >&2

  if [[ "$gate_status" == "failed" ]]; then
    echo "  └─ ❌ Pre-deploy Gate 실패. 배포 중단." >&2

    local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))
    jq -n \
      --argjson gate "$gate_result" \
      --argjson total_duration_ms "$total_duration_ms" \
      '{
        overall: "failed",
        stage: "pre_deploy_gate",
        gate: $gate,
        deploys: {},
        errors: ["Pre-deploy gate 체크 실패"],
        total_duration_ms: $total_duration_ms
      }'
    return 1
  fi

  echo "  └─ ✅ Pre-deploy Gate 통과" >&2
  echo "" >&2

  # 2단계: 이미지 전송
  echo "  ┌─ 이미지 전송" >&2

  local targets
  targets=$(echo "$tags_json" | jq -r 'keys[]')
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    local tag
    tag=$(echo "$tags_json" | jq -r --arg k "$target" '.[$k]')

    echo "  │ 전송 중: $tag → ${target_user}@${target_host}" >&2
    local transfer_result
    transfer_result=$(transfer_image "$tag" "$target_host" "$target_user" 2>/dev/null) || transfer_result='{"status":"failed"}'

    local transfer_status
    transfer_status=$(echo "$transfer_result" | jq -r '.status')

    if [[ "$transfer_status" == "success" ]]; then
      local duration
      duration=$(echo "$transfer_result" | jq -r '.duration_sec // "?"')
      echo "  │ ✅ $target 전송 완료 (${duration}s)" >&2
    else
      echo "  │ ❌ $target 전송 실패" >&2
      errors+=("${target}: 이미지 전송 실패")
      overall="failed"
    fi
  done <<< "$targets"

  echo "  └─ 이미지 전송 완료" >&2
  echo "" >&2

  # 전송 실패 시 중단
  if [[ "$overall" == "failed" ]]; then
    local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
    jq -n \
      --argjson gate "$gate_result" \
      --argjson errors "$errors_json" \
      --argjson total_duration_ms "$total_duration_ms" \
      '{
        overall: "failed",
        stage: "transfer",
        gate: $gate,
        deploys: {},
        errors: $errors,
        total_duration_ms: $total_duration_ms
      }'
    return 1
  fi

  # 3단계: 카나리 배포 (서비스별 순차 실행)
  echo "  ┌─ 카나리 배포" >&2

  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    local tag
    tag=$(echo "$tags_json" | jq -r --arg k "$target" '.[$k]')

    # 서비스 이름 (프로젝트 설정에서 매핑, 없으면 target 사용)
    local service_name
    service_name=$(echo "$config_json" | jq -r --arg t "$target" '.deploy.services[$t] // $t')

    echo "  │ 배포 중: $service_name → $tag" >&2

    # rollback-registry에 현재 이미지 기록 (배포 전)
    local current_tag
    current_tag=$(ssh "${target_user}@${target_host}" \
      "docker compose -f '$compose_file' images '$service_name' --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | head -1) || current_tag=""

    if [[ -n "$current_tag" ]]; then
      rollback_register "$service_name" "$current_tag" 2>/dev/null || true
    fi

    # 카나리 배포 실행
    local deploy_result
    deploy_result=$(canary_deploy \
      "$compose_file" "$service_name" "$tag" "$health_url" \
      "$target_host" "$target_user" "$health_timeout" "$health_retries" \
      2>/dev/null) || deploy_result='{"status":"failed","error":"카나리 배포 실패"}'

    local deploy_status
    deploy_status=$(echo "$deploy_result" | jq -r '.status')

    deploy_results=$(echo "$deploy_results" | jq \
      --arg key "$target" --argjson val "$deploy_result" \
      '. + {($key): $val}')

    if [[ "$deploy_status" == "success" ]]; then
      echo "  │ ✅ $service_name 배포 성공" >&2
      deployed_services+=("$service_name")

      # deployments.json에 기록
      deployment_record "$pipeline_id" "$service_name" "$tag" "success" 2>/dev/null || true
    else
      echo "  │ ❌ $service_name 배포 실패" >&2
      local err
      err=$(echo "$deploy_result" | jq -r '.error // "배포 실패"')
      errors+=("${target}: ${err}")
      overall="failed"

      local was_rolled_back
      was_rolled_back=$(echo "$deploy_result" | jq -r '.rolled_back // false')
      if [[ "$was_rolled_back" == "true" ]]; then
        rolled_back_services+=("$service_name")
        echo "  │ ↩️ $service_name 자동 롤백 완료" >&2
      fi

      # 하나 실패하면 이미 배포된 서비스도 롤백
      if [[ ${#deployed_services[@]} -gt 0 ]]; then
        echo "  │" >&2
        echo "  │ 이전 배포 서비스 롤백 시작..." >&2
        for svc in "${deployed_services[@]}"; do
          local old
          old=$(rollback_get_previous "$svc" 2>/dev/null || echo "")
          if [[ -n "$old" && "$old" != "null" ]]; then
            rollback_service "$compose_file" "$svc" "$old" "$target_host" "$target_user" 2>/dev/null || true
            echo "  │ ↩️ $svc → $old 롤백" >&2
            rolled_back_services+=("$svc")
          fi
        done
      fi

      break  # 실패 시 나머지 배포 중단
    fi
  done <<< "$targets"

  echo "  └─ 카나리 배포 완료" >&2

  local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))

  # errors를 JSON 배열로
  local errors_json
  if [[ ${#errors[@]} -gt 0 ]]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  else
    errors_json="[]"
  fi

  # rolled_back 서비스 목록
  local rolled_back_json
  if [[ ${#rolled_back_services[@]} -gt 0 ]]; then
    rolled_back_json=$(printf '%s\n' "${rolled_back_services[@]}" | jq -R . | jq -s .)
  else
    rolled_back_json="[]"
  fi

  local deployed_count=${#deployed_services[@]}
  local total_targets
  total_targets=$(echo "$tags_json" | jq 'keys | length')

  jq -n \
    --arg overall "$overall" \
    --argjson gate "$gate_result" \
    --argjson deploys "$deploy_results" \
    --argjson errors "$errors_json" \
    --argjson rolled_back "$rolled_back_json" \
    --argjson total_duration_ms "$total_duration_ms" \
    --argjson deployed "$deployed_count" \
    --argjson total "$total_targets" \
    '{
      overall: $overall,
      gate: $gate,
      deploys: $deploys,
      errors: $errors,
      rolled_back_services: $rolled_back,
      total_duration_ms: $total_duration_ms,
      summary: {
        total: $total,
        deployed: $deployed,
        failed: ($total - $deployed),
        rolled_back: ($rolled_back | length)
      }
    }'
}

# ──────────────────────────────────────────────
# 수동 롤백 실행
# ──────────────────────────────────────────────
execute_rollback() {
  local service="$1"
  local config_json="$2"

  source "${SCRIPT_DIR}/docker-utils.sh"
  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true

  local target_host target_user compose_file
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')
  compose_file=$(echo "$config_json" | jq -r '.deploy.compose_file // "docker-compose.prod.yml"')

  # 이전 이미지 조회
  local old_tag
  old_tag=$(rollback_get_previous "$service" 2>/dev/null || echo "")

  if [[ -z "$old_tag" || "$old_tag" == "null" ]]; then
    jq -n --arg service "$service" '{
      status: "failed",
      service: $service,
      error: "이전 배포 이미지를 찾을 수 없습니다"
    }'
    return 1
  fi

  echo "수동 롤백: $service → $old_tag" >&2

  local result
  result=$(rollback_service "$compose_file" "$service" "$old_tag" "$target_host" "$target_user" 2>/dev/null) || \
    result='{"status":"failed","error":"롤백 실패"}'

  echo "$result"
}

# ──────────────────────────────────────────────
# 배포 결과 출력
# ──────────────────────────────────────────────
print_deploy_report() {
  local report_json="$1"

  local overall total_ms
  overall=$(echo "$report_json" | jq -r '.overall')
  total_ms=$(echo "$report_json" | jq '.total_duration_ms')
  local total_s
  total_s=$(echo "scale=1; $total_ms / 1000" | bc 2>/dev/null || echo "?")

  echo ""
  echo "  ┌─ 배포 결과"

  # Gate 결과
  local gate_status
  gate_status=$(echo "$report_json" | jq -r '.gate.overall // "unknown"')
  echo "  │ Pre-deploy Gate: $([ "$gate_status" = "passed" ] && echo "✅ 통과" || echo "❌ 실패")"
  echo "  │"

  # 각 서비스 배포 결과
  local deploy_keys
  deploy_keys=$(echo "$report_json" | jq -r '.deploys | keys[]' 2>/dev/null)
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local result status
    result=$(echo "$report_json" | jq ".deploys.${key}")
    status=$(echo "$result" | jq -r '.status')

    case "$status" in
      success)
        local new_tag
        new_tag=$(echo "$result" | jq -r '.new_tag // "?"')
        echo "  │ ✅ ${key}: ${new_tag}"
        ;;
      failed)
        local err rolled
        err=$(echo "$result" | jq -r '.error // "배포 실패"')
        rolled=$(echo "$result" | jq -r '.rolled_back // false')
        echo "  │ ❌ ${key}: ${err}"
        [[ "$rolled" == "true" ]] && echo "  │    ↩️ 자동 롤백됨"
        ;;
    esac
  done <<< "$deploy_keys"

  echo "  │"

  # 에러
  local error_count
  error_count=$(echo "$report_json" | jq '.errors | length')
  if [[ "$error_count" -gt 0 ]]; then
    echo "  ├─ 에러 ($error_count건)"
    echo "$report_json" | jq -r '.errors[]' | while IFS= read -r e; do
      echo "  │  ❌ $e"
    done
    echo "  │"
  fi

  # 롤백된 서비스
  local rollback_count
  rollback_count=$(echo "$report_json" | jq '.rolled_back_services | length')
  if [[ "$rollback_count" -gt 0 ]]; then
    echo "  ├─ 롤백된 서비스 ($rollback_count건)"
    echo "$report_json" | jq -r '.rolled_back_services[]' | while IFS= read -r svc; do
      echo "  │  ↩️ $svc"
    done
    echo "  │"
  fi

  # 요약
  local s_total s_deployed s_failed
  s_total=$(echo "$report_json" | jq '.summary.total')
  s_deployed=$(echo "$report_json" | jq '.summary.deployed')
  s_failed=$(echo "$report_json" | jq '.summary.failed')

  local overall_icon
  case "$overall" in
    success) overall_icon="✅" ;;
    failed)  overall_icon="❌" ;;
    *)       overall_icon="❓" ;;
  esac

  echo "  └─ ${overall_icon} 전체: ${overall} — ${s_deployed}/${s_total} deployed"
  [[ "$s_failed" -gt 0 ]] && echo "     실패: ${s_failed}건"
  echo "     소요: ${total_s}s"
  echo ""
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    execute)        execute_deploy "$@" ;;
    rollback)       execute_rollback "$@" ;;
    print-report)   print_deploy_report "$@" ;;
    help)
      echo "GonsAutoPilot Deploy Executor"
      echo "사용법: deploy-executor.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  execute <pipeline_id> <tags_json> <config_json>  배포 실행"
      echo "  rollback <service> <config_json>                 수동 롤백"
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
