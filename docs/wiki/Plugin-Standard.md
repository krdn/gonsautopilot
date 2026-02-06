# 플러그인 표준

GonsAutoPilot이 따르는 Claude Code 마켓플레이스 플러그인 표준입니다.

## 필수 구조

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json       # 필수: 플러그인 메타데이터
├── commands/             # 슬래시 명령어
│   └── *.md
├── agents/               # Agent 정의
│   └── *.md
└── hooks/                # 훅
    ├── hooks.json
    └── *.sh
```

---

## .claude-plugin/plugin.json

플러그인을 인식하기 위한 필수 파일입니다:

```json
{
  "name": "gonsautopilot",
  "description": "Fullstack auto test/deploy pipeline",
  "version": "1.0.0",
  "author": {
    "name": "gon",
    "email": "krdn.net@gmail.com"
  }
}
```

### 필수 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `name` | string | 플러그인 고유 이름 |
| `description` | string | 플러그인 설명 |
| `version` | string | 버전 (semver) |

### 선택 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `author.name` | string | 작성자 이름 |
| `author.email` | string | 작성자 이메일 |

---

## 명령어 (commands/*.md)

### 파일 이름 규칙

- `commands/gonsautopilot.md` → `/gonsautopilot` (기본 명령어)
- `commands/test.md` → `/gonsautopilot:test` (하위 명령어)
- `commands/deploy.md` → `/gonsautopilot:deploy`

기본 명령어 파일 이름은 `plugin.json`의 `name`과 일치해야 합니다.

### YAML Frontmatter

```yaml
---
description: 명령어 설명 (/help에 표시)
argument-hint: [--option1] [--option2]
allowed-tools: [Bash, Read, Glob, Grep, Task]
---
```

| 필드 | 필수 | 설명 |
|------|------|------|
| `description` | O | 명령어 설명 |
| `argument-hint` | X | 인자 힌트 (사용법 안내) |
| `allowed-tools` | X | 사전 승인 도구 (권한 프롬프트 감소) |

### 환경 변수

| 변수 | 설명 |
|------|------|
| `${CLAUDE_PLUGIN_ROOT}` | 플러그인 루트 디렉토리 경로 |
| `$ARGUMENTS` | 사용자가 명령어에 전달한 인자 |

---

## Agent (agents/*.md)

### YAML Frontmatter

```yaml
---
name: gap-agent-name
description: Agent 설명. 언제 사용되는지 상세히 작성.
model: inherit
tools: [Bash, Read]
---
```

| 필드 | 필수 | 설명 |
|------|------|------|
| `name` | O | Agent 고유 이름 |
| `description` | O | Agent 설명 + 호출 조건 |
| `model` | X | 사용할 모델 (`inherit`: 부모 모델) |
| `tools` | X | Agent가 사용할 수 있는 도구 |

### 이름 규칙

Agent 이름에는 플러그인 고유 접두사를 사용합니다:

- `gap-orchestrator` (gap = GonsAutoPilot)
- `gap-test-agent`
- `gap-build-agent`

---

## 훅 (hooks/hooks.json)

Claude Code 훅 시스템 표준 형식입니다:

```json
{
  "description": "훅 설명",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/script.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/script.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 지원하는 훅 이벤트

| 이벤트 | 시점 |
|--------|------|
| `PreToolUse` | 도구 사용 전 |
| `PostToolUse` | 도구 사용 후 |
| `UserPromptSubmit` | 사용자 입력 제출 시 |

---

## 설치 방법

### 마켓플레이스 등록

```
/plugin marketplace add krdn/gonsautopilot
```

### 설치

```
/plugin install gonsautopilot@github
```

### 범위(scope)

| 범위 | 설명 | 적용 |
|------|------|------|
| `user` | 사용자 전체 | 모든 프로젝트에 적용 |
| `project` | 프로젝트 | 현재 프로젝트에만 |
| `local` | 로컬 | 로컬에서만 (커밋 안 함) |

---

## 다음 단계

- [[설치 가이드|Installation]] — 상세 설치 방법
- [[개발 가이드|Development]] — 플러그인 확장 방법
