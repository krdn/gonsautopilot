---
description: 이전 버전으로 즉시 롤백
argument-hint: [service-name]
allowed-tools: [Bash, Read]
---

# /gonsautopilot:rollback — 수동 롤백

이전 안정 버전으로 즉시 롤백합니다.

특정 서비스만 롤백: `/gonsautopilot:rollback frontend`

## 전체 실행 흐름

### Step 1: 설정 로드 및 롤백 대상 확인

```bash
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
LIB="${PLUGIN_DIR}/lib"

# 설정 로드
CONFIG=$(${LIB}/config-parser.sh load)

# 인자에서 서비스 이름 추출 (없으면 전체)
SERVICE="${1:-all}"
```

### Step 2: 롤백 가능한 서비스 목록 조회

```bash
# rollback-registry.json에서 이전 이미지 목록 조회
REGISTRY=$(cat ${PLUGIN_DIR}/state/rollback-registry.json)

echo "═══════════════════════════════════════════"
echo "  GonsAutoPilot — Rollback"
echo "═══════════════════════════════════════════"
echo ""
echo "  롤백 가능한 서비스:"
echo "$REGISTRY" | jq -r '.services | to_entries[] | "  - \(.key): \(.value.current) -> \(.value.previous)"'
echo ""
```

### Step 3: 롤백 실행

```bash
# 특정 서비스 롤백
if [ "$SERVICE" != "all" ]; then
  RESULT=$(${LIB}/deploy-executor.sh rollback "$SERVICE" "$CONFIG")
  echo "$RESULT" | jq '.'
else
  # 모든 서비스 순차 롤백
  SERVICES=$(echo "$REGISTRY" | jq -r '.services | keys[]')
  for SVC in $SERVICES; do
    echo "  롤백 중: $SVC"
    RESULT=$(${LIB}/deploy-executor.sh rollback "$SVC" "$CONFIG")
    STATUS=$(echo "$RESULT" | jq -r '.status')
    if [ "$STATUS" = "success" ]; then
      TAG=$(echo "$RESULT" | jq -r '.restored_tag')
      echo "  $SVC -> $TAG (성공)"
    else
      ERROR=$(echo "$RESULT" | jq -r '.error')
      echo "  $SVC 롤백 실패: $ERROR"
    fi
  done
fi
```

### Step 4: 헬스체크 및 결과

```bash
# 롤백 후 헬스체크
HEALTH_URL=$(echo "$CONFIG" | jq -r '.deploy.health_check.url // "http://localhost:3000/health"')
TIMEOUT=$(echo "$CONFIG" | jq -r '.deploy.health_check.timeout // 60')
RETRIES=$(echo "$CONFIG" | jq -r '.deploy.health_check.retries // 3')

${LIB}/docker-utils.sh health-check "$HEALTH_URL" "$TIMEOUT" "$RETRIES"

echo ""
echo "═══════════════════════════════════════════"
echo "  롤백 완료"
echo "═══════════════════════════════════════════"
```

## 사용하는 도구

- `lib/config-parser.sh` — 설정 파일 로드
- `lib/state-manager.sh` — rollback-registry 조회
- `lib/deploy-executor.sh` — 서비스 롤백 실행
- `lib/docker-utils.sh` — 헬스체크
