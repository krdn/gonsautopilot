#!/usr/bin/env bash
# GonsAutoPilot - Pre-commit Hook
# 커밋 전 기본 품질 체크 수행
# 설치: ln -sf $(pwd)/plugin/hooks/pre-commit.sh .git/hooks/pre-commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
LIB="${PLUGIN_DIR}/lib"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo ""
echo "  GonsAutoPilot — Pre-commit Check"
echo "  ─────────────────────────────────"

ERRORS=0

# ──────────────────────────────────────────────
# 1. 스테이징된 파일에서 민감 정보 검사
# ──────────────────────────────────────────────
echo -n "  민감 정보 검사... "

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || echo "")
SENSITIVE_PATTERNS=(
  'password\s*[:=]'
  'api[_-]?key\s*[:=]'
  'secret\s*[:=]'
  'AWS_ACCESS_KEY'
  'AWS_SECRET_KEY'
  'PRIVATE_KEY'
)

SENSITIVE_FOUND=false
for file in $STAGED_FILES; do
  [[ ! -f "$file" ]] && continue
  # 바이너리 파일 제외
  file -b --mime-encoding "$file" 2>/dev/null | grep -q "binary" && continue

  for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
      if [[ "$SENSITIVE_FOUND" == "false" ]]; then
        echo -e "${RED}발견됨${NC}"
        SENSITIVE_FOUND=true
      fi
      echo -e "    ${RED}⚠️ $file: 민감 정보 패턴 발견 ($pattern)${NC}"
      ERRORS=$((ERRORS + 1))
    fi
  done
done

if [[ "$SENSITIVE_FOUND" == "false" ]]; then
  echo -e "${GREEN}OK${NC}"
fi

# ──────────────────────────────────────────────
# 2. .env 파일 커밋 방지
# ──────────────────────────────────────────────
echo -n "  .env 파일 체크... "

ENV_FILES=$(echo "$STAGED_FILES" | grep -E '\.env(\.|$)' || true)
if [[ -n "$ENV_FILES" ]]; then
  echo -e "${RED}발견됨${NC}"
  for f in $ENV_FILES; do
    echo -e "    ${RED}⚠️ $f: .env 파일은 커밋할 수 없습니다${NC}"
  done
  ERRORS=$((ERRORS + 1))
else
  echo -e "${GREEN}OK${NC}"
fi

# ──────────────────────────────────────────────
# 3. 대용량 파일 체크 (10MB 이상)
# ──────────────────────────────────────────────
echo -n "  대용량 파일 체크... "

LARGE_FOUND=false
for file in $STAGED_FILES; do
  [[ ! -f "$file" ]] && continue
  SIZE=$(stat -c%s "$file" 2>/dev/null || echo "0")
  if [[ $SIZE -gt 10485760 ]]; then  # 10MB
    if [[ "$LARGE_FOUND" == "false" ]]; then
      echo -e "${YELLOW}경고${NC}"
      LARGE_FOUND=true
    fi
    SIZE_MB=$((SIZE / 1024 / 1024))
    echo -e "    ${YELLOW}⚠️ $file: ${SIZE_MB}MB (10MB 초과)${NC}"
  fi
done

if [[ "$LARGE_FOUND" == "false" ]]; then
  echo -e "${GREEN}OK${NC}"
fi

# ──────────────────────────────────────────────
# 4. JSON/YAML 문법 검사 (스테이징된 파일)
# ──────────────────────────────────────────────
echo -n "  설정 파일 문법 검사... "

SYNTAX_ERROR=false
for file in $STAGED_FILES; do
  [[ ! -f "$file" ]] && continue

  case "$file" in
    *.json)
      if ! jq empty "$file" 2>/dev/null; then
        if [[ "$SYNTAX_ERROR" == "false" ]]; then
          echo -e "${RED}오류${NC}"
          SYNTAX_ERROR=true
        fi
        echo -e "    ${RED}❌ $file: JSON 문법 오류${NC}"
        ERRORS=$((ERRORS + 1))
      fi
      ;;
    *.yaml|*.yml)
      if command -v yq &>/dev/null; then
        if ! yq eval '.' "$file" >/dev/null 2>&1; then
          if [[ "$SYNTAX_ERROR" == "false" ]]; then
            echo -e "${RED}오류${NC}"
            SYNTAX_ERROR=true
          fi
          echo -e "    ${RED}❌ $file: YAML 문법 오류${NC}"
          ERRORS=$((ERRORS + 1))
        fi
      fi
      ;;
  esac
done

if [[ "$SYNTAX_ERROR" == "false" ]]; then
  echo -e "${GREEN}OK${NC}"
fi

# ──────────────────────────────────────────────
# 결과
# ──────────────────────────────────────────────
echo "  ─────────────────────────────────"

if [[ $ERRORS -gt 0 ]]; then
  echo -e "  ${RED}❌ ${ERRORS}건의 문제 발견. 커밋이 차단되었습니다.${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}✅ 모든 검사 통과${NC}"
  echo ""
  exit 0
fi
