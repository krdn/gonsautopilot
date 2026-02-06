# /gonsautopilot:rollback — 수동 롤백

이전 안정 버전으로 즉시 롤백합니다.

## 실행 방법

사용자가 `/gonsautopilot:rollback`을 호출하면 이 스킬이 실행됩니다.

## 실행 흐름

1. rollback-registry.json에서 각 서비스의 이전 이미지 태그 조회
2. 사용자에게 롤백 대상 확인
3. 운영서버에 이전 이미지로 Compose 배포
4. 헬스체크 실행
5. 결과 보고

## 사용하는 도구

- `lib/state-manager.sh` — rollback-registry 조회
- `lib/docker-utils.sh` — Docker Compose 배포
- `lib/health-check.sh` — 헬스체크
- `lib/notify.sh` — 알림
