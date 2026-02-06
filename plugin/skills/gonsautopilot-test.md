# /gonsautopilot:test — 테스트 자동 실행

변경 분석 + 테스트 실행 + 리포트 출력을 수행합니다 (빌드/배포 없이).

## 실행 방법

사용자가 `/gonsautopilot:test`를 호출하면 이 스킬이 실행됩니다.

## 전체 실행 흐름

이 스킬은 다음 순서로 실행됩니다. 각 단계의 셸 스크립트를 순서대로 호출합니다.

### Step 1: 설정 로드 및 파이프라인 생성

```bash
PLUGIN_DIR="<gonsautopilot 플러그인 경로>/plugin"
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
${LIB}/state-manager.sh pipeline-create "$PID" "manual"
```

### Step 2: 변경 파일 분석 (Stage 1: ANALYZE)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "running"

# 변경 파일 분석
CHANGES=$(${LIB}/change-analyzer.sh analyze auto)
${LIB}/state-manager.sh pipeline-set-changes "$PID" "$CHANGES"

# 필요한 테스트 결정
PLAN=$(${LIB}/change-analyzer.sh determine-tests "$CHANGES")

# 파이프라인 스킵 여부 확인
SHOULD_SKIP=$(echo "$PLAN" | jq -r '.should_skip_pipeline')
if [ "$SHOULD_SKIP" = "true" ]; then
  echo "변경 파일이 없어 파이프라인을 건너뜁니다."
  ${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "skipped"
  ${LIB}/state-manager.sh pipeline-finish "$PID" "success"
  exit 0
fi

# 분석 요약 출력
${LIB}/change-analyzer.sh summary "$CHANGES" "$PLAN"

# 스킵 결정 기록
SKIPPED_TESTS=$(echo "$PLAN" | jq -r '.skipped_tests[]')
for t in $SKIPPED_TESTS; do
  REASON=$(echo "$PLAN" | jq -r ".skip_reasons.${t}")
  ${LIB}/state-manager.sh pipeline-add-decision "$PID" "test-agent" "skip_${t}" "$REASON"
done

${LIB}/state-manager.sh pipeline-update-stage "$PID" "analyze" "passed"
```

### Step 3: 테스트 실행 (Stage 2: TEST)

```bash
${LIB}/state-manager.sh pipeline-update-stage "$PID" "test" "running"

# 필요한 테스트 목록 추출
REQUIRED=$(echo "$PLAN" | jq '.required_tests')

# 테스트 병렬 실행
REPORT=$(${LIB}/test-executor.sh execute "$REQUIRED" "$CONFIG")

# 결과 출력
${LIB}/test-executor.sh print-report "$REPORT"

# 결과를 파이프라인에 저장
OVERALL=$(echo "$REPORT" | jq -r '.overall')
${LIB}/state-manager.sh pipeline-update-stage "$PID" "test" "$OVERALL" "$REPORT"

# 파이프라인 완료
if [ "$OVERALL" = "failed" ]; then
  ${LIB}/state-manager.sh pipeline-finish "$PID" "failed"
  echo "테스트 실패. 파이프라인을 중단합니다."
else
  ${LIB}/state-manager.sh pipeline-finish "$PID" "success"
fi
```

### Step 4: 최종 요약 출력

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Test Complete
═══════════════════════════════════════════════════════

  Pipeline: #<pipeline_id>
  결과:     <passed|failed|warning>
  소요:     <duration>

  테스트:   X passed, Y failed, Z warnings
  스킵:     <skipped tests and reasons>
═══════════════════════════════════════════════════════
```

## 사용하는 도구

- `lib/config-parser.sh` — 설정 파일 로드
- `lib/state-manager.sh` — 파이프라인 상태 관리
- `lib/change-analyzer.sh` — 변경 분석 + 테스트 결정
- `lib/test-executor.sh` — 테스트 병렬 실행 엔진
- `lib/test-runners.sh` — 개별 테스트 실행기
