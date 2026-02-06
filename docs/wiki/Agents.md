# Multi-Agent 시스템

GonsAutoPilot은 5개의 전문 Agent로 파이프라인을 분산 처리합니다.

## Agent 구성도

```
                        gap-orchestrator
                       (파이프라인 총괄)
                             │
            ┌────────────┬───┴───┬────────────┐
            │            │       │            │
      gap-test-agent  gap-build  gap-deploy  gap-monitor
       (테스트)       (빌드)     (배포)      (모니터링)
```

---

## gap-orchestrator — 파이프라인 총괄

파이프라인 전체 흐름을 제어하는 총괄 Agent입니다.

### 역할

- 코드 변경 분석 (Stage 1: ANALYZE)
- 파이프라인 실행 계획 수립
- 각 Agent에게 작업 위임
- 스테이지 간 전환 결정
- 실패 시 정책에 따른 조치 결정
- 최종 결과 보고

### 사전 검증

```
1. 파이프라인 잠금 상태 확인 → 잠금 시 중단 + 안내
2. gonsautopilot.yaml 설정 로드 및 검증
3. git 상태 확인 (clean working tree 권장)
```

### 의사결정 로직

#### 테스트 스킵 판단

| 변경 유형 | 판단 |
|-----------|------|
| frontend만 변경 | backend 테스트 스킵 |
| backend만 변경 | performance 테스트 스킵 |
| config만 변경 | 단위테스트 스킵, 빌드+배포만 |
| 변경 없음 | 전체 파이프라인 스킵 |

#### 실패 대응 판단

| 상황 | 대응 |
|------|------|
| CRITICAL 실패 | 즉시 중단 |
| WARNING 1~2개 | 기록 후 계속 |
| WARNING 누적 5개+ | CRITICAL로 승격 |
| 보안 취약점 high+ | 중단 |
| 보안 취약점 moderate 이하 | 경고만 |
| 연속 실패 3회 | 파이프라인 잠금 + 이메일 알림 |

### 사용하는 도구

| 도구 | 용도 |
|------|------|
| `lib/state-manager.sh` | 파이프라인 상태 관리 |
| `lib/config-parser.sh` | 설정 파일 로드 |
| `lib/change-analyzer.sh` | 변경 파일 분석 |
| `lib/notify.sh` | 알림 발송 |

### Agent 정의 (frontmatter)

```yaml
---
name: gap-orchestrator
description: 파이프라인 총괄 Agent - 흐름 제어, 상태 관리, 의사결정
model: inherit
tools: [Bash, Read, Glob, Grep, Task]
---
```

---

## gap-test-agent — 테스트

테스트 실행을 전담하는 Agent입니다.

### 역할

- Orchestrator로부터 필요한 테스트 목록을 수신
- 각 테스트를 병렬로 실행 (독립적인 Sub-agent로)
- 결과를 종합하여 Orchestrator에 보고

### 지원하는 테스트

| 종류 | 도구 | 판단 기준 | 실패 등급 |
|------|------|-----------|-----------|
| **Unit** | Jest, Vitest | 통과율 100%, 커버리지 threshold 이상 | CRITICAL |
| **E2E** | Playwright | 모든 시나리오 통과 | CRITICAL |
| **Performance** | Lighthouse CLI | 종합 점수 threshold 이상 | WARNING |
| **Security** | npm audit | high 이상 취약점 없음 | high+: CRITICAL, moderate-: WARNING |

### 결과 리포트

```json
{
  "overall": "passed",
  "tests": {
    "unit": { "status": "passed", "total": 23, "passed": 23, "coverage": 87 },
    "e2e": { "status": "passed", "scenarios": 8, "passed": 8 },
    "performance": { "status": "passed", "score": 82 },
    "security": { "status": "warning", "vulnerabilities": { "high": 0, "moderate": 2 } }
  },
  "warnings": ["npm audit: moderate 취약점 2건"]
}
```

### Agent 정의

```yaml
---
name: gap-test-agent
description: 테스트 전문 Agent - 단위/통합/E2E/성능/보안 테스트 병렬 실행
model: inherit
tools: [Bash, Read, Grep]
---
```

---

## gap-build-agent — 빌드

Docker 이미지 빌드를 전담하는 Agent입니다.

### 역할

- Orchestrator로부터 빌드 대상 목록 수신
- Docker 이미지 빌드
- 이미지 태깅 (git SHA 기반)
- 이전 이미지 보존 (롤백용)

### 빌드 프로세스

```
1. 빌드 대상 확인 (frontend, backend, 또는 둘 다)
2. 각 대상에 대해:
   a. Dockerfile 존재 확인
   b. docker build 실행
   c. 태그 생성: <project>-<target>:<git-sha>
   d. rollback-registry에 등록
3. 빌드 결과 보고
```

### 태깅 전략

| 전략 | 형식 | 예시 |
|------|------|------|
| `git-sha` | `<name>:<short-sha>` | `myapp-front:a1b2c3d` |
| `semver` | `<name>:v<major>.<minor>.<patch>` | `myapp-front:v1.2.3` |
| `timestamp` | `<name>:<YYYYMMDD-HHMMSS>` | `myapp-front:20260206-160000` |

### Agent 정의

```yaml
---
name: gap-build-agent
description: 빌드 전문 Agent - Docker 이미지 빌드 및 태깅
model: inherit
tools: [Bash, Read]
---
```

---

## gap-deploy-agent — 배포

운영서버 배포를 전담하는 Agent입니다.

### 역할

- Pre-deploy gate 체크 (5가지 조건)
- 운영서버에 SSH로 Docker Compose 배포
- Canary 배포 (새 컨테이너 먼저, 검증 후 교체)
- 배포 실패 시 즉시 롤백

### Pre-deploy Gate

| # | 체크 항목 | 확인 방법 |
|---|----------|-----------|
| 1 | CRITICAL 테스트 통과 | 파이프라인 상태에서 확인 |
| 2 | Docker 이미지 빌드 성공 | 이미지 존재 확인 |
| 3 | 이전 배포 이미지 백업 | rollback-registry에 등록 확인 |
| 4 | 운영서버 디스크 여유 > 2GB | SSH로 df 확인 |
| 5 | 운영서버 SSH 연결 정상 | 연결 테스트 |

### 카나리 배포 프로세스

```
1. docker-compose.prod.yml에서 이미지 태그 업데이트
2. 새 컨테이너 시작 (docker compose up -d --no-deps <service>)
3. 헬스체크 대기 (최대 60초, 3회 재시도)
4. 헬스체크 통과 → 배포 성공
5. 헬스체크 실패 → 이전 이미지로 복원 + 에러 보고
```

### Agent 정의

```yaml
---
name: gap-deploy-agent
description: 배포 전문 Agent - SSH 배포, Compose 업데이트, 카나리 배포
model: inherit
tools: [Bash, Read]
---
```

---

## gap-monitor-agent — 모니터링

배포 후 검증과 모니터링을 전담하는 Agent입니다.

### 역할

- 배포 직후 스모크 테스트 실행
- 30초 와치독 모니터링
- 이상 감지 시 자동 롤백 트리거
- 에스컬레이션 (연속 실패 시 알림)

### 스모크 테스트

```
1. GET /health → 200 OK 확인
2. 주요 페이지 접근 확인 (gonsautopilot.yaml에서 정의)
3. API 엔드포인트 기본 응답 확인
4. 응답 시간 측정 → threshold 초과 시 경고
```

### 와치독 감시 항목

| 항목 | 롤백 조건 |
|------|----------|
| HTTP 5xx 에러 | 1건이라도 발생 |
| 응답 시간 | 평소 대비 200% 초과 |
| 컨테이너 재시작 | crash loop 감지 |
| 에러 로그 | 급격한 증가 |

### Agent 정의

```yaml
---
name: gap-monitor-agent
description: 모니터링 Agent - 스모크 테스트, 와치독, 자동 롤백
model: inherit
tools: [Bash, Read]
---
```

---

## Agent 간 통신

Agent 간 통신은 Claude Code의 `Task` 도구를 통해 이루어집니다:

```
Orchestrator ──(Task)──→ Test Agent     : "unit, e2e 테스트 실행"
Test Agent   ──(결과)──→ Orchestrator   : JSON 리포트 반환
Orchestrator ──(Task)──→ Build Agent    : "frontend 빌드"
Build Agent  ──(결과)──→ Orchestrator   : 빌드 결과 + 태그
Orchestrator ──(Task)──→ Deploy Agent   : "이미지 태그 a1b2c3d 배포"
Deploy Agent ──(결과)──→ Orchestrator   : 배포 결과
Orchestrator ──(Task)──→ Monitor Agent  : "배포 검증 시작"
Monitor Agent──(결과)──→ Orchestrator   : 검증 결과
```

---

## 다음 단계

- [[셸 유틸리티|Shell-Utilities]] — lib 파일 상세
- [[파이프라인 흐름|Pipeline]] — 전체 파이프라인 설명
