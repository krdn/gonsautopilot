---
description: 빌드+배포만 실행 (테스트 통과 전제)
allowed-tools: [Bash, Read, Glob, Grep, Task]
---

# /gonsautopilot:deploy — 빌드+배포 실행

빌드와 배포를 실행합니다 (최근 테스트 통과 전제).

## 사전 조건

- 최근 파이프라인의 테스트 스테이지가 passed 상태여야 합니다
- 파이프라인이 잠금 상태가 아니어야 합니다

## 전체 실행 흐름

### Step 1: 설정 로드 및 사전 조건 확인

```bash
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
LIB="${PLUGIN_DIR}/lib"

# 설정 로드
CONFIG=$(${LIB}/config-parser.sh load)

# 파이프라인 잠금 확인
LOCKED=$(${LIB}/state-manager.sh pipeline-is-locked)
if [ "$LOCKED" = "true" ]; then
  echo "파이프라인이 잠금 상태입니다. /gonsautopilot:status로 확인하세요."
  exit 1
fi

# 파이프라인 생성
PID=$(${LIB}/state-manager.sh pipeline-generate-id)
${LIB}/state-manager.sh pipeline-create "$PID" "deploy"
```

### Step 2: 변경 분석 + 빌드 대상 결정 (Stage 1: ANALYZE)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "running"

# 변경 파일 분석
CHANGES=$(${LIB}/change-analyzer.sh analyze auto)
${LIB}/state-manager.sh pipeline-set-changes "$PID" "$CHANGES"

# 빌드 대상 결정
TARGETS=$(${LIB}/build-executor.sh determine-targets "$CHANGES" "$CONFIG")

# 분석 요약 출력
${LIB}/change-analyzer.sh summary "$CHANGES"

${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "passed"
```

### Step 3: Docker 이미지 빌드 (Stage 2: BUILD)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "build" "running"

# 빌드 실행
BUILD_REPORT=$(${LIB}/build-executor.sh execute "$TARGETS" "$CONFIG")

# 빌드 결과 출력
${LIB}/build-executor.sh print-report "$BUILD_REPORT"

# 빌드 상태 확인
BUILD_STATUS=$(echo "$BUILD_REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "build" "$BUILD_STATUS" "$BUILD_REPORT"

if [ "$BUILD_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  echo "빌드 실패. 파이프라인을 중단합니다."
  exit 1
fi

# 빌드된 태그 추출
TAGS=$(echo "$BUILD_REPORT" | jq '.tags')
```

### Step 4: 배포 실행 (Stage 3: DEPLOY)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "deploy" "running"

# 배포 실행 (pre-deploy gate -> 이미지 전송 -> 카나리 배포)
DEPLOY_REPORT=$(${LIB}/deploy-executor.sh execute "$PID" "$TAGS" "$CONFIG")

# 배포 결과 출력
${LIB}/deploy-executor.sh print-report "$DEPLOY_REPORT"

# 배포 상태 확인
DEPLOY_STATUS=$(echo "$DEPLOY_REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "deploy" "$DEPLOY_STATUS" "$DEPLOY_REPORT"

if [ "$DEPLOY_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"

  # 연속 실패 확인
  CONSECUTIVE=$(${LIB}/state-manager.sh pipeline-get-consecutive-failures)
  MAX_FAILURES=$(echo "$CONFIG" | jq -r '.safety.max_consecutive_failures // 3')

  if [ "$CONSECUTIVE" -ge "$MAX_FAILURES" ]; then
    echo "연속 ${CONSECUTIVE}회 실패! 에스컬레이션 실행."
    ${LIB}/state-manager.sh pipeline-lock "연속 ${CONSECUTIVE}회 실패"
    ${LIB}/notify.sh escalation "배포 연속 ${CONSECUTIVE}회 실패"
  fi

  echo "배포 실패. 파이프라인을 중단합니다."
  exit 1
fi
```

### Step 5: 파이프라인 완료 및 최종 요약

```bash
${LIB}/state-manager.sh pipeline-finish "$PID" "success"
```

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Deploy Complete
═══════════════════════════════════════════════════════

  Pipeline: #<pipeline_id>
  결과:     <success|failed>
  소요:     <duration>

  빌드:     X targets built
  배포:     Y services deployed
  롤백:     Z services (if any)
═══════════════════════════════════════════════════════
```

## 사용하는 도구

- `lib/config-parser.sh` — 설정 파일 로드
- `lib/state-manager.sh` — 파이프라인 상태 관리
- `lib/change-analyzer.sh` — 변경 분석
- `lib/build-executor.sh` — Docker 이미지 빌드 엔진
- `lib/deploy-executor.sh` — 배포 실행 엔진 (pre-deploy gate + 카나리)
- `lib/notify.sh` — 알림 (에스컬레이션)
