#!/usr/bin/env bash
# GonsAutoPilot - 알림 유틸리티
# 파이프라인 이벤트를 사용자에게 알림

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 콘솔 알림 (기본)
notify_console() {
  local level="$1"   # info | warning | error | critical
  local title="$2"
  local message="$3"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  case "$level" in
    info)     local icon="ℹ️" ;;
    warning)  local icon="⚠️" ;;
    error)    local icon="❌" ;;
    critical) local icon="🚨" ;;
    success)  local icon="✅" ;;
    *)        local icon="📋" ;;
  esac

  echo ""
  echo "  ${icon} [${timestamp}] ${title}"
  echo "  ${message}"
  echo ""
}

# 파이프라인 성공 알림
notify_success() {
  local pipeline_id="$1"
  local duration="$2"
  notify_console "success" "Pipeline SUCCESS" "Pipeline #${pipeline_id} 완료 (${duration})"
}

# 파이프라인 실패 알림
notify_failure() {
  local pipeline_id="$1"
  local stage="$2"
  local reason="$3"
  notify_console "error" "Pipeline FAILED" "Pipeline #${pipeline_id} 실패 - Stage: ${stage}, 원인: ${reason}"
}

# 롤백 알림
notify_rollback() {
  local pipeline_id="$1"
  local service="$2"
  local from_tag="$3"
  local to_tag="$4"
  notify_console "warning" "AUTO ROLLBACK" "Pipeline #${pipeline_id} - ${service}: ${from_tag} → ${to_tag}"
}

# 긴급 알림 (에스컬레이션)
notify_escalation() {
  local pipeline_id="$1"
  local failures="$2"
  local message="$3"

  notify_console "critical" "ESCALATION - 파이프라인 잠금" \
    "Pipeline #${pipeline_id} - 연속 ${failures}회 실패. ${message}"

  # /notify-important 스킬 호출 (이메일 발송)
  echo "ESCALATION: 이메일 알림 필요 - /notify-important 호출 권장"
}

# 메인
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    console)     notify_console "$@" ;;
    success)     notify_success "$@" ;;
    failure)     notify_failure "$@" ;;
    rollback)    notify_rollback "$@" ;;
    escalation)  notify_escalation "$@" ;;
    help)
      echo "GonsAutoPilot Notify"
      echo "사용법: notify.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  console <level> <title> <message>  콘솔 알림"
      echo "  success <pipeline_id> <duration>   성공 알림"
      echo "  failure <pipeline_id> <stage> <reason>  실패 알림"
      echo "  rollback <pipeline_id> <service> <from> <to>  롤백 알림"
      echo "  escalation <pipeline_id> <failures> <message>  긴급 알림"
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
