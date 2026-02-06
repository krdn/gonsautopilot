# 설치 가이드

## 사전 요구사항

GonsAutoPilot은 다음 도구가 설치되어 있어야 합니다:

| 도구 | 용도 | 설치 확인 |
|------|------|----------|
| **jq** | JSON 처리 | `jq --version` |
| **yq** | YAML 처리 | `yq --version` |
| **Docker** | 이미지 빌드/배포 | `docker --version` |
| **SSH** | 운영서버 접근 | `ssh -V` |
| **curl** | 헬스체크 | `curl --version` |
| **Git** | 변경 분석 | `git --version` |
| **Claude Code** | 플러그인 실행 | `claude --version` |

### Ubuntu/Debian 설치

```bash
# jq, curl은 보통 기본 설치됨
sudo apt install -y jq curl

# yq 설치
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq

# Docker 설치 (공식 가이드)
# https://docs.docker.com/engine/install/ubuntu/
```

---

## 플러그인 설치

### 방법 1: GitHub에서 설치 (권장)

Claude Code 대화 중 다음 명령어를 실행합니다:

**Step 1 — 마켓플레이스 등록**

```
/plugin marketplace add krdn/gonsautopilot
```

**Step 2 — 플러그인 설치**

```
/plugin install gonsautopilot@gonsautopilot
```

### 방법 2: 인터랙티브 UI

```
/plugin
```

실행하면 탭 UI가 열립니다:
1. **Marketplaces** 탭 → `krdn/gonsautopilot` 추가
2. **Discover** 탭 → `gonsautopilot` 찾아서 Install
3. **Installed** 탭 → 설치 확인

### 방법 3: 로컬 경로에서 설치 (개발용)

```bash
# 저장소 클론
git clone https://github.com/krdn/gonsautopilot.git

# 로컬 마켓플레이스로 등록
/plugin marketplace add /path/to/gonsautopilot
```

---

## 설치 범위 (Scope)

플러그인은 3가지 범위로 설치할 수 있습니다:

| 범위 | 설정 파일 | 공유 | 용도 |
|------|-----------|------|------|
| `user` (기본) | `~/.claude/settings.json` | 개인 전체 | 모든 프로젝트에서 사용 |
| `project` | `.claude/settings.json` | 팀 공유 (git) | 팀원 모두 동일 플러그인 |
| `local` | `.claude/settings.local.json` | 비공유 (gitignore) | 개인 프로젝트용 |

```bash
# user 범위 (기본)
/plugin install gonsautopilot@gonsautopilot

# project 범위 (팀 공유)
/plugin install gonsautopilot@gonsautopilot --scope project

# local 범위
/plugin install gonsautopilot@gonsautopilot --scope local
```

---

## 설치 확인

설치 후 Claude Code에서 다음을 확인합니다:

```
/gonsautopilot:status
```

`실행된 파이프라인이 없습니다`라고 나오면 정상 설치된 것입니다.

---

## 플러그인 관리

### 비활성화 (데이터 유지)

```bash
/plugin disable gonsautopilot@gonsautopilot
```

### 다시 활성화

```bash
/plugin enable gonsautopilot@gonsautopilot
```

### 업데이트

```bash
/plugin update gonsautopilot@gonsautopilot
```

### 완전 제거

```bash
# 플러그인 제거
/plugin uninstall gonsautopilot@gonsautopilot

# 마켓플레이스도 제거 (선택)
/plugin marketplace remove gonsautopilot
```

---

## 다음 단계

- [[빠른 시작|Quick-Start]] — 첫 파이프라인 실행하기
- [[설정 파일|Configuration]] — 프로젝트에 맞게 설정하기
