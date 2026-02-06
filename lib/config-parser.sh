#!/usr/bin/env bash
# GonsAutoPilot - gonsautopilot.yaml 파서
# YAML 설정을 읽어서 환경변수 또는 JSON으로 출력

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# yq 존재 확인 (YAML 파서)
_require_yq() {
  if ! command -v yq &>/dev/null; then
    echo "ERROR: yq가 설치되어 있지 않습니다. sudo snap install yq 또는 pip install yq" >&2
    exit 1
  fi
}

# 설정 파일 경로 탐색 (프로젝트 루트에서 찾기)
find_config() {
  local search_dir="${1:-.}"
  local config_names=("gonsautopilot.yaml" "gonsautopilot.yml" ".gonsautopilot.yaml")

  for name in "${config_names[@]}"; do
    if [[ -f "${search_dir}/${name}" ]]; then
      echo "${search_dir}/${name}"
      return 0
    fi
  done

  echo ""
  return 1
}

# 기본값이 포함된 전체 설정 로드
load_config() {
  _require_yq
  local config_file="${1:-}"

  if [[ -z "$config_file" ]]; then
    config_file=$(find_config "." 2>/dev/null || true)
  fi

  # 기본 설정
  local defaults
  defaults=$(cat <<'DEFAULTS_EOF'
{
  "project": {
    "name": "unnamed-project",
    "type": "fullstack"
  },
  "test": {
    "unit": {
      "command": "npm test",
      "coverage_threshold": 80,
      "enabled": true
    },
    "e2e": {
      "command": "npx playwright test",
      "browser": "chromium",
      "enabled": true
    },
    "performance": {
      "tool": "lighthouse",
      "min_score": 70,
      "enabled": true
    },
    "security": {
      "enabled": true,
      "audit": true
    }
  },
  "build": {
    "docker": {
      "frontend": "./Dockerfile.frontend",
      "backend": "./Dockerfile.backend"
    },
    "tag_strategy": "git-sha"
  },
  "deploy": {
    "target": "192.168.0.5",
    "method": "docker-compose",
    "compose_file": "docker-compose.prod.yml",
    "health_check": {
      "url": "http://localhost:3000/health",
      "timeout": 60,
      "retries": 3
    }
  },
  "safety": {
    "auto_rollback": true,
    "max_consecutive_failures": 3,
    "notify": {
      "email": true,
      "method": "/notify-important"
    }
  }
}
DEFAULTS_EOF
)

  # 설정 파일이 있으면 기본값과 병합
  if [[ -n "$config_file" && -f "$config_file" ]]; then
    local user_config
    user_config=$(yq -o=json "$config_file")
    # 사용자 설정이 기본값을 덮어씀 (깊은 병합)
    echo "$defaults" | jq --argjson user "$user_config" \
      'def deep_merge(a; b):
        a as $a | b as $b |
        if ($a | type) == "object" and ($b | type) == "object" then
          reduce ($b | keys[]) as $key ($a;
            .[$key] = deep_merge($a[$key]; $b[$key])
          )
        elif $b != null then $b
        else $a
        end;
      deep_merge(.; $user)'
  else
    echo "$defaults"
  fi
}

# 특정 키 값 조회
get_config_value() {
  _require_yq
  local config_file="$1"
  local key_path="$2"  # 예: ".deploy.target"

  load_config "$config_file" | jq -r "$key_path"
}

# 테스트 설정만 추출
get_test_config() {
  local config_file="${1:-}"
  load_config "$config_file" | jq '.test'
}

# 배포 설정만 추출
get_deploy_config() {
  local config_file="${1:-}"
  load_config "$config_file" | jq '.deploy'
}

# 안전장치 설정만 추출
get_safety_config() {
  local config_file="${1:-}"
  load_config "$config_file" | jq '.safety'
}

# 빌드 설정만 추출
get_build_config() {
  local config_file="${1:-}"
  load_config "$config_file" | jq '.build'
}

# 설정 유효성 검사
validate_config() {
  local config_file="${1:-}"
  local config
  config=$(load_config "$config_file")
  local errors=()

  # 프로젝트 이름 확인
  local name
  name=$(echo "$config" | jq -r '.project.name')
  if [[ "$name" == "unnamed-project" ]]; then
    errors+=("project.name이 설정되지 않았습니다")
  fi

  # 배포 타겟 확인
  local target
  target=$(echo "$config" | jq -r '.deploy.target')
  if [[ -z "$target" ]]; then
    errors+=("deploy.target이 설정되지 않았습니다")
  fi

  # 헬스체크 URL 확인
  local health_url
  health_url=$(echo "$config" | jq -r '.deploy.health_check.url')
  if [[ -z "$health_url" ]]; then
    errors+=("deploy.health_check.url이 설정되지 않았습니다")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    echo "설정 검증 실패:" >&2
    for err in "${errors[@]}"; do
      echo "  - $err" >&2
    done
    return 1
  fi

  echo "설정 검증 통과"
  return 0
}

# 메인
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    load)       load_config "$@" ;;
    get)        get_config_value "$@" ;;
    test)       get_test_config "$@" ;;
    deploy)     get_deploy_config "$@" ;;
    safety)     get_safety_config "$@" ;;
    build)      get_build_config "$@" ;;
    validate)   validate_config "$@" ;;
    find)       find_config "$@" ;;
    help)
      echo "GonsAutoPilot Config Parser"
      echo "사용법: config-parser.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  load [config_file]          전체 설정 로드 (기본값 병합)"
      echo "  get <config_file> <path>    특정 키 값 조회"
      echo "  test [config_file]          테스트 설정만 추출"
      echo "  deploy [config_file]        배포 설정만 추출"
      echo "  safety [config_file]        안전장치 설정만 추출"
      echo "  build [config_file]         빌드 설정만 추출"
      echo "  validate [config_file]      설정 유효성 검사"
      echo "  find [dir]                  설정 파일 경로 탐색"
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
