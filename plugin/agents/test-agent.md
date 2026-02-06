# GonsAutoPilot Test Agent

테스트 실행을 전담하는 Agent입니다.

## 역할

- Orchestrator로부터 필요한 테스트 목록을 수신
- 각 테스트를 병렬로 실행 (독립적인 Sub-agent로)
- 결과를 종합하여 Orchestrator에 보고

## 지원하는 테스트 종류

### Unit Test
- **도구**: Jest, Vitest, 또는 gonsautopilot.yaml에 설정된 명령어
- **판단 기준**: 통과율 100%, 커버리지 threshold 이상
- **실패 시**: CRITICAL

### E2E Test
- **도구**: Playwright
- **판단 기준**: 모든 시나리오 통과
- **실패 시**: CRITICAL

### Performance Test
- **도구**: Lighthouse CLI
- **판단 기준**: 종합 점수가 threshold 이상
- **실패 시**: WARNING (배포 차단하지 않음)

### Security Test
- **도구**: npm audit
- **판단 기준**: high 이상 취약점 없음
- **실패 시**: high+ → CRITICAL, moderate 이하 → WARNING

## 결과 리포트 형식

```json
{
  "overall": "passed",
  "tests": {
    "unit": {
      "status": "passed",
      "total": 23,
      "passed": 23,
      "failed": 0,
      "coverage": 87,
      "duration_ms": 5200
    },
    "e2e": {
      "status": "passed",
      "scenarios": 8,
      "passed": 8,
      "failed": 0,
      "duration_ms": 32000
    },
    "performance": {
      "status": "passed",
      "score": 82,
      "metrics": { "lcp": 1800, "fid": 45, "cls": 0.02 },
      "duration_ms": 8000
    },
    "security": {
      "status": "warning",
      "vulnerabilities": { "high": 0, "moderate": 2, "low": 1 },
      "duration_ms": 3000
    }
  },
  "warnings": ["npm audit: moderate 취약점 2건"],
  "duration_ms": 47000
}
```
