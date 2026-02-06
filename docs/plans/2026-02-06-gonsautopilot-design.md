# GonsAutoPilot - 설계 문서

> Claude Code 플러그인 기반 풀스택 자동 테스트/배포 시스템
> 작성일: 2026-02-06

---

## 1. 시스템 아키텍처 개요

**프로젝트명: GonsAutoPilot** — Claude Code 플러그인 기반 풀스택 자동 테스트/배포 시스템

```
┌─────────────────────────────────────────────────┐
│              Claude Code Plugin                  │
│  ┌───────────────────────────────────────────┐  │
│  │         Orchestrator Agent (총괄)          │  │
│  │  - 파이프라인 상태 관리                      │  │
│  │  - Agent 스케줄링 & 의사결정                  │  │
│  │  - 실패 복구 & 롤백 정책                     │  │
│  └──────────┬────────────────────────────────┘  │
│             │                                    │
│  ┌──────────┼────────────────────────────────┐  │
│  │          ▼                                 │  │
│  │  ┌──────────┐ ┌──────────┐ ┌───────────┐ │  │
│  │  │  Test    │ │  Build   │ │  Deploy   │ │  │
│  │  │  Agent   │ │  Agent   │ │  Agent    │ │  │
│  │  └────┬─────┘ └──────────┘ └───────────┘ │  │
│  │       │                                    │  │
│  │  ┌────┴──────────────────────────────┐    │  │
│  │  │  Sub-Agents (병렬 실행)             │    │  │
│  │  │  - Unit Test Runner               │    │  │
│  │  │  - E2E Runner (Playwright)        │    │  │
│  │  │  - Performance Analyzer           │    │  │
│  │  │  - Security Scanner               │    │  │
│  │  └───────────────────────────────────┘    │  │
│  │                                            │  │
│  │  ┌──────────┐ ┌──────────────────────┐    │  │
│  │  │ Monitor  │ │  State Store         │    │  │
│  │  │ Agent    │ │  (pipeline.json)     │    │  │
│  │  └──────────┘ └──────────────────────┘    │  │
│  └────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
  ┌──────────────┐         ┌──────────────────┐
  │ 로컬 개발환경   │         │ 운영서버           │
  │ 192.168.0.8   │         │ 192.168.0.5      │
  │ (테스트 실행)   │         │ (Docker 배포)     │
  └──────────────┘         └──────────────────┘
```

**핵심 설계 원칙:**
- **독립성**: 각 Agent는 자신의 영역만 책임지고, 결과를 Orchestrator에 보고
- **상태 추적**: 모든 파이프라인 실행은 `pipeline.json`에 기록되어 재현 가능
- **안전장치**: 배포 전 health check 필수, 실패 시 자동 롤백, 연속 3회 실패 시 사람에게 알림

---

## 2. 파이프라인 흐름

전체 파이프라인은 **5단계**로 진행됩니다.

```
코드 변경 감지
     │
     ▼
┌─────────────────────────────────────────────────────┐
│  Stage 1: ANALYZE (Orchestrator)                     │
│  - 변경된 파일 분석 (프론트/백엔드/DB/설정)               │
│  - 영향 범위 판단 → 필요한 테스트 종류 결정                │
│  - 파이프라인 실행 계획 생성                              │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Stage 2: TEST (Test Agent → Sub-agents 병렬)        │
│                                                      │
│  ┌────────────┐ ┌────────────┐ ┌─────────────────┐  │
│  │ Unit Test  │ │ Integration│ │ E2E (Playwright) │  │
│  │ (Jest/     │ │ Test       │ │ - UI 렌더링 검증   │  │
│  │  Vitest)   │ │ (API 호출)  │ │ - 유저 플로우 검증  │  │
│  └─────┬──────┘ └─────┬──────┘ └───────┬─────────┘  │
│        ▼              ▼                ▼             │
│  ┌────────────┐ ┌────────────┐                       │
│  │ Performance│ │ Security   │                       │
│  │ (Lighthouse│ │ (npm audit │                       │
│  │  k6)       │ │  OWASP)    │                       │
│  └─────┬──────┘ └─────┬──────┘                       │
│        └──────┬───────┘                              │
│               ▼                                      │
│       Test Report 종합                                │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Stage 3: BUILD (Build Agent)                        │
│  - Docker 이미지 빌드                                  │
│  - 이미지 태깅 (git SHA + timestamp)                   │
│  - 이전 이미지 보존 (롤백용)                              │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Stage 4: DEPLOY (Deploy Agent)                      │
│  - 운영서버(192.168.0.5)에 SSH로 배포                   │
│  - Docker Compose 업데이트                             │
│  - Blue-Green 또는 Rolling 배포                        │
│  - Health check 대기 (최대 60초)                        │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Stage 5: VERIFY (Monitor Agent)                     │
│  - 배포 후 E2E 스모크 테스트                              │
│  - API 응답 시간 측정                                   │
│  - 에러 로그 모니터링 (30초간)                             │
│  - 실패 시 → 자동 롤백 → 알림                             │
│  - 성공 시 → 완료 보고                                   │
└─────────────────────────────────────────────────────┘
```

**핵심 포인트:**
- Stage 1에서 AI가 변경 범위를 분석해서 불필요한 테스트를 건너뜀
- Stage 2에서 독립적인 테스트는 병렬 실행으로 시간 절약
- Stage 4에서 이전 이미지를 항상 보존하여 30초 내 롤백 가능
- Stage 5에서 배포 후에도 실제로 동작하는지 실 환경 검증

---

## 3. 플러그인 파일 구조

```
gonsautopilot/
├── plugin/
│   ├── manifest.json              # 플러그인 메타데이터
│   │
│   ├── skills/                    # 사용자 호출 스킬
│   │   ├── gonsautopilot-run.md       # /gonsautopilot — 전체 파이프라인 실행
│   │   ├── gonsautopilot-test.md      # /gonsautopilot:test — 테스트만 실행
│   │   ├── gonsautopilot-deploy.md    # /gonsautopilot:deploy — 배포만 실행
│   │   ├── gonsautopilot-status.md    # /gonsautopilot:status — 현재 상태 조회
│   │   └── gonsautopilot-rollback.md  # /gonsautopilot:rollback — 수동 롤백
│   │
│   ├── agents/                    # Agent 정의
│   │   ├── orchestrator.md        # 총괄 Agent (파이프라인 흐름 제어)
│   │   ├── test-agent.md          # 테스트 전문 Agent
│   │   ├── build-agent.md         # 빌드 전문 Agent
│   │   ├── deploy-agent.md        # 배포 전문 Agent
│   │   └── monitor-agent.md       # 모니터링 전문 Agent
│   │
│   ├── hooks/                     # 자동 트리거 훅
│   │   ├── pre-commit.sh          # 커밋 전 빠른 린트/타입체크
│   │   └── post-push.sh           # 푸시 후 파이프라인 자동 시작
│   │
│   ├── lib/                       # 공유 스크립트
│   │   ├── docker-utils.sh        # Docker 빌드/배포 유틸
│   │   ├── test-runners.sh        # 테스트 실행기 래퍼
│   │   ├── health-check.sh        # 헬스체크 유틸
│   │   └── notify.sh              # 알림 (이메일/슬랙)
│   │
│   └── state/                     # 상태 저장소
│       ├── pipeline.json          # 현재/이전 파이프라인 상태
│       ├── deployments.json       # 배포 이력
│       └── rollback-registry.json # 롤백 가능한 이미지 목록
│
├── configs/                       # 프로젝트별 설정 템플릿
│   ├── gonsautopilot.yaml         # 파이프라인 설정
│   └── thresholds.yaml            # 품질 임계값 (커버리지, 성능 등)
│
├── docs/
│   └── plans/
│
└── CLAUDE.md
```

**사용자 호출:**

```bash
/gonsautopilot                    # 전체 파이프라인 (분석→테스트→빌드→배포→검증)
/gonsautopilot:test               # 테스트만 실행
/gonsautopilot:deploy             # 빌드+배포만 (테스트 통과 전제)
/gonsautopilot:status             # 마지막 파이프라인 결과 조회
/gonsautopilot:rollback           # 이전 버전으로 즉시 롤백
```

**gonsautopilot.yaml 설정 예시:**

```yaml
project:
  name: "my-webapp"
  type: "fullstack"

test:
  unit:
    command: "npm test"
    coverage_threshold: 80
  e2e:
    command: "npx playwright test"
    browser: "chromium"
  performance:
    tool: "lighthouse"
    min_score: 70
  security:
    enabled: true
    audit: true

build:
  docker:
    frontend: "./Dockerfile.frontend"
    backend: "./Dockerfile.backend"
  tag_strategy: "git-sha"

deploy:
  target: "192.168.0.5"
  method: "docker-compose"
  compose_file: "docker-compose.prod.yml"
  health_check:
    url: "http://localhost:3000/health"
    timeout: 60
    retries: 3

safety:
  auto_rollback: true
  max_consecutive_failures: 3
  notify:
    email: true
    method: "/notify-important"
```

---

## 4. Agent 간 통신과 상태 관리

**State Store (pipeline.json):**

```json
{
  "pipeline_id": "20260206-153000-a1b2c3",
  "status": "running",
  "trigger": "auto",
  "started_at": "2026-02-06T15:30:00+09:00",
  "stages": {
    "analyze": { "status": "passed" },
    "test":    { "status": "running" },
    "build":   { "status": "pending" },
    "deploy":  { "status": "pending" },
    "verify":  { "status": "pending" }
  },
  "changes": {
    "frontend": ["src/App.tsx"],
    "backend": [],
    "config": ["docker-compose.yml"]
  },
  "decisions": [
    {
      "agent": "orchestrator",
      "action": "skip_backend_test",
      "reason": "백엔드 파일 변경 없음"
    }
  ]
}
```

**실패 처리 정책 (Decision Matrix):**

| 실패 유형 | 심각도 | 자동 조치 |
|-----------|--------|----------|
| 단위테스트 실패 | CRITICAL | 파이프라인 중단 |
| E2E 실패 | CRITICAL | 파이프라인 중단 |
| 성능 점수 미달 | WARNING | 로그 기록, 배포 계속 |
| 보안 취약점 (high+) | CRITICAL | 파이프라인 중단 |
| 보안 취약점 (low/mod) | WARNING | 경고만 |
| 빌드 실패 | CRITICAL | 중단 + 에러 분석 보고 |
| 배포 실패 | CRITICAL | 자동 롤백 + 알림 |
| 헬스체크 실패 | CRITICAL | 자동 롤백 + 알림 |
| 연속 3회 실패 | ESCALATE | 파이프라인 잠금 + 이메일 알림 |

---

## 5. 안전장치와 롤백 메커니즘

### 3중 안전장치

**Layer 1: PRE-DEPLOY GATE**
- 모든 CRITICAL 테스트 통과
- Docker 이미지 빌드 성공
- 이전 배포 이미지 백업 확인
- 운영서버 디스크 여유 공간 > 2GB
- 운영서버 SSH 연결 정상
- → 하나라도 실패 시 배포 차단

**Layer 2: DEPLOY CANARY**
1. 새 컨테이너 시작 (이전 컨테이너 유지)
2. 새 컨테이너 헬스체크 통과 대기 (60초)
3. 통과 → 이전 컨테이너 중지 / 실패 → 새 컨테이너 제거
- → 서비스 다운타임 제로 목표

**Layer 3: POST-DEPLOY WATCHDOG**
- 배포 후 30초간 모니터링
- HTTP 5xx 발생 시 롤백
- 응답 시간 기준 대비 200% 초과 시 롤백
- 컨테이너 crash loop 시 롤백
- 에러 로그 급증 감지

### 롤백 프로세스

```
롤백 트리거 → rollback-registry.json에서 직전 성공 이미지 조회
→ docker-compose.prod.yml 이미지 태그 변경
→ docker compose up -d (운영서버)
→ 헬스체크 → 성공: 알림 / 실패: 긴급 알림
```

### 에스컬레이션

```
실패 1회 → 자동 롤백 + 로그 저장
실패 2회 → 자동 롤백 + 상세 분석 리포트
실패 3회 → 파이프라인 잠금 + 이메일 알림 (수동 해제 필요)
```

---

## 6. 구현 마일스톤

### Phase 1: 기반 구축 (Foundation)
- 플러그인 구조 생성 (manifest.json, skills, agents)
- Orchestrator Agent 기본 로직
- State Store (pipeline.json) 읽기/쓰기
- gonsautopilot.yaml 파서
- /gonsautopilot:status 스킬

### Phase 2: 테스트 자동화 (Test Agent)
- 변경 파일 분석 로직 (git diff 기반)
- Unit Test Runner
- E2E Runner (Playwright)
- Performance Analyzer (Lighthouse)
- Security Scanner (npm audit)
- 병렬 실행 + 결과 종합
- /gonsautopilot:test 스킬

### Phase 3: 빌드 + 배포 (Build & Deploy Agent)
- Docker 이미지 빌드 + 태깅
- SSH 배포 + Compose 업데이트
- Pre-deploy gate (5가지 체크)
- Canary 배포
- rollback-registry.json 관리
- /gonsautopilot:deploy 스킬

### Phase 4: 검증 + 안전장치 (Monitor Agent)
- 스모크 테스트
- 30초 와치독 모니터링
- 자동 롤백 메커니즘
- 에스컬레이션 (3회 실패 → 잠금 + 알림)
- /gonsautopilot:rollback 스킬
- /notify-important 연동

### Phase 5: 자동 트리거 + 리포팅 (Polish)
- post-push hook → 파이프라인 자동 시작
- pre-commit hook → 빠른 린트/타입체크
- 배포 이력 리포팅
- 파이프라인 실행 통계
- /gonsautopilot 전체 흐름 통합 테스트

---

## 설계 결정 사항

| 결정 | 선택 | 이유 |
|------|------|------|
| 대상 | 웹 풀스택 | 프론트+백엔드+DB 통합 테스트 필요 |
| 테스트 범위 | 전체 파이프라인 | 단위→통합→E2E→성능→보안 |
| 배포 전략 | 현재 인프라 활용 | Docker + 운영서버(192.168.0.5) |
| AI 자율성 | 완전 자동 | 사람 개입 최소화, 안전장치로 보완 |
| 시스템 형태 | Claude Code 플러그인 | 기존 워크플로우에 자연스럽게 통합 |
| 아키텍처 | Multi-Agent Orchestrator | 병렬성, 전문성, 확장성 확보 |
