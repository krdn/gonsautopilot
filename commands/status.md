---
description: 파이프라인 상태/배포이력/통계 조회
argument-hint: [deployments|stats|full]
allowed-tools: [Bash, Read]
---

# /gonsautopilot:status — 파이프라인 상태 조회

현재 또는 마지막 파이프라인의 상태를 보여줍니다.

## 옵션

- `/gonsautopilot:status` — 현재 파이프라인 상태 (기본)
- `/gonsautopilot:status deployments` — 배포 이력
- `/gonsautopilot:status stats` — 성공률 통계
- `/gonsautopilot:status full` — 전체 리포트

## 전체 실행 흐름

### Step 1: 상태 조회

```bash
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
LIB="${PLUGIN_DIR}/lib"

# 옵션 파싱
MODE="${1:-status}"

case "$MODE" in
  status|"")
    ${LIB}/status-reporter.sh status
    ;;
  deployments)
    ${LIB}/status-reporter.sh deployments "${2:-10}"
    ;;
  stats|statistics)
    ${LIB}/status-reporter.sh statistics
    ;;
  full)
    ${LIB}/status-reporter.sh full
    ;;
  rollback)
    ${LIB}/status-reporter.sh rollback-status
    ;;
esac
```

## 출력 형식

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline Status
═══════════════════════════════════════════════════════

  Pipeline:  #<pipeline_id>
  상태:      <running|success|failed>
  트리거:    <auto|manual>
  시작:      <started_at>
  완료:      <finished_at>

  ┌─ Stages
  │  analyze:  passed
  │  test:     passed
  │  build:    passed
  │  deploy:   running
  │  verify:   pending
  │
  ├─ Changes
  │  frontend: 3 files
  │  backend:  0 files
  │
  ├─ Decisions
  │  - skip_backend_test: 백엔드 파일 변경 없음
  │
  └─ Stats
     총 실행: 12 | 성공: 10 | 실패: 2 | 연속 실패: 0

═══════════════════════════════════════════════════════
```

## 잠금 상태 표시

파이프라인이 잠긴 경우 추가로 표시합니다:

```
  파이프라인 잠금 상태
     이유: 연속 3회 배포 실패
     잠금 시각: 2026-02-06T15:30:00+09:00
     해제: /gonsautopilot:unlock 실행
```

## 사용하는 도구

- `lib/status-reporter.sh` — 상태 포맷팅, 배포 이력, 통계
