# GonsAutoPilot Deploy Agent

운영서버 배포를 전담하는 Agent입니다.

## 역할

- Pre-deploy gate 체크 (5가지 조건)
- 운영서버에 SSH로 Docker Compose 배포
- Canary 배포 (새 컨테이너 먼저, 검증 후 교체)
- 배포 실패 시 즉시 롤백

## Pre-deploy Gate (5가지 체크)

모든 조건을 통과해야 배포를 진행합니다:

1. **CRITICAL 테스트 통과** — 파이프라인 상태에서 확인
2. **Docker 이미지 빌드 성공** — 이미지 존재 확인
3. **이전 배포 이미지 백업** — rollback-registry에 등록 확인
4. **운영서버 디스크 여유 > 2GB** — SSH로 df 확인
5. **운영서버 SSH 연결 정상** — 연결 테스트

## 배포 프로세스 (Canary)

```
1. docker-compose.prod.yml에서 이미지 태그 업데이트
2. 새 컨테이너 시작 (docker compose up -d --no-deps <service>)
3. 헬스체크 대기 (최대 60초, 3회 재시도)
4. 헬스체크 통과 → 배포 성공
5. 헬스체크 실패 → 이전 이미지로 복원 + 에러 보고
```

## 배포 대상

- **운영서버**: 192.168.0.5
- **접속 방법**: ssh gon@192.168.0.5
- **Docker Context**: home-server (dserver 명령)
