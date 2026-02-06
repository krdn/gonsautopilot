# 개발 가이드

GonsAutoPilot 플러그인을 수정하거나 확장하는 방법입니다.

## 개발 규칙

### 셸 스크립트

- `set -euo pipefail` 사용 (엄격한 에러 처리)
- JSON 출력 반환 (`jq` 처리 가능)
- `SCRIPT_DIR` 기반 상대 경로로 다른 파일 참조
- YAML 처리에 `yq` 사용

### 명령어 파일 (commands/*.md)

- YAML frontmatter 필수: `description`, `allowed-tools`
- 옵션이 있으면 `argument-hint` 추가
- 플러그인 내부 경로는 `${CLAUDE_PLUGIN_ROOT}` 사용
- 인자 접근은 `$ARGUMENTS` 사용

### Agent 파일 (agents/*.md)

- YAML frontmatter 필수: `name`, `description`, `model`, `tools`
- Agent 이름 접두사: `gap-` (GonsAutoPilot)
- `model: inherit` — 부모 모델 사용 (권장)

### 상태 관리

- 상태 파일 직접 수정 금지
- 반드시 `lib/state-manager.sh`를 통해 수정
- `state/*.json`은 `.gitignore`에 포함 (커밋하지 않음)

---

## 새 명령어 추가

### 1. 명령어 파일 생성

`commands/` 디렉토리에 `.md` 파일을 생성합니다:

```markdown
---
description: 새 명령어 설명
argument-hint: [--option]
allowed-tools: [Bash, Read]
---

# 명령어 이름

명령어 설명과 실행 로직을 작성합니다.

## 실행 로직

1단계: ...
2단계: ...
```

### 2. 명령어 이름 규칙

- 기본 명령어: `commands/gonsautopilot.md` → `/gonsautopilot`
- 하위 명령어: `commands/test.md` → `/gonsautopilot:test`

파일 이름이 곧 하위 명령어 이름입니다 (플러그인 이름이 접두사).

---

## 새 Agent 추가

### 1. Agent 파일 생성

`agents/` 디렉토리에 `.md` 파일을 생성합니다:

```markdown
---
name: gap-new-agent
description: 새 Agent 설명. 언제 사용되는지 상세히 작성.
model: inherit
tools: [Bash, Read]
---

# 새 Agent

Agent의 역할과 동작 방식을 상세히 작성합니다.
```

### 2. Agent 호출

Orchestrator에서 `Task` 도구로 Agent를 호출합니다. Agent의 `description`이 호출 조건을 결정합니다.

---

## 새 셸 스크립트 추가

### 1. 파일 생성

`lib/` 디렉토리에 `.sh` 파일을 생성합니다:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../state"

# 함수 정의
my_function() {
  local arg1="${1:?'arg1 필수'}"
  # ...
  echo '{"status":"ok"}'  # JSON 출력
}

# 메인
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    my-command) my_function "$@" ;;
    help)       echo "사용법: ..." ;;
    *)          echo "ERROR: 알 수 없는 명령어: $cmd" >&2; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

### 2. 실행 권한 부여

```bash
chmod +x lib/new-script.sh
```

---

## 테스트

### 개별 스크립트 테스트

```bash
# 직접 실행
bash lib/state-manager.sh create-pipeline
bash lib/config-parser.sh load
bash lib/change-analyzer.sh analyze
```

### dry-run 모드

전체 파이프라인을 분석까지만 실행합니다:

```
/gonsautopilot --dry-run
```

---

## 디버깅

### 상태 파일 확인

```bash
cat state/pipeline.json | jq .
cat state/rollback-registry.json | jq .
cat state/deployments.json | jq .
```

### 로그 확인

각 스크립트는 stderr로 디버그 정보를 출력합니다. 필요 시 `2>&1`로 리다이렉트하여 확인합니다.

---

## 다음 단계

- [[플러그인 표준|Plugin-Standard]] — Claude Code 플러그인 표준 형식
- [[프로젝트 구조|Architecture]] — 디렉토리 구조
