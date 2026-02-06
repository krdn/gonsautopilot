# /gonsautopilot — 전체 파이프라인 실행

전체 자동 파이프라인을 실행합니다: 분석 → 테스트 → 빌드 → 배포 → 검증

## 실행 방법

사용자가 `/gonsautopilot`을 호출하면 이 스킬이 실행됩니다.

## 사전 조건

- 프로젝트 루트에 `gonsautopilot.yaml` 설정 파일이 존재해야 합니다
- git 저장소여야 합니다
- 파이프라인이 잠금 상태가 아니어야 합니다

## 실행 흐름

이 스킬은 Orchestrator Agent(`gap-orchestrator`)를 호출하여 전체 파이프라인을 실행합니다.

### Step 1: 사전 검증
```
- 파이프라인 잠금 확인 (state-manager.sh pipeline-is-locked)
- 설정 파일 로드 (config-parser.sh load)
- 설정 유효성 검사 (config-parser.sh validate)
```

### Step 2: 파이프라인 생성
```
- ID 생성 (state-manager.sh pipeline-generate-id)
- 파이프라인 생성 (state-manager.sh pipeline-create)
```

### Step 3: Orchestrator Agent 실행
```
Orchestrator Agent에게 다음을 전달:
- pipeline_id
- config (gonsautopilot.yaml)
- 변경 분석 결과

Orchestrator가 5개 스테이지를 순차적으로 실행합니다.
```

### Step 4: 결과 출력
```
파이프라인 완료 후 최종 리포트 출력
```

## 옵션

- `/gonsautopilot` — 전체 파이프라인 (기본)
- `/gonsautopilot --dry-run` — 분석까지만 실행 (테스트/배포 없이)
- `/gonsautopilot --skip-deploy` — 테스트까지만 (배포 건너뜀)
