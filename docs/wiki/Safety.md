# 3-Layer Safety

GonsAutoPilot의 3단계 안전 장치 시스템입니다.

## 개요

```
Layer 1: Pre-commit    — 커밋 전 품질 체크
Layer 2: Pre-deploy    — 배포 전 게이트
Layer 3: Post-deploy   — 배포 후 검증 + 자동 롤백
```

---

## Layer 1: Pre-commit (커밋 전)

커밋 전에 기본적인 품질 체크를 수행합니다.

### 체크 항목

| # | 항목 | 실패 시 |
|---|------|---------|
| 1 | 민감 정보 검사 | 커밋 차단 |
| 2 | .env 파일 커밋 방지 | 커밋 차단 |
| 3 | 대용량 파일 체크 (10MB+) | 경고 표시 |
| 4 | JSON/YAML 문법 검사 | 커밋 차단 |

### 민감 정보 패턴

다음 패턴이 코드에 포함되면 커밋을 차단합니다:

```
password\s*[:=]
api[_-]?key\s*[:=]
secret\s*[:=]
AWS_ACCESS_KEY
AWS_SECRET_KEY
PRIVATE_KEY
```

### 동작 방식

`hooks/pre-commit.sh`가 `PreToolUse` 훅으로 실행됩니다. Claude Code가 Bash 도구를 사용할 때마다 트리거됩니다.

---

## Layer 2: Pre-deploy Gate (배포 전)

5가지 조건을 **모두** 통과해야 배포가 진행됩니다.

### 체크 항목

| # | 항목 | 확인 방법 | 실패 시 |
|---|------|-----------|---------|
| 1 | CRITICAL 테스트 통과 | `pipeline.json`에서 test 스테이지 확인 | 배포 중단 |
| 2 | Docker 이미지 존재 | `docker images` 확인 | 배포 중단 |
| 3 | 롤백용 이전 이미지 백업 | `rollback-registry.json` 확인 | 배포 중단 |
| 4 | 운영서버 디스크 > 2GB | SSH `df -h` 확인 | 배포 중단 |
| 5 | SSH 연결 정상 | SSH 연결 테스트 | 배포 중단 |

### 실패 시

Pre-deploy gate가 하나라도 실패하면 배포를 진행하지 않습니다. 실패 원인을 `pipeline.json`에 기록하고 사용자에게 안내합니다.

---

## Layer 3: Post-deploy (배포 후)

배포 완료 후 스모크 테스트와 와치독으로 검증합니다.

### 3a. 스모크 테스트

```
1. GET /health → HTTP 200 확인
2. 추가 엔드포인트 검증 (설정에 정의된 endpoints)
3. 응답 시간 측정 → threshold 초과 시 실패
```

### 3b. 와치독 모니터링 (30초)

5초 간격으로 다음을 감시합니다:

| 항목 | 롤백 조건 |
|------|----------|
| HTTP 5xx 에러 | 1건이라도 발생 |
| 응답 시간 | 첫 측정 대비 200% 초과 |
| 컨테이너 재시작 | 배포 전 대비 증가 |

### 3c. 자동 롤백

이상이 감지되면 즉시 자동 롤백을 수행합니다:

```
1. rollback-registry.json에서 직전 성공 이미지 조회
2. docker-compose.prod.yml 이미지 태그 변경
3. docker compose up -d (운영서버)
4. 롤백된 서비스 헬스체크
5. 결과 보고 + 알림
```

### 캐스케이딩 롤백

여러 서비스를 배포할 때, 한 서비스가 실패하면 이미 배포된 다른 서비스도 함께 롤백합니다:

```
frontend 배포 성공 → backend 배포 실패
→ backend 롤백 + frontend도 롤백
```

---

## 안전 장치 설정

`gonsautopilot.yaml`에서 안전 장치를 설정합니다:

```yaml
safety:
  auto_rollback: true           # 실패 시 자동 롤백
  max_consecutive_failures: 3   # 연속 N회 실패 시 잠금 + 알림
  notify:
    email: true
    method: "/notify-important"
```

---

## 다음 단계

- [[에스컬레이션 정책|Escalation]] — 연속 실패 시 대응
- [[파이프라인 흐름|Pipeline]] — 파이프라인 상세
