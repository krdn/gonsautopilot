# GonsAutoPilot Wiki

Claude Code 플러그인 기반 풀스택 자동 테스트/배포 시스템

git push 한 번으로 **분석 → 테스트 → 빌드 → 배포 → 검증**까지 AI가 자동 처리합니다.

## 목차

### 시작하기
- [[설치 가이드|Installation]]
- [[빠른 시작|Quick-Start]]
- [[설정 파일|Configuration]]

### 사용법
- [[슬래시 명령어|Commands]]
- [[파이프라인 흐름|Pipeline]]
- [[상태 조회|Status]]
- [[롤백|Rollback]]

### 아키텍처
- [[프로젝트 구조|Architecture]]
- [[Multi-Agent 시스템|Agents]]
- [[셸 유틸리티|Shell-Utilities]]

### 안전 장치
- [[3-Layer Safety|Safety]]
- [[에스컬레이션 정책|Escalation]]

### 개발
- [[개발 가이드|Development]]
- [[플러그인 표준|Plugin-Standard]]

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| **스마트 변경 분석** | git diff 기반 카테고리별 분류, 필요한 테스트만 선택 |
| **병렬 테스트** | Unit / E2E / Performance / Security 동시 실행 |
| **Docker 빌드 + SSH 배포** | 이미지 빌드, 원격 전송, Compose 업데이트 |
| **카나리 배포** | 새 컨테이너 → 헬스체크 → 성공 시 확정 / 실패 시 롤백 |
| **배포 후 검증** | 스모크 테스트 + 30초 와치독 모니터링 |
| **자동 롤백** | 이상 감지 시 즉시 롤백, 연속 실패 시 잠금 + 알림 |

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
