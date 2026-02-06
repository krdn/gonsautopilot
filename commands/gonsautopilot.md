---
description: 전체 파이프라인 실행 (분석→테스트→빌드→배포→검증)
argument-hint: [--dry-run] [--skip-deploy]
allowed-tools: [Bash, Read, Glob, Grep, Task]
---

# /gonsautopilot — 전체 파이프라인 실행

전체 자동 파이프라인을 실행합니다: 분석 → 테스트 → 빌드 → 배포 → 검증

## 옵션

- `/gonsautopilot` — 전체 파이프라인 (기본)
- `/gonsautopilot --dry-run` — 분석까지만 실행 (테스트/배포 없이)
- `/gonsautopilot --skip-deploy` — 테스트까지만 (배포 건너뜀)

## 사전 조건

- 프로젝트 루트에 `gonsautopilot.yaml` 설정 파일이 존재해야 합니다
- git 저장소여야 합니다
- 파이프라인이 잠금 상태가 아니어야 합니다

## 전체 실행 흐름

### Step 1: 설정 로드 및 파이프라인 생성

```bash
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
LIB="${PLUGIN_DIR}/lib"

# 옵션 파싱
DRY_RUN=false
SKIP_DEPLOY=false
for arg in $ARGUMENTS; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --skip-deploy) SKIP_DEPLOY=true ;;
  esac
done

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
${LIB}/state-manager.sh pipeline-create "$PID" "full"

echo "═══════════════════════════════════════════════════════"
echo "  GonsAutoPilot — Pipeline #${PID}"
echo "═══════════════════════════════════════════════════════"
```

### Step 2: 변경 분석 (Stage 1: ANALYZE)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "running"

# 변경 파일 분석
CHANGES=$(${LIB}/change-analyzer.sh analyze auto)
${LIB}/state-manager.sh pipeline-set-changes "$PID" "$CHANGES"

# 필요한 테스트 결정
PLAN=$(${LIB}/change-analyzer.sh determine-tests "$CHANGES")

# 빌드 대상 결정
TARGETS=$(${LIB}/build-executor.sh determine-targets "$CHANGES" "$CONFIG")

# 파이프라인 스킵 여부 확인
SHOULD_SKIP=$(echo "$PLAN" | jq -r '.should_skip_pipeline')
if [ "$SHOULD_SKIP" = "true" ]; then
  echo "  변경 파일이 없어 파이프라인을 건너뜁니다."
  ${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "skipped"
  ${LIB}/state-manager.sh pipeline-finish "$PID" "success"
  exit 0
fi

# 분석 요약 출력
${LIB}/change-analyzer.sh summary "$CHANGES" "$PLAN"

${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "passed"

# --dry-run이면 여기서 종료
if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "  [dry-run] 분석 완료. 테스트/빌드/배포는 건너뜁니다."
  ${LIB}/state-manager.sh pipeline-finish "$PID" "success"
  exit 0
fi
```

### Step 3: 테스트 실행 (Stage 2: TEST)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "test" "running"

# 필요한 테스트 목록
REQUIRED=$(echo "$PLAN" | jq '.required_tests')

# 테스트 병렬 실행
REPORT=$(${LIB}/test-executor.sh execute "$REQUIRED" "$CONFIG")

# 결과 출력
${LIB}/test-executor.sh print-report "$REPORT"

# 결과를 파이프라인에 저장
TEST_STATUS=$(echo "$REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "test" "$TEST_STATUS" "$REPORT"

if [ "$TEST_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  ${LIB}/notify.sh failure "$PID" "test" "테스트 실패"
  echo "  테스트 실패. 파이프라인을 중단합니다."
  exit 1
fi

# --skip-deploy면 여기서 종료
if [ "$SKIP_DEPLOY" = "true" ]; then
  echo ""
  echo "  [skip-deploy] 테스트 완료. 빌드/배포는 건너뜁니다."
  ${LIB}/state-manager.sh pipeline-finish "$PID" "success"
  exit 0
fi
```

### Step 4: 빌드 + 배포 (Stage 3: BUILD, Stage 4: DEPLOY)

```bash
# ── BUILD ──
${LIB}/state-manager.sh pipeline-update-stage "$PID" "build" "running"

BUILD_REPORT=$(${LIB}/build-executor.sh execute "$TARGETS" "$CONFIG")
${LIB}/build-executor.sh print-report "$BUILD_REPORT"

BUILD_STATUS=$(echo "$BUILD_REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "build" "$BUILD_STATUS" "$BUILD_REPORT"

if [ "$BUILD_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  ${LIB}/notify.sh failure "$PID" "build" "빌드 실패"
  echo "  빌드 실패. 파이프라인을 중단합니다."
  exit 1
fi

TAGS=$(echo "$BUILD_REPORT" | jq '.tags')

# ── DEPLOY ──
${LIB}/state-manager.sh pipeline-update-stage "$PID" "deploy" "running"

DEPLOY_REPORT=$(${LIB}/deploy-executor.sh execute "$PID" "$TAGS" "$CONFIG")
${LIB}/deploy-executor.sh print-report "$DEPLOY_REPORT"

DEPLOY_STATUS=$(echo "$DEPLOY_REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "deploy" "$DEPLOY_STATUS" "$DEPLOY_REPORT"

if [ "$DEPLOY_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  ${LIB}/notify.sh failure "$PID" "deploy" "배포 실패"
  echo "  배포 실패. 파이프라인을 중단합니다."
  exit 1
fi
```

### Step 5: 배포 후 검증 (Stage 5: VERIFY)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "verify" "running"

VERIFY_REPORT=$(${LIB}/monitor-executor.sh verify "$PID" "$TAGS" "$CONFIG")
${LIB}/monitor-executor.sh print-report "$VERIFY_REPORT"

VERIFY_STATUS=$(echo "$VERIFY_REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "verify" "$VERIFY_STATUS" "$VERIFY_REPORT"

if [ "$VERIFY_STATUS" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  ${LIB}/notify.sh failure "$PID" "verify" "배포 후 검증 실패 (자동 롤백됨)"
  exit 1
fi

# 파이프라인 성공
${LIB}/state-manager.sh pipeline-finish "$PID" "success"
${LIB}/notify.sh success "$PID" "전체 파이프라인 완료"
```

### Step 6: 최종 요약

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline Complete
═══════════════════════════════════════════════════════

  Pipeline: #<pipeline_id>
  결과:     <success|failed>
  소요:     <total_duration>

  ANALYZE:  <passed|skipped>
  TEST:     X passed, Y failed, Z warnings
  BUILD:    N targets built
  DEPLOY:   M services deployed
  VERIFY:   스모크 <status>, 와치독 <status>

  스킵:     <skipped tests and reasons>
═══════════════════════════════════════════════════════
```

## 사용하는 도구

- `lib/config-parser.sh` — 설정 파일 로드
- `lib/state-manager.sh` — 파이프라인 상태 관리
- `lib/change-analyzer.sh` — 변경 분석 + 테스트 결정
- `lib/test-executor.sh` — 테스트 병렬 실행 엔진
- `lib/build-executor.sh` — Docker 이미지 빌드 엔진
- `lib/deploy-executor.sh` — 배포 실행 엔진
- `lib/monitor-executor.sh` — 배포 후 검증 (스모크 + 와치독)
- `lib/notify.sh` — 알림
