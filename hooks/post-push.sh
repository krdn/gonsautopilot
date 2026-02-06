#!/usr/bin/env bash
# GonsAutoPilot - Post-push Hook
# 푸시 후 자동으로 파이프라인 트리거 여부를 판단
# 설치: ln -sf $(pwd)/plugin/hooks/post-push.sh .git/hooks/post-push
#
# 참고: Git에는 기본 post-push hook이 없으므로,
# post-receive (서버) 또는 수동 호출로 트리거합니다.
# Claude Code에서는 UserPromptSubmit hook으로 연동할 수 있습니다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
LIB="${PLUGIN_DIR}/lib"

# ──────────────────────────────────────────────
# 자동 트리거 판단
# ──────────────────────────────────────────────
should_auto_trigger() {
  local config_json="$1"

  # 자동 트리거 설정 확인
  local auto_trigger
  auto_trigger=$(echo "$config_json" | jq -r '.trigger.auto_on_push // true')

  if [[ "$auto_trigger" != "true" ]]; then
    echo "false"
    return
  fi

  # 파이프라인 잠금 확인
  local locked
  locked=$("${LIB}/state-manager.sh" pipeline-is-locked 2>/dev/null || echo "false")
  if [[ "$locked" == "true" ]]; then
    echo "locked"
    return
  fi

  # 푸시된 브랜치 확인
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  local trigger_branches
  trigger_branches=$(echo "$config_json" | jq -r '.trigger.branches // ["main","master"] | .[]' 2>/dev/null)

  local branch_match=false
  while IFS= read -r branch; do
    [[ "$current_branch" == "$branch" ]] && branch_match=true
  done <<< "$trigger_branches"

  if [[ "$branch_match" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# ──────────────────────────────────────────────
# 트리거 실행
# ──────────────────────────────────────────────
trigger_pipeline() {
  local mode="${1:-full}"

  echo ""
  echo "  GonsAutoPilot — Auto Trigger"
  echo "  ─────────────────────────────"
  echo "  브랜치: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "  커밋:   $(git rev-parse --short HEAD 2>/dev/null)"
  echo "  모드:   $mode"
  echo ""

  # 설정 로드
  local config
  config=$("${LIB}/config-parser.sh" load 2>/dev/null || echo "{}")

  local decision
  decision=$(should_auto_trigger "$config")

  case "$decision" in
    true)
      echo "  ✅ 자동 파이프라인 트리거됨"
      echo ""
      echo "  → /gonsautopilot 명령을 실행하세요."
      echo "    또는 자동 실행 설정: trigger.auto_execute: true"
      echo ""

      # 자동 실행 설정이 켜져 있으면 직접 실행 안내
      local auto_execute
      auto_execute=$(echo "$config" | jq -r '.trigger.auto_execute // false')
      if [[ "$auto_execute" == "true" ]]; then
        echo "  🚀 자동 실행 모드 활성화됨 — 파이프라인 시작"
        # 실제로는 Claude Code에서 /gonsautopilot 스킬을 호출하도록 안내
      fi
      ;;
    locked)
      echo "  🔒 파이프라인 잠금 상태 — 트리거 스킵"
      echo "  → /gonsautopilot:status 로 확인하세요."
      echo ""
      ;;
    false)
      echo "  ⏭️ 자동 트리거 조건 미충족 (브랜치 또는 설정)"
      echo ""
      ;;
  esac
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
main() {
  local cmd="${1:-trigger}"
  shift || true

  case "$cmd" in
    trigger)         trigger_pipeline "$@" ;;
    should-trigger)
      local config
      config=$("${LIB}/config-parser.sh" load 2>/dev/null || echo "{}")
      should_auto_trigger "$config"
      ;;
    help)
      echo "GonsAutoPilot Post-push Hook"
      echo "사용법: post-push.sh [command]"
      echo ""
      echo "명령어:"
      echo "  trigger [mode]       파이프라인 트리거 (기본)"
      echo "  should-trigger       트리거 여부만 확인"
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
