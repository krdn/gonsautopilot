# 프로젝트 구조

GonsAutoPilot의 디렉토리 구조와 각 파일의 역할입니다.

## 디렉토리 구조 (마켓플레이스 표준)

```
gonsautopilot/
├── .claude-plugin/
│   └── plugin.json         # 플러그인 메타데이터 (필수)
├── commands/               # 슬래시 명령어 (5개)
│   ├── gonsautopilot.md    # /gonsautopilot (전체 파이프라인)
│   ├── test.md             # /gonsautopilot:test
│   ├── deploy.md           # /gonsautopilot:deploy
│   ├── status.md           # /gonsautopilot:status
│   └── rollback.md         # /gonsautopilot:rollback
├── agents/                 # Agent 정의 (5개)
│   ├── orchestrator.md     # gap-orchestrator (총괄)
│   ├── test-agent.md       # gap-test-agent (테스트)
│   ├── build-agent.md      # gap-build-agent (빌드)
│   ├── deploy-agent.md     # gap-deploy-agent (배포)
│   └── monitor-agent.md    # gap-monitor-agent (모니터링)
├── hooks/                  # 플러그인 훅
│   ├── hooks.json          # 훅 설정 (Claude Code 표준)
│   ├── pre-commit.sh       # 커밋 전 품질 체크
│   └── post-push.sh        # 푸시 후 자동 트리거
├── lib/                    # 셸 유틸리티 (12개)
│   ├── state-manager.sh    # 파이프라인 상태 관리
│   ├── config-parser.sh    # YAML 설정 파싱
│   ├── change-analyzer.sh  # git diff 변경 분석
│   ├── test-runners.sh     # 개별 테스트 실행기
│   ├── test-executor.sh    # 테스트 병렬 실행
│   ├── build-executor.sh   # Docker 이미지 빌드
│   ├── deploy-executor.sh  # 카나리 배포 실행
│   ├── docker-utils.sh     # Docker 유틸리티
│   ├── monitor-executor.sh # 스모크 + 와치독
│   ├── status-reporter.sh  # 상태 리포트 생성
│   ├── health-check.sh     # 헬스체크
│   └── notify.sh           # 알림 발송
├── state/                  # 런타임 상태 (JSON)
│   ├── pipeline.json       # 파이프라인 실행 기록
│   ├── deployments.json    # 배포 이력
│   └── rollback-registry.json  # 롤백용 이전 이미지
├── configs/                # 설정 템플릿
│   ├── gonsautopilot.yaml  # 기본 설정 템플릿
│   └── thresholds.yaml     # 품질 임계값
├── CLAUDE.md               # Claude Code 프로젝트 가이드
└── README.md               # 프로젝트 문서
```

---

## 핵심 파일 설명

### .claude-plugin/plugin.json

Claude Code가 플러그인을 인식하기 위한 필수 파일입니다:

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

### commands/*.md

슬래시 명령어 정의 파일. YAML frontmatter가 필수입니다:

```yaml
---
description: 전체 파이프라인 실행
argument-hint: [--dry-run] [--skip-deploy]
allowed-tools: [Bash, Read, Glob, Grep, Task]
---
```

- `description` — `/help`에 표시되는 설명
- `argument-hint` — 인자 힌트
- `allowed-tools` — 사전 승인된 도구 (권한 프롬프트 감소)

### agents/*.md

Agent 정의 파일. YAML frontmatter로 Agent 속성을 정의합니다:

```yaml
---
name: gap-orchestrator
description: 파이프라인 총괄 Agent
model: inherit
tools: [Bash, Read, Glob, Grep, Task]
---
```

- `name` — Agent 이름 (접두사 `gap-`)
- `description` — Claude가 Agent를 호출할 조건
- `model` — 사용할 모델 (`inherit`: 부모 모델 사용)
- `tools` — Agent가 사용할 수 있는 도구

### hooks/hooks.json

Claude Code 훅 시스템 표준 형식:

```json
{
  "hooks": {
    "PreToolUse": [...],
    "UserPromptSubmit": [...]
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` 환경변수로 플러그인 루트 경로를 참조합니다.

### lib/*.sh

모든 셸 스크립트는 `set -euo pipefail`을 사용하며, JSON 출력을 반환합니다.

스크립트 간 참조는 `SCRIPT_DIR` 기반 상대 경로를 사용합니다:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../state"
```

### state/*.json

런타임 중 생성/수정되는 상태 파일입니다. `.gitignore`에서 제외되어 있습니다.

---

## 다음 단계

- [[Multi-Agent 시스템|Agents]] — Agent 간 역할 분담
- [[셸 유틸리티|Shell-Utilities]] — lib 파일 상세
