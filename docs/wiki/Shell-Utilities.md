# 셸 유틸리티

`lib/` 디렉토리의 12개 셸 스크립트 상세 설명입니다.

## 공통 규칙

모든 스크립트는 다음 규칙을 따릅니다:

- `set -euo pipefail` — 엄격한 에러 처리
- JSON 출력 — `jq`로 처리 가능한 형식
- 상대 경로 — `SCRIPT_DIR` 기반으로 다른 스크립트/상태 참조

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../state"
```

---

## 스크립트 목록

| 스크립트 | 역할 | 사용 Agent |
|----------|------|-----------|
| `state-manager.sh` | 파이프라인 상태 관리 | Orchestrator |
| `config-parser.sh` | YAML 설정 파싱 | Orchestrator |
| `change-analyzer.sh` | git diff 변경 분석 | Orchestrator |
| `test-runners.sh` | 개별 테스트 실행기 | Test Agent |
| `test-executor.sh` | 테스트 병렬 실행 | Test Agent |
| `build-executor.sh` | Docker 이미지 빌드 | Build Agent |
| `deploy-executor.sh` | 카나리 배포 실행 | Deploy Agent |
| `docker-utils.sh` | Docker 유틸리티 | Build/Deploy Agent |
| `monitor-executor.sh` | 스모크 + 와치독 | Monitor Agent |
| `status-reporter.sh` | 상태 리포트 생성 | Orchestrator |
| `health-check.sh` | 헬스체크 | Deploy/Monitor Agent |
| `notify.sh` | 알림 발송 | Orchestrator |

---

## state-manager.sh — 상태 관리

파이프라인 실행 기록과 상태를 관리합니다.

### 명령어

```bash
state-manager.sh create-pipeline              # 새 파이프라인 생성
state-manager.sh update-stage <name> <status>  # 스테이지 상태 업데이트
state-manager.sh complete-pipeline <status>    # 파이프라인 완료 처리
state-manager.sh get-current                   # 현재 파이프라인 조회
state-manager.sh pipeline-is-locked            # 잠금 상태 확인
state-manager.sh lock-pipeline                 # 파이프라인 잠금
state-manager.sh unlock-pipeline               # 파이프라인 잠금 해제
state-manager.sh register-rollback <svc> <tag> # 롤백 이미지 등록
state-manager.sh get-rollback <service>        # 롤백 이미지 조회
```

### 상태 파일

- `state/pipeline.json` — 파이프라인 실행 기록
- `state/deployments.json` — 배포 이력
- `state/rollback-registry.json` — 롤백용 이전 이미지

---

## config-parser.sh — 설정 파싱

`gonsautopilot.yaml` 파일을 로드하고 JSON으로 변환합니다.

### 명령어

```bash
config-parser.sh load                    # 설정 로드 (JSON 출력)
config-parser.sh get <path>              # 특정 값 조회 (예: "test.unit.command")
config-parser.sh validate                # 설정 유효성 검사
```

### 설정 파일 검색 순서

```
1. 프로젝트 루트의 gonsautopilot.yaml
2. 프로젝트 루트의 gonsautopilot.yml
3. 플러그인의 configs/gonsautopilot.yaml (기본값)
```

---

## change-analyzer.sh — 변경 분석

git diff를 기반으로 변경된 파일을 분류합니다.

### 명령어

```bash
change-analyzer.sh analyze                # 변경 분석 (JSON 출력)
change-analyzer.sh determine-tests        # 필요한 테스트 목록 결정
change-analyzer.sh determine-builds       # 필요한 빌드 대상 결정
```

### 변경 카테고리

| 카테고리 | 파일 패턴 |
|----------|----------|
| frontend | `.tsx`, `.jsx`, `src/pages/`, `src/components/`, `tailwind.config` |
| backend | `server/`, `api/`, `.go`, `.py`, `src/api/`, `src/routes/` |
| database | `migrations/`, `prisma/`, `drizzle/`, `.sql` |
| config | `docker/`, `.github/`, `Dockerfile`, `package.json` |
| test | `.test.ts`, `.spec.ts`, `__tests__/` |

---

## test-runners.sh — 테스트 실행기

개별 테스트 종류별 실행 로직입니다.

### 명령어

```bash
test-runners.sh unit        # 단위 테스트 실행
test-runners.sh e2e         # E2E 테스트 실행
test-runners.sh performance # 성능 테스트 실행
test-runners.sh security    # 보안 테스트 실행
```

---

## test-executor.sh — 병렬 테스트

여러 테스트를 병렬로 실행하고 결과를 종합합니다.

### 명령어

```bash
test-executor.sh run <test1> <test2> ...  # 지정 테스트 병렬 실행
test-executor.sh run-all                  # 모든 테스트 실행
```

---

## build-executor.sh — Docker 빌드

Docker 이미지를 빌드하고 태깅합니다.

### 명령어

```bash
build-executor.sh build <target>          # frontend 또는 backend 빌드
build-executor.sh build-all               # 모두 빌드
build-executor.sh tag <image> <strategy>  # 이미지 태깅
```

---

## deploy-executor.sh — 카나리 배포

운영서버에 카나리 방식으로 배포합니다.

### 명령어

```bash
deploy-executor.sh pre-check              # Pre-deploy gate 체크
deploy-executor.sh deploy <service> <tag> # 서비스 배포
deploy-executor.sh rollback <service>     # 서비스 롤백
deploy-executor.sh rollback-all           # 전체 롤백
```

---

## docker-utils.sh — Docker 유틸리티

Docker 관련 공통 유틸리티 함수입니다.

### 주요 함수

```bash
docker_image_exists <image:tag>       # 이미지 존재 확인
docker_save_and_transfer <image:tag>  # 이미지 저장 + SCP 전송
docker_remote_load <image:tag>        # 원격서버에서 이미지 로드
docker_get_container_restarts <name>  # 컨테이너 재시작 횟수
```

---

## monitor-executor.sh — 모니터링

스모크 테스트와 와치독을 실행합니다.

### 명령어

```bash
monitor-executor.sh smoke-test            # 스모크 테스트
monitor-executor.sh watchdog <duration>   # 와치독 모니터링 (초)
monitor-executor.sh verify                # 스모크 + 와치독 전체 실행
```

---

## status-reporter.sh — 상태 리포트

파이프라인 상태를 보기 좋게 출력합니다.

### 명령어

```bash
status-reporter.sh current       # 현재 파이프라인 상태
status-reporter.sh deployments   # 배포 이력 (최근 10건)
status-reporter.sh stats         # 성공률 통계
status-reporter.sh full          # 전체 리포트
```

---

## health-check.sh — 헬스체크

서비스 헬스체크를 수행합니다.

### 명령어

```bash
health-check.sh check <url> <timeout> <retries>  # 헬스체크 실행
health-check.sh quick <url>                        # 빠른 헬스체크 (기본값)
```

---

## notify.sh — 알림

이메일 등 알림을 발송합니다.

### 명령어

```bash
notify.sh send <type> <message>   # 알림 발송
notify.sh escalation <level>      # 에스컬레이션 알림
```

### 알림 타입

| 타입 | 설명 |
|------|------|
| `success` | 파이프라인 성공 |
| `failure` | 파이프라인 실패 |
| `rollback` | 자동 롤백 발생 |
| `locked` | 파이프라인 잠금 |

---

## 다음 단계

- [[프로젝트 구조|Architecture]] — 전체 디렉토리 구조
- [[3-Layer Safety|Safety]] — 안전 장치 상세
