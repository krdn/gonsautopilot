#!/usr/bin/env bash
# GonsAutoPilot - 헬스체크 유틸리티
# docker-utils.sh의 health_check를 직접 호출하는 래퍼

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/docker-utils.sh"

main() {
  health_check "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
