# PostgreSQL in EC2

이 디렉토리는 EC2 환경에서 Docker Compose를 활용하여 PostgreSQL(버전 16) 데이터베이스 서버를 손쉽게 구축하기 위한 설정 파일들을 포함하고 있습니다.

## 파일 구성

- `docker-compose.yml`: PostgreSQL 컨테이너 배포 및 설정 정의 파일
- `.env.sample`: 환경 변수 설정 예시 파일 (실행 전에 `.env`로 복사하여 사용)
- `init.sql`: pgvector 확장을 자동으로 활성화하기 위한 DB 초기화 스크립트

## 파일 다운로드

원격 저장소에서 필요한 파일들을 아래 명령어를 사용하여 다운로드 받습니다.

```bash
# 디렉토리 생성 및 이동
mkdir -p ec2-postgresql && cd ec2-postgresql

# 필요한 파일들 다운로드 (curl)
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/ec2-postgresql/docker-compose.yml
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/ec2-postgresql/.env.sample
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/ec2-postgresql/init.sql
```

## 환경 변수 설정

1. `.env.sample` 파일을 복사하여 `.env` 파일을 생성합니다.
   ```bash
   cp .env.sample .env
   ```
2. 생성된 `.env` 파일을 열고, 목적에 맞게 값을 수정하거나 그대로 사용합니다. 기본 설정값은 다음과 같습니다:

   - **`POSTGRES_DB`**: 생성할 데이터베이스 이름 (기본값: `postgres`)
   - **`POSTGRES_USER`**: 데이터베이스 접속 계정명 (기본값: `postgres`)
   - **`POSTGRES_PASSWORD`**: 데이터베이스 접속 비밀번호 (기본값: `postgres`)
   - **`POSTGRES_PORT`**: 호스트와 매핑될 외부 접속 포트 (기본값: `5432`)

## 실행 방법

`.env` 파일이 준비되었다면, 아래 명령어를 통해 PostgreSQL 컨테이너를 백그라운드에서 실행합니다.

```bash
docker-compose up -d
```

## 확인 사항

- 정상 실행 확인:
  ```bash
  docker-compose ps
  ```
- 컨테이너 로그 확인:
  ```bash
  docker-compose logs -f
  ```

## 데이터 영속성 (Data Persistence)

PostgreSQL의 데이터는 `pgdata`라는 이름의 Docker 볼륨(`volumes`)으로 마운트되어 관리됩니다. 따라서 컨테이너를 삭제하고 재생성하더라도 데이터베이스 정보는 보존됩니다.
