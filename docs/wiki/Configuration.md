# 설정 파일

GonsAutoPilot은 프로젝트 루트의 `gonsautopilot.yaml` 파일로 설정합니다.

## 전체 설정 레퍼런스

```yaml
# ─── 프로젝트 기본 정보 ───
project:
  name: "my-webapp"           # 프로젝트 이름 (Docker 이미지 이름에 사용)
  type: "fullstack"           # fullstack | backend | frontend

# ─── 테스트 설정 ───
test:
  unit:
    command: "npm test"       # 단위테스트 실행 명령어
    coverage_threshold: 80    # 커버리지 최소 기준 (%)
    enabled: true
  e2e:
    command: "npx playwright test"
    browser: "chromium"       # chromium | firefox | webkit
    enabled: true
  performance:
    tool: "lighthouse"        # lighthouse
    min_score: 70             # Lighthouse 최소 점수
    enabled: true
  security:
    enabled: true
    audit: true               # npm audit 실행 여부

# ─── 빌드 설정 ───
build:
  docker:
    frontend: "./Dockerfile.frontend"   # 프론트엔드 Dockerfile 경로
    backend: "./Dockerfile.backend"     # 백엔드 Dockerfile 경로
  tag_strategy: "git-sha"    # git-sha | semver | timestamp

# ─── 배포 설정 ───
deploy:
  target: "192.168.0.5"      # 운영서버 IP
  method: "docker-compose"   # 배포 방식
  compose_file: "docker-compose.prod.yml"
  health_check:
    url: "http://localhost:3000/health"  # 헬스체크 URL
    timeout: 60               # 최대 대기 시간 (초)
    retries: 3                # 재시도 횟수

# ─── 배포 후 검증 ───
verify:
  smoke_test:
    response_time_max: 3000   # 응답 시간 최대 기준 (ms)
    endpoints: []             # 추가 검증 엔드포인트 (예: "/api/v1/status")
  watchdog:
    duration: 30              # 와치독 모니터링 시간 (초)
    error_rate_max: 0.01      # 최대 에러율 (1%)
    latency_spike_ratio: 2.0  # 평소 대비 응답시간 비율

# ─── 안전 장치 ───
safety:
  auto_rollback: true         # 실패 시 자동 롤백
  max_consecutive_failures: 3 # 연속 N회 실패 시 잠금 + 알림
  notify:
    email: true
    method: "/notify-important"

# ─── 트리거 ───
trigger:
  auto_on_push: true          # 푸시 시 자동 트리거
  auto_execute: false         # true: 자동 실행, false: 안내만
  branches:                   # 트리거 대상 브랜치
    - main
    - master
```

---

## 섹션별 상세 설명

### project

| 필드 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| `name` | string | 필수 | 프로젝트 이름. Docker 이미지 이름에 `<name>-frontend`, `<name>-backend`으로 사용 |
| `type` | string | `fullstack` | `fullstack`: 프론트+백엔드 모두, `backend`: 백엔드만, `frontend`: 프론트만 |

### test

각 테스트 종류별 `enabled: false`로 비활성화할 수 있습니다.

| 테스트 | 실패 시 | 영향 |
|--------|---------|------|
| **unit** | CRITICAL | 파이프라인 중단 |
| **e2e** | CRITICAL | 파이프라인 중단 |
| **performance** | WARNING | 기록 후 계속 진행 |
| **security (high+)** | CRITICAL | 파이프라인 중단 |
| **security (moderate-)** | WARNING | 기록 후 계속 진행 |

### build.tag_strategy

| 전략 | 형식 | 예시 |
|------|------|------|
| `git-sha` | `<name>:<short-sha>` | `myapp-front:a1b2c3d` |
| `semver` | `<name>:v<major>.<minor>.<patch>` | `myapp-front:v1.2.3` |
| `timestamp` | `<name>:<YYYYMMDD-HHMMSS>` | `myapp-front:20260206-160000` |

### deploy.health_check

카나리 배포 시 새 컨테이너의 헬스체크에 사용됩니다.

- `url`: 헬스체크 엔드포인트 (HTTP 200 확인)
- `timeout`: 최대 대기 시간. 이 시간 안에 200이 안 오면 실패
- `retries`: 실패 시 재시도 횟수

### verify.watchdog

배포 완료 후 `duration`초 동안 5초 간격으로 모니터링합니다.

- **5xx 에러** → 1건이라도 발생하면 즉시 롤백
- **응답 시간** → 첫 측정 대비 `latency_spike_ratio`배 초과 시 롤백
- **컨테이너 재시작** → crash loop 감지 시 롤백

### safety

- `auto_rollback: true` → 배포/검증 실패 시 자동으로 이전 버전 복원
- `max_consecutive_failures: 3` → 3회 연속 실패 시 파이프라인 잠금 + 이메일 알림

### trigger

- `auto_on_push: true` + `auto_execute: false` → 푸시 시 파이프라인 실행 안내만 표시
- `auto_on_push: true` + `auto_execute: true` → 푸시 시 자동 파이프라인 실행
- `branches` → 지정된 브랜치만 트리거 (feature 브랜치는 무시)

---

## 다음 단계

- [[슬래시 명령어|Commands]] — 명령어 레퍼런스
- [[파이프라인 흐름|Pipeline]] — 파이프라인 상세 흐름
