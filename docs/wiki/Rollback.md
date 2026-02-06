# 롤백

이전 안정 버전으로 서비스를 복원하는 방법입니다.

## 자동 롤백 vs 수동 롤백

| 구분 | 트리거 | 시점 |
|------|--------|------|
| **자동** | 배포/검증 실패 시 자동 실행 | 파이프라인 중 |
| **수동** | `/gonsautopilot:rollback` 명령어 | 사용자 판단 |

---

## 수동 롤백

### 사용법

```
/gonsautopilot:rollback            # 모든 서비스 롤백
/gonsautopilot:rollback frontend   # 프론트엔드만 롤백
/gonsautopilot:rollback backend    # 백엔드만 롤백
```

### 실행 흐름

```
1. 설정 로드
2. rollback-registry에서 이전 이미지 조회
3. 이전 이미지가 있는지 확인
4. 서비스별 롤백 실행:
   a. docker-compose.prod.yml 이미지 태그 변경
   b. docker compose up -d --no-deps <service>
   c. 헬스체크 (최대 60초)
5. 롤백 결과 보고
```

---

## rollback-registry

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

### 작동 원리

1. **빌드 시**: 새 이미지가 빌드되면 기존 이미지를 `previous`로 이동
2. **배포 시**: `current`를 새 이미지로 업데이트
3. **롤백 시**: `previous` 이미지로 복원

---

## 자동 롤백 시나리오

### 카나리 배포 실패

```
새 컨테이너 시작 → 헬스체크 실패
→ 이전 이미지로 자동 복원
→ 파이프라인 상태: failed
```

### 와치독 이상 감지

```
배포 성공 → 와치독 30초 모니터링
→ 5xx 에러 감지 또는 응답시간 급증
→ 모든 서비스 자동 롤백
→ 파이프라인 상태: failed
```

### 캐스케이딩 롤백

여러 서비스를 순차 배포할 때, 나중 서비스가 실패하면 먼저 배포된 서비스도 함께 롤백합니다:

```
frontend 배포 성공 → backend 배포 실패
→ backend 롤백 + frontend도 롤백
→ 모든 서비스가 이전 안정 버전으로 복원
```

---

## 롤백 실패 시

롤백 자체가 실패하면:

1. 에러 로그 저장
2. 파이프라인 잠금
3. `/notify-important` 이메일 알림
4. 수동 개입 필요

---

## 롤백 이력

배포 이력에서 롤백 기록을 확인할 수 있습니다:

```
/gonsautopilot:status deployments
```

롤백된 배포는 `(rollback)` 표시와 함께 나타납니다.

---

## 다음 단계

- [[상태 조회|Status]] — 파이프라인 상태 확인
- [[에스컬레이션 정책|Escalation]] — 연속 실패 대응
