# 상태 조회

`/gonsautopilot:status` 명령어로 파이프라인 상태를 조회합니다.

## 사용법

```
/gonsautopilot:status              # 현재 파이프라인 상태
/gonsautopilot:status deployments  # 배포 이력 (최근 10건)
/gonsautopilot:status stats        # 성공률 통계
/gonsautopilot:status full         # 전체 리포트
```

---

## 현재 파이프라인 상태

```
/gonsautopilot:status
```

### 출력 예시

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline Status
═══════════════════════════════════════════════════════

  Pipeline:  #20260206-160000-a1b2c3d
  상태:      success
  트리거:    manual
  시작:      2026-02-06T16:00:00+09:00
  완료:      2026-02-06T16:05:30+09:00

  ┌─ Stages
  │  analyze:   passed
  │  test:      passed
  │  build:     passed
  │  deploy:    passed
  │  verify:    passed
  │
  ├─ Changes
  │  frontend:  3 files
  │  backend:   0 files
  │
  └─ Decisions
     skip_backend_test: 백엔드 파일 변경 없음

═══════════════════════════════════════════════════════
```

---

## 배포 이력

```
/gonsautopilot:status deployments
```

최근 10건의 배포 이력을 시간순으로 보여줍니다.

### 출력 예시

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Deployment History (최근 10건)
═══════════════════════════════════════════════════════

  #1  2026-02-06 16:05  success  frontend:a1b2c3d
  #2  2026-02-05 14:30  success  frontend:x9y8z7w backend:x9y8z7w
  #3  2026-02-04 11:20  failed   backend:m3n4o5p  (rollback)
  ...

═══════════════════════════════════════════════════════
```

---

## 성공률 통계

```
/gonsautopilot:status stats
```

### 출력 예시

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Statistics
═══════════════════════════════════════════════════════

  총 실행:     12
  성공:        10 (83.3%)
  실패:        2 (16.7%)
  연속 실패:   0

═══════════════════════════════════════════════════════
```

---

## 전체 리포트

```
/gonsautopilot:status full
```

위 세 가지를 모두 합친 종합 리포트를 출력합니다.

---

## 잠금 상태

파이프라인이 잠금된 경우 특별한 메시지가 표시됩니다:

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline Status
═══════════════════════════════════════════════════════

  상태: LOCKED
  잠금 이유: 연속 3회 파이프라인 실패
  마지막 실패: 2026-02-06T16:05:30+09:00

  → 문제 해결 후 잠금을 해제하세요:
    lib/state-manager.sh unlock-pipeline

═══════════════════════════════════════════════════════
```

---

## 상태 데이터

상태 정보는 `state/pipeline.json`에 저장됩니다:

```json
{
  "pipelines": [...],
  "current": "20260206-160000-a1b2c3d",
  "stats": {
    "total_runs": 12,
    "success_count": 10,
    "failure_count": 2,
    "consecutive_failures": 0
  }
}
```

---

## 다음 단계

- [[롤백|Rollback]] — 수동 롤백
- [[슬래시 명령어|Commands]] — 모든 명령어 레퍼런스
