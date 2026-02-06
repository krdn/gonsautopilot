#!/usr/bin/env bash
# GonsAutoPilot - Build Agent 실행 엔진
# 설정을 기반으로 Docker 이미지 빌드, 태깅, rollback-registry 등록

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# 빌드 대상 결정
# 변경 분석 결과와 설정을 기반으로 빌드할 대상 결정
# ──────────────────────────────────────────────
determine_build_targets() {
  local changes_json="$1"
  local config_json="$2"

  local project_type
  project_type=$(echo "$config_json" | jq -r '.project.type // "fullstack"')

  local targets=()

  case "$project_type" in
    fullstack)
      local has_frontend has_backend
      has_frontend=$(echo "$changes_json" | jq '.categories.frontend | length > 0')
      has_backend=$(echo "$changes_json" | jq '.categories.backend | length > 0')
      has_shared=$(echo "$changes_json" | jq '.categories.shared | length > 0')
      has_config=$(echo "$changes_json" | jq '.categories.config | length > 0')

      # shared/config 변경은 둘 다 빌드
      if [[ "$has_shared" == "true" || "$has_config" == "true" ]]; then
        targets+=("frontend" "backend")
      else
        [[ "$has_frontend" == "true" ]] && targets+=("frontend")
        [[ "$has_backend" == "true" ]] && targets+=("backend")
      fi

      # 변경 없으면 둘 다 빌드 (안전)
      [[ ${#targets[@]} -eq 0 ]] && targets+=("frontend" "backend")
      ;;
    frontend)
      targets+=("frontend")
      ;;
    backend)
      targets+=("backend")
      ;;
  esac

  # 중복 제거
  local unique_targets=()
  for t in "${targets[@]}"; do
    local found=false
    for u in "${unique_targets[@]+"${unique_targets[@]}"}"; do
      [[ "$t" == "$u" ]] && found=true && break
    done
    [[ "$found" == "false" ]] && unique_targets+=("$t")
  done

  printf '%s\n' "${unique_targets[@]}" | jq -R . | jq -s .
}

# ──────────────────────────────────────────────
# 단일 대상 빌드
# ──────────────────────────────────────────────
_build_single_target() {
  local target="$1"         # frontend | backend
  local config_json="$2"
  local output_file="$3"

  source "${SCRIPT_DIR}/docker-utils.sh"
  source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true

  local log_file="${output_file}.log"

  local project_name dockerfile tag_strategy tag
  project_name=$(echo "$config_json" | jq -r '.project.name // "app"')
  tag_strategy=$(echo "$config_json" | jq -r '.build.tag_strategy // "git-sha"')

  # Dockerfile 경로
  dockerfile=$(echo "$config_json" | jq -r ".build.docker.${target} // \"./Dockerfile.${target}\"")

  # 태그 생성
  tag=$(generate_tag "$project_name" "$target" "$tag_strategy")

  # Dockerfile 존재 확인
  if [[ ! -f "$dockerfile" ]]; then
    jq -n \
      --arg target "$target" \
      --arg dockerfile "$dockerfile" \
      '{
        target: $target,
        status: "failed",
        error: ("Dockerfile이 존재하지 않습니다: " + $dockerfile)
      }' > "$output_file"
    return
  fi

  # 빌드 실행
  local build_result
  build_result=$(docker_build "$dockerfile" "." "$tag" 2>"$log_file") || true

  local build_status
  build_status=$(echo "$build_result" | jq -r '.status // "failed"')

  if [[ "$build_status" == "success" ]]; then
    # rollback-registry에 현재 이미지 등록
    rollback_register "$target" "$tag" 2>/dev/null || true

    jq -n \
      --arg target "$target" \
      --arg tag "$tag" \
      --arg dockerfile "$dockerfile" \
      --argjson build_info "$build_result" \
      '{
        target: $target,
        status: "success",
        tag: $tag,
        dockerfile: $dockerfile,
        image_id: $build_info.image_id,
        size_mb: $build_info.size_mb
      }' > "$output_file"
  else
    local error_msg
    error_msg=$(echo "$build_result" | jq -r '.error // "빌드 실패"')
    jq -n \
      --arg target "$target" \
      --arg tag "$tag" \
      --arg error "$error_msg" \
      '{
        target: $target,
        status: "failed",
        tag: $tag,
        error: $error
      }' > "$output_file"
  fi

  rm -f "$log_file"
}

# ──────────────────────────────────────────────
# 빌드 실행 (메인)
# 여러 대상을 병렬로 빌드하고 결과를 종합
# ──────────────────────────────────────────────
execute_build() {
  local targets_json="$1"   # ["frontend","backend"] 형태
  local config_json="$2"

  local start_time=$SECONDS
  local tmp_dir="/tmp/gap-build-$$"
  mkdir -p "$tmp_dir"

  # 빌드 대상 목록 파싱
  local targets=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && targets+=("$t")
  done < <(echo "$targets_json" | jq -r '.[]')

  if [[ ${#targets[@]} -eq 0 ]]; then
    jq -n '{
      overall: "skipped",
      builds: {},
      tags: {},
      errors: [],
      total_duration_ms: 0,
      summary: { total: 0, success: 0, failed: 0 }
    }'
    rm -rf "$tmp_dir"
    return
  fi

  # 각 대상 병렬 빌드
  local pids=()
  for target in "${targets[@]}"; do
    local output_file="${tmp_dir}/${target}.json"
    _build_single_target "$target" "$config_json" "$output_file" &
    pids+=($!)
  done

  # 완료 대기
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local total_duration_ms=$(( (SECONDS - start_time) * 1000 ))

  # 결과 수집
  local builds="{}"
  local tags="{}"
  local errors=()
  local count_success=0 count_failed=0

  for target in "${targets[@]}"; do
    local output_file="${tmp_dir}/${target}.json"

    if [[ -f "$output_file" ]] && jq empty "$output_file" 2>/dev/null; then
      local result
      result=$(jq '.' "$output_file")
      builds=$(echo "$builds" | jq --arg key "$target" --argjson val "$result" '. + {($key): $val}')

      local status
      status=$(echo "$result" | jq -r '.status')

      if [[ "$status" == "success" ]]; then
        count_success=$((count_success + 1))
        local tag
        tag=$(echo "$result" | jq -r '.tag')
        tags=$(echo "$tags" | jq --arg key "$target" --arg val "$tag" '. + {($key): $val}')
      else
        count_failed=$((count_failed + 1))
        local err
        err=$(echo "$result" | jq -r '.error // "빌드 실패"')
        errors+=("${target}: ${err}")
      fi
    else
      builds=$(echo "$builds" | jq --arg key "$target" \
        '. + {($key): { target: $key, status: "failed", error: "결과 파일 없음" }}')
      count_failed=$((count_failed + 1))
      errors+=("${target}: 결과 파일 없음")
    fi
  done

  rm -rf "$tmp_dir"

  # 전체 상태
  local overall="success"
  [[ $count_failed -gt 0 ]] && overall="failed"

  # errors를 JSON 배열로
  local errors_json
  if [[ ${#errors[@]} -gt 0 ]]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  else
    errors_json="[]"
  fi

  local total=${#targets[@]}

  jq -n \
    --arg overall "$overall" \
    --argjson builds "$builds" \
    --argjson tags "$tags" \
    --argjson errors "$errors_json" \
    --argjson total_duration_ms "$total_duration_ms" \
    --argjson total "$total" \
    --argjson success "$count_success" \
    --argjson failed "$count_failed" \
    '{
      overall: $overall,
      builds: $builds,
      tags: $tags,
      errors: $errors,
      total_duration_ms: $total_duration_ms,
      summary: {
        total: $total,
        success: $success,
        failed: $failed
      }
    }'
}

# ──────────────────────────────────────────────
# 빌드 결과 출력
# ──────────────────────────────────────────────
print_build_report() {
  local report_json="$1"

  local overall total_ms
  overall=$(echo "$report_json" | jq -r '.overall')
  total_ms=$(echo "$report_json" | jq '.total_duration_ms')
  local total_s
  total_s=$(echo "scale=1; $total_ms / 1000" | bc 2>/dev/null || echo "?")

  echo ""
  echo "  ┌─ 빌드 결과"

  # 각 빌드 결과
  local build_targets
  build_targets=$(echo "$report_json" | jq -r '.builds | keys[]')
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    local result status tag size_mb
    result=$(echo "$report_json" | jq ".builds.${target}")
    status=$(echo "$result" | jq -r '.status')
    tag=$(echo "$result" | jq -r '.tag // "N/A"')

    case "$status" in
      success)
        size_mb=$(echo "$result" | jq -r '.size_mb // "?"')
        echo "  │ ✅ ${target}: ${tag} (${size_mb}MB)"
        ;;
      failed)
        local err
        err=$(echo "$result" | jq -r '.error // "알 수 없는 오류"')
        echo "  │ ❌ ${target}: 실패 — ${err}"
        ;;
    esac
  done <<< "$build_targets"

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

  # 요약
  local s_total s_success s_failed
  s_total=$(echo "$report_json" | jq '.summary.total')
  s_success=$(echo "$report_json" | jq '.summary.success')
  s_failed=$(echo "$report_json" | jq '.summary.failed')

  local overall_icon
  case "$overall" in
    success) overall_icon="✅" ;;
    failed)  overall_icon="❌" ;;
    *)       overall_icon="❓" ;;
  esac

  echo "  └─ ${overall_icon} 전체: ${overall} — ${s_success}/${s_total} success"
  [[ "$s_failed" -gt 0 ]] && echo "     실패: ${s_failed}건"
  echo "     소요: ${total_s}s"
  echo ""
}

# ──────────────────────────────────────────────
# 이미지 전송 (운영서버로)
# ──────────────────────────────────────────────
transfer_built_images() {
  local tags_json="$1"      # {"frontend":"app-frontend:abc","backend":"app-backend:abc"}
  local config_json="$2"

  source "${SCRIPT_DIR}/docker-utils.sh"

  local target_host target_user
  target_host=$(echo "$config_json" | jq -r '.deploy.target // "192.168.0.5"')
  target_user=$(echo "$config_json" | jq -r '.deploy.user // "gon"')

  local results="{}"
  local all_success=true

  local targets
  targets=$(echo "$tags_json" | jq -r 'keys[]')
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    local tag
    tag=$(echo "$tags_json" | jq -r --arg k "$target" '.[$k]')

    echo "이미지 전송 중: $tag → ${target_user}@${target_host}" >&2
    local transfer_result
    transfer_result=$(transfer_image "$tag" "$target_host" "$target_user" 2>/dev/null) || true

    local status
    status=$(echo "$transfer_result" | jq -r '.status // "failed"')

    results=$(echo "$results" | jq \
      --arg key "$target" \
      --argjson val "$transfer_result" \
      '. + {($key): $val}')

    [[ "$status" != "success" ]] && all_success=false
  done <<< "$targets"

  local overall="success"
  [[ "$all_success" != "true" ]] && overall="failed"

  jq -n \
    --arg overall "$overall" \
    --argjson transfers "$results" \
    '{ overall: $overall, transfers: $transfers }'
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    determine-targets)  determine_build_targets "$@" ;;
    execute)            execute_build "$@" ;;
    print-report)       print_build_report "$@" ;;
    transfer)           transfer_built_images "$@" ;;
    help)
      echo "GonsAutoPilot Build Executor"
      echo "사용법: build-executor.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  determine-targets <changes_json> <config_json>  빌드 대상 결정"
      echo "  execute <targets_json> <config_json>            빌드 실행"
      echo "  print-report <report_json>                      결과 출력"
      echo "  transfer <tags_json> <config_json>              이미지 전송"
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
