# 파이프라인 흐름

GonsAutoPilot의 5-Stage 파이프라인 상세 설명입니다.

## 전체 흐름도

```
ANALYZE → TEST → BUILD → DEPLOY → VERIFY
   │         │       │        │        │
   │         │       │        │        └─ 스모크 테스트 + 와치독 30초
   │         │       │        └─ Pre-deploy gate + 카나리 배포
   │         │       └─ Docker 이미지 빌드 + 태깅
   │         └─ Unit/E2E/Performance/Security 병렬 실행
   └─ 변경 파일 분석 + 테스트/빌드 대상 결정
```

---

## Stage 1: ANALYZE

변경 파일을 분석하여 이후 스테이지의 실행 계획을 결정합니다.

### 변경 파일 분류

| 카테고리 | 파일 패턴 |
|----------|----------|
| **frontend** | `.tsx`, `.jsx`, `src/pages/`, `src/components/`, `tailwind.config` |
| **backend** | `server/`, `api/`, `.go`, `.py`, `src/api/`, `src/routes/` |
| **database** | `migrations/`, `prisma/`, `drizzle/`, `.sql` |
| **config** | `docker/`, `.github/`, `Dockerfile`, `package.json` |
| **test** | `.test.ts`, `.spec.ts`, `__tests__/` |

### 스킵 결정 로직

```
frontend만 변경 → backend 테스트 스킵
backend만 변경 → performance 테스트 스킵
config만 변경 → 단위테스트 스킵, 빌드+배포만
shared/config 변경 → 모든 테스트 실행
변경 없음 → 전체 파이프라인 스킵
```

---

## Stage 2: TEST

필요한 테스트를 병렬로 실행합니다.

### 실행 순서

```
                ┌─ Unit Test (Jest/Vitest)
                │
ANALYZE 결과 ─→ ├─ E2E Test (Playwright)         ← 병렬 실행
                │
                ├─ Performance Test (Lighthouse)
                │
                └─ Security Test (npm audit)
```

### 판정 기준

| 결과 | 조건 | 파이프라인 영향 |
|------|------|----------------|
| **passed** | 모든 CRITICAL 통과 | 다음 스테이지로 |
| **warning** | WARNING만 존재 | 기록 후 계속 |
| **failed** | CRITICAL 1개 이상 실패 | 파이프라인 중단 |

---

## Stage 3: BUILD

Docker 이미지를 빌드하고 태깅합니다.

### 빌드 대상 결정

```
frontend 변경 → frontend 빌드
backend 변경 → backend 빌드
shared/config 변경 → 둘 다 빌드
```

### 빌드 프로세스

```
1. Dockerfile 존재 확인
2. docker build 실행
3. 태그 생성 (git-sha / semver / timestamp)
4. rollback-registry에 이전 태그 저장
5. (배포 대상 서버에) docker save + scp 전송
```

---

## Stage 4: DEPLOY

Pre-deploy 검증 후 카나리 방식으로 배포합니다.

### Pre-deploy Gate

5가지 조건을 **모두** 통과해야 배포가 진행됩니다:

```
1. CRITICAL 테스트 통과 확인
2. Docker 이미지 존재 확인
3. 롤백용 이전 이미지 백업 확인
4. 운영서버 디스크 여유 > 2GB
5. SSH 연결 정상
```

### 카나리 배포 프로세스

```
1. docker-compose.prod.yml에서 이미지 태그 업데이트
2. 새 컨테이너 시작 (docker compose up -d --no-deps <service>)
3. 헬스체크 대기 (최대 60초, 3회 재시도)
4. 통과 → 배포 성공
5. 실패 → 이전 이미지로 복원 (자동 롤백)
```

### 캐스케이딩 롤백

여러 서비스를 배포할 때, 한 서비스가 실패하면 이미 배포된 다른 서비스도 함께 롤백합니다:

```
frontend 배포 성공 → backend 배포 실패
→ backend 롤백 + frontend도 롤백
```

---

## Stage 5: VERIFY

배포 완료 후 서비스를 검증합니다.

### 스모크 테스트

```
1. GET /health → HTTP 200 확인
2. 추가 엔드포인트 검증 (설정에 정의된 endpoints)
3. 응답 시간 측정 → threshold 초과 시 실패
```

### 와치독 모니터링 (30초)

5초 간격으로 다음을 감시합니다:

| 항목 | 롤백 조건 |
|------|----------|
| HTTP 5xx 에러 | 1건이라도 발생 |
| 응답 시간 | 첫 측정 대비 200% 초과 |
| 컨테이너 재시작 | 배포 전 대비 증가 |

### 검증 실패 시

```
1. 모든 서비스 자동 롤백
2. rollback-registry에서 이전 이미지 복원
3. 복원 후 헬스체크
4. 에스컬레이션 체크 (연속 실패 횟수)
```

---

## 파이프라인 상태 저장

모든 파이프라인 실행 기록은 `state/pipeline.json`에 저장됩니다:

```json
{
  "pipelines": [
    {
      "pipeline_id": "20260206-160000-a1b2c3d",
      "status": "success",
      "trigger": "manual",
      "started_at": "2026-02-06T16:00:00+09:00",
      "finished_at": "2026-02-06T16:05:30+09:00",
      "stages": [
        { "name": "analyze", "status": "passed" },
        { "name": "test", "status": "passed" },
        { "name": "build", "status": "passed" },
        { "name": "deploy", "status": "passed" },
        { "name": "verify", "status": "passed" }
      ],
      "changes": { "categories": { "frontend": [...], "backend": [] } },
      "decisions": [
        { "action": "skip_backend_test", "reason": "백엔드 파일 변경 없음" }
      ]
    }
  ],
  "current": "20260206-160000-a1b2c3d",
  "stats": {
    "total_runs": 12,
    "success_count": 10,
    "failure_count": 2,
    "consecutive_failures": 0
  }
}
```

---

## 다음 단계

- [[안전 장치|Safety]] — 3-Layer Safety 상세
- [[Multi-Agent 시스템|Agents]] — Agent 역할 분담
