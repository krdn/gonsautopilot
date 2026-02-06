# GonsAutoPilot

Claude Code 플러그인 기반 풀스택 자동 테스트/배포 시스템

git push 한 번으로 **분석 → 테스트 → 빌드 → 배포 → 검증**까지 AI가 자동 처리합니다.

## 주요 기능

- **스마트 변경 분석** — git diff 기반으로 변경 파일을 카테고리별 분류, 필요한 테스트만 선택 실행
- **병렬 테스트** — Unit / E2E (Playwright) / Performance (Lighthouse) / Security (npm audit) 동시 실행
- **Docker 빌드 + SSH 배포** — 이미지 빌드, 운영서버 전송, Docker Compose 업데이트
- **카나리 배포** — 새 컨테이너 시작 → 헬스체크 → 성공 시 확정 / 실패 시 자동 롤백
- **배포 후 검증** — 스모크 테스트 + 30초 와치독 모니터링
- **자동 롤백 + 에스컬레이션** — 이상 감지 시 즉시 롤백, 연속 실패 시 파이프라인 잠금 + 이메일 알림

## 5-Stage 파이프라인

```
ANALYZE → TEST → BUILD → DEPLOY → VERIFY
   │         │       │        │        │
   │         │       │        │        └─ 스모크 테스트 + 와치독
   │         │       │        └─ Pre-deploy gate + 카나리 배포
   │         │       └─ Docker 이미지 빌드 + 태깅
   │         └─ Unit/E2E/Performance/Security 병렬 실행
   └─ 변경 파일 분석 + 테스트/빌드 대상 결정
```

## 사용법

### 스킬 명령어

| 명령어 | 설명 |
|--------|------|
| `/gonsautopilot` | 전체 파이프라인 실행 |
| `/gonsautopilot --dry-run` | 분석까지만 (테스트/배포 없이) |
| `/gonsautopilot --skip-deploy` | 테스트까지만 |
| `/gonsautopilot:test` | 테스트만 실행 |
| `/gonsautopilot:deploy` | 빌드+배포만 (테스트 통과 전제) |
| `/gonsautopilot:status` | 파이프라인 상태 조회 |
| `/gonsautopilot:status stats` | 성공률 통계 |
| `/gonsautopilot:status deployments` | 배포 이력 |
| `/gonsautopilot:rollback` | 이전 버전으로 즉시 롤백 |
| `/gonsautopilot:rollback frontend` | 특정 서비스만 롤백 |

### 설정

프로젝트 루트에 `gonsautopilot.yaml`을 생성합니다:

```yaml
project:
  name: "my-webapp"
  type: "fullstack"           # fullstack | backend | frontend

test:
  unit:
    command: "npm test"
    coverage_threshold: 80
    enabled: true
  e2e:
    command: "npx playwright test"
    enabled: true
  performance:
    tool: "lighthouse"
    min_score: 70
    enabled: true
  security:
    enabled: true

build:
  docker:
    frontend: "./Dockerfile.frontend"
    backend: "./Dockerfile.backend"
  tag_strategy: "git-sha"     # git-sha | semver | timestamp

deploy:
  target: "192.168.0.5"
  compose_file: "docker-compose.prod.yml"
  health_check:
    url: "http://localhost:3000/health"
    timeout: 60
    retries: 3

verify:
  smoke_test:
    response_time_max: 3000
  watchdog:
    duration: 30
    error_rate_max: 0.01

safety:
  auto_rollback: true
  max_consecutive_failures: 3

trigger:
  auto_on_push: true
  branches: [main, master]
```

## 아키텍처

### Multi-Agent 구조

```
Orchestrator Agent
├── Test Agent      → 테스트 병렬 실행 + 결과 수집
├── Build Agent     → Docker 이미지 빌드 + 태깅
├── Deploy Agent    → Pre-deploy gate + 카나리 배포
└── Monitor Agent   → 스모크 테스트 + 와치독 + 자동 롤백
```

### 프로젝트 구조

```
gonsautopilot/
├── plugin/
│   ├── agents/              # Agent 정의 (5개)
│   │   ├── orchestrator.md
│   │   ├── test-agent.md
│   │   ├── build-agent.md
│   │   ├── deploy-agent.md
│   │   └── monitor-agent.md
│   ├── skills/              # 사용자 호출 스킬 (5개)
│   │   ├── gonsautopilot-run.md
│   │   ├── gonsautopilot-test.md
│   │   ├── gonsautopilot-deploy.md
│   │   ├── gonsautopilot-status.md
│   │   └── gonsautopilot-rollback.md
│   ├── lib/                 # 셸 유틸리티 (12개)
│   │   ├── state-manager.sh
│   │   ├── config-parser.sh
│   │   ├── change-analyzer.sh
│   │   ├── test-runners.sh
│   │   ├── test-executor.sh
│   │   ├── build-executor.sh
│   │   ├── deploy-executor.sh
│   │   ├── docker-utils.sh
│   │   ├── monitor-executor.sh
│   │   ├── status-reporter.sh
│   │   ├── health-check.sh
│   │   └── notify.sh
│   ├── hooks/               # Git Hooks (2개)
│   │   ├── pre-commit.sh
│   │   └── post-push.sh
│   ├── state/               # 런타임 상태
│   │   ├── pipeline.json
│   │   ├── deployments.json
│   │   └── rollback-registry.json
│   └── manifest.json
├── configs/
│   ├── gonsautopilot.yaml   # 설정 템플릿
│   └── thresholds.yaml      # 품질 임계값
├── docs/plans/
│   └── 2026-02-06-gonsautopilot-design.md
├── CLAUDE.md
└── README.md
```

## 안전 장치

### 3-Layer Safety

| 레이어 | 시점 | 동작 |
|--------|------|------|
| **Pre-deploy Gate** | 배포 전 | 테스트 통과, 이미지 존재, 롤백 준비, 디스크 공간, SSH 연결 5가지 체크 |
| **카나리 배포** | 배포 중 | 새 컨테이너 시작 → 헬스체크 → 실패 시 즉시 이전 버전 복원 |
| **와치독** | 배포 후 | 30초간 5xx 에러, 응답시간, 컨테이너 재시작 감시 |

### 에스컬레이션 정책

```
실패 1회 → 자동 롤백 + 로그 저장
실패 2회 → 자동 롤백 + 경고
실패 3회 → 파이프라인 잠금 + 이메일 알림
```

## 요구사항

- **jq** — JSON 처리
- **yq** — YAML 처리
- **Docker** — 이미지 빌드/배포
- **SSH** — 운영서버 접근
- **curl** — 헬스체크
- **Git** — 변경 분석

## 라이선스

MIT
