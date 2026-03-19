# EC2 Auto Setup 스크립트 (setup-ec2.sh)

이 스크립트는 Amazon Linux 2023 기반의 EC2 인스턴스 초기 설정을 자동화하고, 동적 공인 IP를 Route53에 자동으로 업데이트하는 환경을 구축합니다.

## 대상 환경

- **OS**: Amazon Linux 2023
- **사용자 권한**: root 권한 필요 (`sudo`를 통해 실행)
- **AWS 권한**: EC2 인스턴스에 Route53 레코드 업데이트 권한이 있는 IAM Role 부여 권장 (미부여 시 AWS CLI 액세스 키 사용 가능)

## 환경 변수 설정 (`.ec2-setup.env.sample` 참조)

스크립트 실행 시 사용되는 주요 환경 변수들은 다음과 같으며, `.ec2-setup.env.sample` 파일에도 가이드되어 있습니다.

- **`ZONE_ID`**: Route 53 호스팅 영역 ID (예: `Z1234567890`)
  - 확인 방법: AWS CLI 명령어 `aws route53 list-hosted-zones` 실행
- **`RECORD_NAME`**: 동적으로 IP를 업데이트할 대상 A 레코드 (예: `example.intuaos.com`)
- **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`**: AWS CLI 인증을 위한 보안 자격 증명
  - **권장 사항**: 인스턴스에 적절한 권한을 가진 IAM Role이 부여된 경우, 이 값들은 비워두시는 것이 보안상 안전합니다.
- **`AWS_DEFAULT_REGION`**: AWS 리전 (기본값: `ap-northeast-2`, 서울 리전)
- **`PUBLIC_IP`**: 스크립트 실행 시 EC2 내부 메타데이터 서버(`169.254.169.254`)를 호출하여 배포 인스턴스의 공인 IP를 자동으로 식별합니다. (사용자가 직접 입력하지 않습니다.)

## 주요 기능

1. **사용자 환경 설정 관리 (`~/ec2-setup.env`)**
   - 인터랙티브 프롬프트를 통해 사용자 입력(Route53 Hosted Zone ID, 레코드 이름, 리전, AWS 크레덴셜 등)을 받아 환경 설정 파일을 생성/재사용합니다.
2. **시스템 기본 설정**
   - 시스템 패키지 업데이트 (`yum update -y`)
   - 타임존을 한국 시간(`Asia/Seoul`)으로 설정
   - 필수 패키지 설치 (`awscli`, `docker`)
3. **Docker 및 Docker Compose 설치**
   - Docker 서비스 시작 및 부팅 시 자동 실행 설정
   - `ec2-user`를 `docker` 그룹에 추가
   - 최신 버전의 Docker Compose를 CLI 플러그인 형태로 다운로드 및 권한 설정
4. **AWS CLI 구성**
   - 입력받은 Access Key/Secret Key로 AWS CLI 설정 (IAM Role 사용 시 이 과정은 생략 가능)
5. **Route53 Dynamic DNS (DDNS) 자동 업데이트 구성**
   - 인스턴스의 공인 IP를 동적으로 가져와 Route53 A 레코드를 업데이트하는 쉘 스크립트(`/usr/local/bin/update-route53.sh`) 생성
   - 설정 변수를 `/etc/route53-vars` 파일에 저장하여 스크립트 실행 시 참조
   - 부팅 시 자동으로 DDNS 스크립트를 실행하도록 Systemd 서비스(`update-route53.service`) 등록 및 활성화
6. **즉시 실행 및 테스트**
   - 모든 설정 완료 후 즉시 Route53 통신 테스트 및 IP 업데이트를 수행합니다.

## 실행 방법

### 방법 1: 스크립트 다운로드 후 실행
```bash
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/ec2-init/setup-ec2.sh
chmod +x setup-ec2.sh
sudo ./setup-ec2.sh
```

### 방법 2: 파이프라인을 통해 즉시 실행
```bash
curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/ec2-init/setup-ec2.sh | sudo bash
```

## 확인 사항

스크립트가 완료된 후 시스템 재부팅(`sudo reboot`)을 권장하며, 다음 명령어를 통해 설정이 정상적으로 완료되었는지 확인할 수 있습니다.

- `.env` 설정 확인: `cat ~/ec2-setup.env`
- 타임존 설정 확인: `timedatectl`
- Docker Compose 버젼 확인: `docker-compose version`
- Route53 DDNS 시스템 서비스 상태: `systemctl status update-route53`
