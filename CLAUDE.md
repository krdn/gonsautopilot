# GonsAutoPilot

Claude Code 플러그인 기반 풀스택 자동 테스트/배포 시스템

## 프로젝트 구조 (마켓플레이스 표준)

```
gonsautopilot/
├── .claude-plugin/
│   └── plugin.json        # 플러그인 메타데이터 (필수)
├── commands/              # 슬래시 명령어 (5개)
│   ├── gonsautopilot.md   # /gonsautopilot
│   ├── test.md            # /gonsautopilot:test
│   ├── deploy.md          # /gonsautopilot:deploy
│   ├── status.md          # /gonsautopilot:status
│   └── rollback.md        # /gonsautopilot:rollback
├── agents/                # Agent 정의 (5개)
├── hooks/                 # 플러그인 훅
│   ├── hooks.json         # 훅 설정
│   ├── pre-commit.sh      # 커밋 전 품질 체크
│   └── post-push.sh       # 푸시 후 자동 트리거
├── lib/                   # 공유 셸 유틸리티 (12개)
├── state/                 # 런타임 상태 저장소
├── configs/               # 설정 템플릿
└── docs/plans/            # 설계 문서
```

## 핵심 명령어

```bash
/gonsautopilot              # 전체 파이프라인
/gonsautopilot:test         # 테스트만
/gonsautopilot:deploy       # 빌드+배포만
/gonsautopilot:status       # 상태 조회
/gonsautopilot:rollback     # 수동 롤백
```

## 개발 규칙

- 셸 스크립트는 `set -euo pipefail` 사용
- JSON 처리에 `jq` 사용
- YAML 처리에 `yq` 사용
- 상태 파일 수정 시 반드시 `state-manager.sh`를 통해 수행
- Agent 이름 접두사: `gap-` (GonsAutoPilot)
- 명령어 파일에는 YAML frontmatter 필수 (description, allowed-tools)
- 플러그인 내부 경로 참조는 `${CLAUDE_PLUGIN_ROOT}` 환경변수 사용
