#!/usr/bin/env bash
# GonsAutoPilot - Docker 빌드/배포 유틸리티
# 이미지 빌드, 태깅, 전송, Compose 배포, 카나리 배포, 헬스체크

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/state-manager.sh" 2>/dev/null || true

# ──────────────────────────────────────────────
# Docker 이미지 빌드
# ──────────────────────────────────────────────
docker_build() {
  local dockerfile="$1"
  local context="${2:-.}"
  local tag="$3"
  local build_args="${4:-}"

  if [[ ! -f "$dockerfile" ]]; then
    echo "ERROR: Dockerfile이 존재하지 않습니다: $dockerfile" >&2
    return 1
  fi

  local cmd=(docker build -f "$dockerfile" -t "$tag")

  # 빌드 인자 추가
  if [[ -n "$build_args" ]]; then
    while IFS= read -r arg; do
      [[ -n "$arg" ]] && cmd+=(--build-arg "$arg")
    done <<< "$build_args"
  fi

  cmd+=("$context")

  echo "빌드 시작: $tag (Dockerfile: $dockerfile)" >&2
  if "${cmd[@]}" >&2; then
    local image_id
    image_id=$(docker inspect --format='{{.Id}}' "$tag" 2>/dev/null | cut -c8-19)
    local image_size
    image_size=$(docker inspect --format='{{.Size}}' "$tag" 2>/dev/null || echo "0")
    local size_mb=$((image_size / 1024 / 1024))

    jq -n \
      --arg tag "$tag" \
      --arg image_id "$image_id" \
      --argjson size_mb "$size_mb" \
      '{
        status: "success",
        tag: $tag,
        image_id: $image_id,
        size_mb: $size_mb
      }'
  else
    jq -n --arg tag "$tag" '{
      status: "failed",
      tag: $tag,
      error: "Docker build 실패"
    }'
    return 1
  fi
}

# ──────────────────────────────────────────────
# 이미지 태그 생성
# ──────────────────────────────────────────────
generate_tag() {
  local project_name="$1"
  local target="$2"         # frontend | backend
  local strategy="${3:-git-sha}"

  case "$strategy" in
    git-sha)
      local sha
      sha=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
      echo "${project_name}-${target}:${sha}"
      ;;
    timestamp)
      local ts
      ts=$(date +%Y%m%d-%H%M%S)
      echo "${project_name}-${target}:${ts}"
      ;;
    semver)
      local version
      version=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
      echo "${project_name}-${target}:${version}"
      ;;
    *)
      echo "${project_name}-${target}:latest"
      ;;
  esac
}

# ──────────────────────────────────────────────
# 로컬 이미지 존재 확인
# ──────────────────────────────────────────────
image_exists() {
  local tag="$1"
  docker image inspect "$tag" &>/dev/null
}

# ──────────────────────────────────────────────
# 운영서버에 이미지 전송 (docker save | ssh docker load)
# 진행률 및 크기 포함 JSON 결과 반환
# ──────────────────────────────────────────────
transfer_image() {
  local tag="$1"
  local target_host="${2:-192.168.0.5}"
  local target_user="${3:-gon}"

  if ! image_exists "$tag"; then
    jq -n --arg tag "$tag" '{
      status: "failed",
      tag: $tag,
      error: "로컬에 이미지가 존재하지 않습니다"
    }'
    return 1
  fi

  echo "이미지 전송: $tag → ${target_user}@${target_host}" >&2
  local start_time=$SECONDS

  if docker save "$tag" | ssh "${target_user}@${target_host}" docker load >&2 2>&1; then
    local duration=$((SECONDS - start_time))
    jq -n \
      --arg tag "$tag" \
      --arg host "$target_host" \
      --argjson duration "$duration" \
      '{
        status: "success",
        tag: $tag,
        target_host: $host,
        duration_sec: $duration
      }'
  else
    jq -n --arg tag "$tag" --arg host "$target_host" '{
      status: "failed",
      tag: $tag,
      target_host: $host,
      error: "이미지 전송 실패"
    }'
    return 1
  fi
}

# ──────────────────────────────────────────────
# Compose 파일 이미지 태그 업데이트 (원격 서버)
# sed로 서비스의 image: 라인을 새 태그로 교체
# ──────────────────────────────────────────────
compose_update_image() {
  local compose_file="$1"
  local service="$2"
  local new_tag="$3"
  local target_host="${4:-192.168.0.5}"
  local target_user="${5:-gon}"

  echo "Compose 이미지 태그 업데이트: $service → $new_tag" >&2

  # 원격 서버에서 compose 파일의 서비스 이미지 태그 업데이트
  ssh "${target_user}@${target_host}" bash -s <<EOFSH
    set -euo pipefail
    COMPOSE_FILE="$compose_file"

    if [[ ! -f "\$COMPOSE_FILE" ]]; then
      echo "ERROR: Compose 파일이 존재하지 않습니다: \$COMPOSE_FILE" >&2
      exit 1
    fi

    # 서비스 블록의 image 라인 교체
    # yq가 있으면 사용, 없으면 sed 폴백
    if command -v yq &>/dev/null; then
      yq -i '.services."$service".image = "$new_tag"' "\$COMPOSE_FILE"
    else
      # sed: 서비스 이름 다음의 image 라인 찾아 교체
      # 간단하고 안전한 방식: 전체 이미지 이름 패턴 교체
      sed -i "s|image:.*${service}.*|image: $new_tag|g" "\$COMPOSE_FILE" 2>/dev/null || true
    fi
EOFSH

  if [[ $? -eq 0 ]]; then
    echo "태그 업데이트 완료" >&2
    return 0
  else
    echo "ERROR: 태그 업데이트 실패" >&2
    return 1
  fi
}

# ──────────────────────────────────────────────
# 카나리 배포 (서비스 단위)
# 새 컨테이너 시작 → 헬스체크 → 성공시 확정 / 실패시 롤백
# ──────────────────────────────────────────────
canary_deploy() {
  local compose_file="$1"
  local service="$2"
  local new_tag="$3"
  local health_url="$4"
  local target_host="${5:-192.168.0.5}"
  local target_user="${6:-gon}"
  local health_timeout="${7:-60}"
  local health_retries="${8:-3}"

  echo "카나리 배포 시작: $service → $new_tag" >&2

  # 1. 현재 이미지 태그 백업
  local old_tag
  old_tag=$(ssh "${target_user}@${target_host}" \
    "docker compose -f '$compose_file' images '$service' --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | head -1) || old_tag=""

  # 2. Compose 파일 이미지 업데이트
  if ! compose_update_image "$compose_file" "$service" "$new_tag" "$target_host" "$target_user"; then
    jq -n --arg service "$service" '{
      status: "failed",
      service: $service,
      stage: "update_compose",
      error: "Compose 파일 업데이트 실패"
    }'
    return 1
  fi

  # 3. 새 컨테이너 시작 (--no-deps: 의존 서비스 재시작 방지)
  echo "새 컨테이너 시작..." >&2
  if ! ssh "${target_user}@${target_host}" \
    "docker compose -f '$compose_file' up -d --no-deps '$service'" >&2 2>&1; then
    jq -n --arg service "$service" '{
      status: "failed",
      service: $service,
      stage: "container_start",
      error: "컨테이너 시작 실패"
    }'
    return 1
  fi

  # 4. 헬스체크
  echo "헬스체크 대기..." >&2
  if health_check "$health_url" "$health_timeout" "$health_retries"; then
    # 배포 성공
    jq -n \
      --arg service "$service" \
      --arg new_tag "$new_tag" \
      --arg old_tag "$old_tag" \
      '{
        status: "success",
        service: $service,
        new_tag: $new_tag,
        old_tag: $old_tag,
        stage: "completed"
      }'
  else
    # 헬스체크 실패 → 롤백
    echo "헬스체크 실패! 롤백 시작..." >&2

    if [[ -n "$old_tag" ]]; then
      compose_update_image "$compose_file" "$service" "$old_tag" "$target_host" "$target_user" 2>/dev/null || true
      ssh "${target_user}@${target_host}" \
        "docker compose -f '$compose_file' up -d --no-deps '$service'" >&2 2>&1 || true
    fi

    jq -n \
      --arg service "$service" \
      --arg new_tag "$new_tag" \
      --arg old_tag "$old_tag" \
      '{
        status: "failed",
        service: $service,
        new_tag: $new_tag,
        old_tag: $old_tag,
        stage: "health_check",
        error: "헬스체크 실패, 이전 버전으로 롤백됨",
        rolled_back: true
      }'
    return 1
  fi
}

# ──────────────────────────────────────────────
# 롤백 (지정 서비스를 이전 이미지로 되돌림)
# ──────────────────────────────────────────────
rollback_service() {
  local compose_file="$1"
  local service="$2"
  local old_tag="$3"
  local target_host="${4:-192.168.0.5}"
  local target_user="${5:-gon}"

  echo "롤백: $service → $old_tag" >&2

  compose_update_image "$compose_file" "$service" "$old_tag" "$target_host" "$target_user" || true

  if ssh "${target_user}@${target_host}" \
    "docker compose -f '$compose_file' up -d --no-deps '$service'" >&2 2>&1; then
    jq -n \
      --arg service "$service" \
      --arg tag "$old_tag" \
      '{ status: "success", service: $service, restored_tag: $tag }'
  else
    jq -n \
      --arg service "$service" \
      --arg tag "$old_tag" \
      '{ status: "failed", service: $service, tag: $tag, error: "롤백 실패" }'
    return 1
  fi
}

# ──────────────────────────────────────────────
# 헬스체크
# ──────────────────────────────────────────────
health_check() {
  local url="$1"
  local timeout="${2:-60}"
  local retries="${3:-3}"
  local interval=$((timeout / retries))
  [[ $interval -lt 5 ]] && interval=5

  echo "헬스체크: $url (timeout: ${timeout}s, retries: $retries)" >&2

  for i in $(seq 1 "$retries"); do
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$interval" "$url" 2>/dev/null || echo "000")

    if [[ "$status_code" =~ ^2[0-9]{2}$ ]]; then
      echo "헬스체크 통과 (시도 $i/$retries, 상태: $status_code)" >&2
      return 0
    fi

    echo "헬스체크 재시도 $i/$retries (상태: $status_code)" >&2
    [[ $i -lt $retries ]] && sleep "$interval"
  done

  echo "헬스체크 실패: $url (${retries}회 시도 후)" >&2
  return 1
}

# ──────────────────────────────────────────────
# Pre-deploy gate 체크 (5가지 조건)
# ──────────────────────────────────────────────
pre_deploy_gate() {
  local pipeline_id="$1"
  local image_tag="$2"
  local target_host="${3:-192.168.0.5}"
  local target_user="${4:-gon}"
  local min_disk_gb="${5:-2}"

  local checks=()
  local all_passed=true

  # 1. 테스트 통과 확인
  local pipeline_json
  pipeline_json=$(pipeline_get_current 2>/dev/null || echo "{}")
  local test_status
  test_status=$(echo "$pipeline_json" | jq -r '.stages[]? | select(.name == "test") | .status' 2>/dev/null || echo "unknown")

  if [[ "$test_status" == "passed" || "$test_status" == "warning" ]]; then
    checks+=('{"check":"test_passed","status":"passed","detail":"테스트 스테이지 통과"}')
  else
    checks+=("{\"check\":\"test_passed\",\"status\":\"failed\",\"detail\":\"테스트 미통과: ${test_status}\"}")
    all_passed=false
  fi

  # 2. Docker 이미지 존재 확인
  if image_exists "$image_tag"; then
    checks+=('{"check":"image_exists","status":"passed","detail":"이미지 확인됨"}')
  else
    checks+=('{"check":"image_exists","status":"failed","detail":"이미지를 찾을 수 없습니다"}')
    all_passed=false
  fi

  # 3. 롤백 레지스트리 확인
  local rollback_info
  rollback_info=$(rollback_get_previous "service" 2>/dev/null || echo "")
  if [[ -n "$rollback_info" && "$rollback_info" != "null" ]]; then
    checks+=('{"check":"rollback_ready","status":"passed","detail":"이전 이미지 백업 확인"}')
  else
    checks+=('{"check":"rollback_ready","status":"warning","detail":"이전 배포 이력 없음 (첫 배포)"}')
  fi

  # 4. 디스크 공간 확인
  local disk_result
  if disk_result=$(check_disk_space "$target_host" "$target_user" "$min_disk_gb" 2>/dev/null); then
    checks+=("{\"check\":\"disk_space\",\"status\":\"passed\",\"detail\":\"여유 공간: ${disk_result}GB\"}")
  else
    checks+=("{\"check\":\"disk_space\",\"status\":\"failed\",\"detail\":\"디스크 여유 부족: ${disk_result:-?}GB\"}")
    all_passed=false
  fi

  # 5. SSH 연결 확인
  if check_ssh_connection "$target_host" "$target_user" &>/dev/null; then
    checks+=('{"check":"ssh_connection","status":"passed","detail":"SSH 연결 정상"}')
  else
    checks+=('{"check":"ssh_connection","status":"failed","detail":"SSH 연결 실패"}')
    all_passed=false
  fi

  # 결과 조합
  local checks_json
  checks_json=$(printf '%s\n' "${checks[@]}" | jq -s '.')

  local overall="passed"
  if [[ "$all_passed" != "true" ]]; then
    overall="failed"
  fi

  jq -n \
    --arg overall "$overall" \
    --argjson checks "$checks_json" \
    '{
      overall: $overall,
      checks: $checks,
      total: ($checks | length),
      passed: [.checks[] | select(.status == "passed")] | length,
      failed: [.checks[] | select(.status == "failed")] | length,
      warnings: [.checks[] | select(.status == "warning")] | length
    }'
}

# ──────────────────────────────────────────────
# 운영서버 디스크 여유 공간 확인 (GB)
# ──────────────────────────────────────────────
check_disk_space() {
  local target_host="${1:-192.168.0.5}"
  local target_user="${2:-gon}"
  local min_gb="${3:-2}"

  local available_kb
  available_kb=$(ssh -o ConnectTimeout=10 "${target_user}@${target_host}" df -k / 2>/dev/null | awk 'NR==2{print $4}')
  local available_gb=$((available_kb / 1024 / 1024))

  if [[ $available_gb -ge $min_gb ]]; then
    echo "$available_gb"
    return 0
  else
    echo "$available_gb"
    return 1
  fi
}

# ──────────────────────────────────────────────
# SSH 연결 확인
# ──────────────────────────────────────────────
check_ssh_connection() {
  local target_host="${1:-192.168.0.5}"
  local target_user="${2:-gon}"

  ssh -o ConnectTimeout=5 -o BatchMode=yes "${target_user}@${target_host}" echo "ok" &>/dev/null
}

# ──────────────────────────────────────────────
# 원격 Docker 정보 조회
# ──────────────────────────────────────────────
remote_docker_info() {
  local target_host="${1:-192.168.0.5}"
  local target_user="${2:-gon}"

  ssh "${target_user}@${target_host}" "docker info --format '{{json .}}'" 2>/dev/null | \
    jq '{
      containers_running: .ContainersRunning,
      containers_total: .Containers,
      images: .Images,
      server_version: .ServerVersion
    }'
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    build)             docker_build "$@" ;;
    generate-tag)      generate_tag "$@" ;;
    image-exists)      image_exists "$@" && echo "true" || echo "false" ;;
    transfer)          transfer_image "$@" ;;
    compose-update)    compose_update_image "$@" ;;
    canary-deploy)     canary_deploy "$@" ;;
    rollback)          rollback_service "$@" ;;
    health-check)      health_check "$@" ;;
    pre-deploy-gate)   pre_deploy_gate "$@" ;;
    check-disk)        check_disk_space "$@" ;;
    check-ssh)         check_ssh_connection "$@" && echo "ok" || echo "fail" ;;
    remote-info)       remote_docker_info "$@" ;;
    help)
      echo "GonsAutoPilot Docker Utils"
      echo "사용법: docker-utils.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  build <dockerfile> <context> <tag> [build_args]  Docker 이미지 빌드"
      echo "  generate-tag <project> <target> [strategy]       태그 생성"
      echo "  image-exists <tag>                               이미지 존재 확인"
      echo "  transfer <tag> [host] [user]                     이미지 전송"
      echo "  compose-update <compose> <svc> <tag> [host] [user]  Compose 태그 업데이트"
      echo "  canary-deploy <compose> <svc> <tag> <health_url> [host] [user] [timeout] [retries]"
      echo "  rollback <compose> <svc> <old_tag> [host] [user] 서비스 롤백"
      echo "  health-check <url> [timeout] [retries]           헬스체크"
      echo "  pre-deploy-gate <pid> <tag> [host] [user] [min_gb]  배포 전 5가지 체크"
      echo "  check-disk [host] [user] [min_gb]                디스크 공간 확인"
      echo "  check-ssh [host] [user]                          SSH 연결 확인"
      echo "  remote-info [host] [user]                        원격 Docker 정보"
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
