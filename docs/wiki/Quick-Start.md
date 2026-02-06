# 빠른 시작

플러그인 설치 후 첫 파이프라인을 실행하는 가이드입니다.

## 1. 설정 파일 생성

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
    enabled: false              # 처음에는 비활성화 권장
  security:
    enabled: true

build:
  docker:
    frontend: "./Dockerfile.frontend"
    backend: "./Dockerfile.backend"
  tag_strategy: "git-sha"

deploy:
  target: "192.168.0.5"        # 운영서버 IP
  compose_file: "docker-compose.prod.yml"
  health_check:
    url: "http://localhost:3000/health"
    timeout: 60
    retries: 3

safety:
  auto_rollback: true
  max_consecutive_failures: 3

trigger:
  auto_on_push: false           # 처음에는 수동 실행 권장
  branches: [main, master]
```

## 2. 분석만 먼저 실행 (dry-run)

코드를 변경한 뒤 분석만 먼저 해봅니다:

```
/gonsautopilot --dry-run
```

출력 예시:
```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline #20260206-160000-a1b2c3d
═══════════════════════════════════════════════════════

  ANALYZE: passed
  변경 파일: frontend 3개, backend 0개
  필요한 테스트: unit, e2e
  스킵: backend_test (백엔드 변경 없음)

  [dry-run] 분석 완료. 테스트/빌드/배포는 건너뜁니다.
═══════════════════════════════════════════════════════
```

## 3. 테스트만 실행

분석 결과가 올바르면 테스트를 실행합니다:

```
/gonsautopilot:test
```

## 4. 전체 파이프라인 실행

테스트가 통과하면 전체 파이프라인을 실행합니다:

```
/gonsautopilot
```

## 5. 상태 확인

실행 중이거나 완료된 파이프라인 상태를 확인합니다:

```
/gonsautopilot:status
```

---

## 단계별 사용 권장 순서

| 단계 | 명령어 | 목적 |
|------|--------|------|
| 1 | `/gonsautopilot --dry-run` | 분석 결과 확인 |
| 2 | `/gonsautopilot:test` | 테스트만 실행 |
| 3 | `/gonsautopilot --skip-deploy` | 테스트까지만 (배포 제외) |
| 4 | `/gonsautopilot` | 전체 파이프라인 |
| 5 | `trigger.auto_on_push: true` | 자동 트리거 활성화 |

---

## 다음 단계

- [[설정 파일|Configuration]] — 상세 설정 옵션
- [[슬래시 명령어|Commands]] — 모든 명령어 레퍼런스
