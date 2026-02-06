# 슬래시 명령어

GonsAutoPilot이 제공하는 모든 슬래시 명령어 레퍼런스입니다.

## 명령어 목록

| 명령어 | 설명 | 파일 |
|--------|------|------|
| `/gonsautopilot` | 전체 파이프라인 실행 | `commands/gonsautopilot.md` |
| `/gonsautopilot:test` | 테스트만 실행 | `commands/test.md` |
| `/gonsautopilot:deploy` | 빌드+배포만 실행 | `commands/deploy.md` |
| `/gonsautopilot:status` | 상태 조회 | `commands/status.md` |
| `/gonsautopilot:rollback` | 수동 롤백 | `commands/rollback.md` |

---

## /gonsautopilot — 전체 파이프라인

전체 5-Stage 파이프라인을 실행합니다.

### 옵션

```
/gonsautopilot               # 전체 실행
/gonsautopilot --dry-run     # 분석까지만 (테스트/배포 없이)
/gonsautopilot --skip-deploy # 테스트까지만 (배포 건너뜀)
```

### 실행 흐름

```
1. 설정 로드 + 파이프라인 생성
2. ANALYZE — 변경 파일 분석, 테스트/빌드 대상 결정
3. TEST — 필요한 테스트 병렬 실행
4. BUILD — Docker 이미지 빌드 + 태깅
5. DEPLOY — Pre-deploy gate + 카나리 배포
6. VERIFY — 스모크 테스트 + 30초 와치독
```

### 중단 조건

- CRITICAL 테스트 실패 → TEST에서 중단
- 빌드 실패 → BUILD에서 중단
- Pre-deploy gate 실패 → DEPLOY에서 중단
- 카나리 배포 실패 → 자동 롤백 후 중단
- 와치독 이상 감지 → 자동 롤백 후 중단

---

## /gonsautopilot:test — 테스트만

변경 분석 + 테스트 실행 + 리포트 출력 (빌드/배포 없이)

```
/gonsautopilot:test
```

### 실행 흐름

```
1. 설정 로드 + 파이프라인 생성
2. ANALYZE — 변경 파일 분석, 필요한 테스트 결정
3. TEST — 테스트 병렬 실행 + 결과 리포트
```

### 지원 테스트

| 종류 | 도구 | 실패 등급 |
|------|------|----------|
| Unit | Jest, Vitest 등 | CRITICAL |
| E2E | Playwright | CRITICAL |
| Performance | Lighthouse | WARNING |
| Security | npm audit | high+: CRITICAL, moderate-: WARNING |

---

## /gonsautopilot:deploy — 빌드+배포

빌드와 배포를 실행합니다 (테스트 통과 전제).

```
/gonsautopilot:deploy
```

### 사전 조건

- 파이프라인이 잠금 상태가 아닐 것
- (권장) 최근 테스트 통과

### 실행 흐름

```
1. 설정 로드 + 파이프라인 생성
2. ANALYZE — 변경 분석, 빌드 대상 결정
3. BUILD — Docker 이미지 빌드
4. DEPLOY — Pre-deploy gate → 이미지 전송 → 카나리 배포
```

### Pre-deploy Gate (5가지 체크)

| # | 체크 항목 | 실패 시 |
|---|----------|---------|
| 1 | CRITICAL 테스트 통과 | 배포 중단 |
| 2 | Docker 이미지 존재 | 배포 중단 |
| 3 | 롤백용 이전 이미지 백업 | 배포 중단 |
| 4 | 운영서버 디스크 > 2GB | 배포 중단 |
| 5 | SSH 연결 정상 | 배포 중단 |

---

## /gonsautopilot:status — 상태 조회

파이프라인 상태, 배포 이력, 통계를 조회합니다.

```
/gonsautopilot:status              # 현재 파이프라인 상태
/gonsautopilot:status deployments  # 배포 이력 (최근 10건)
/gonsautopilot:status stats        # 성공률 통계
/gonsautopilot:status full         # 전체 리포트
```

### 출력 예시

```
═══════════════════════════════════════════════════════
  GonsAutoPilot — Pipeline Status
═══════════════════════════════════════════════════════

  Pipeline:  #20260206-160000-a1b2c3d
  상태:      success
  트리거:    manual
  시작:      2026-02-06T16:00:00+09:00
  완료:      2026-02-06T16:05:30+09:00

  ┌─ Stages
  │  analyze:   passed
  │  test:      passed
  │  build:     passed
  │  deploy:    passed
  │  verify:    passed
  │
  ├─ Changes
  │  frontend:  3 files
  │  backend:   0 files
  │
  └─ Stats
     총 실행: 12 | 성공: 10 | 실패: 2 | 연속 실패: 0

═══════════════════════════════════════════════════════
```

---

## /gonsautopilot:rollback — 수동 롤백

이전 안정 버전으로 즉시 롤백합니다.

```
/gonsautopilot:rollback            # 모든 서비스 롤백
/gonsautopilot:rollback frontend   # 프론트엔드만 롤백
/gonsautopilot:rollback backend    # 백엔드만 롤백
```

### 실행 흐름

```
1. 설정 로드
2. rollback-registry에서 이전 이미지 조회
3. 서비스별 롤백 실행
4. 헬스체크로 롤백 성공 확인
```

### rollback-registry

`state/rollback-registry.json`에서 서비스별 현재/이전 이미지 태그를 관리합니다:

```json
{
  "services": {
    "frontend": {
      "current": "myapp-front:a1b2c3d",
      "previous": "myapp-front:x9y8z7w"
    },
    "backend": {
      "current": "myapp-back:a1b2c3d",
      "previous": "myapp-back:x9y8z7w"
    }
  }
}
```

---

## 다음 단계

- [[파이프라인 흐름|Pipeline]] — 각 스테이지 상세 설명
- [[안전 장치|Safety]] — 3-Layer Safety 시스템
