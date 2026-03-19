#!/bin/bash

# === 사용자 변수 설정 (여기만 수정하세요) ===
# ZONE_ID="Z1234567890"  # Route53 Hosted Zone ID (aws route53 list-hosted-zones)
# RECORD_NAME="example.intuaos.com"  # 업데이트할 A 레코드 FQDN
# AWS_ACCESS_KEY_ID=""  # IAM Role 사용 시 빈 값 (권장)
# AWS_SECRET_ACCESS_KEY=""
# AWS_DEFAULT_REGION="ap-northeast-2"  # 서울 리전
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || curl -s http://169.254.169.254/latest/meta-data/public-hostname)

# .env 파일 경로 (스크립트를 실행하는 사용자 홈 디렉토리 기준)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
ENV_FILE="$ACTUAL_HOME/ec2-setup.env"

# 사용자 입력 함수 (기본값 지원)
read_var() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local value
  
  if [[ -f "$ENV_FILE" ]]; then
    value=$(grep "^$varname=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//')
    [[ -n "$value" ]] && default="$value"
  fi
  
  if [[ -n "$default" ]]; then
    read -p "$prompt [기본: $default]: " value
    value=${value:-$default}
  else
    read -p "$prompt: " value
  fi
  
  echo "$varname=\"$value\""
}

# .env 파일 생성/업데이트
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S KST')] $1"; }
create_env() {
  log "설정 파일 생성: $ENV_FILE"
  cat > "$ENV_FILE" << 'EOF'
# EC2 Auto Setup Environment (수정 후 재실행)
EOF
  
  # 사용자 입력
  echo "$(read_var 'Route53 Hosted Zone ID' ZONE_ID)" >> "$ENV_FILE"
  echo "$(read_var 'Route53 Record Name (e.g. intuaos.com)' RECORD_NAME)" >> "$ENV_FILE"
  echo "$(read_var 'AWS Region (e.g. ap-northeast-2)' AWS_DEFAULT_REGION 'ap-northeast-2')" >> "$ENV_FILE"
  echo "$(read_var 'AWS Access Key ID (IAM Role 사용 시 빈 값)' AWS_ACCESS_KEY_ID)" >> "$ENV_FILE"
  echo "$(read_var 'AWS Secret Key (IAM Role 사용 시 빈 값)' AWS_SECRET_ACCESS_KEY)" >> "$ENV_FILE"
  
  chmod 600 "$ENV_FILE"
  source "$ENV_FILE"
  log ".env 파일 생성 완료"
}

# 메인 실행
log "=== EC2 Auto Setup 시작 (Amazon Linux 2023) ==="

# .env 확인 및 생성
if [[ ! -f "$ENV_FILE" ]]; then
  create_env
else
  log ".env 파일 존재. 재사용? (y/n)"
  read -r reuse
  [[ "$reuse" != "y" && "$reuse" != "Y" ]] && create_env
  source "$ENV_FILE"
fi

log "설정 확인:"
log "  ZONE_ID: ${ZONE_ID:-없음}"
log "  RECORD_NAME: ${RECORD_NAME:-없음}"
log "  REGION: ${AWS_DEFAULT_REGION:-ap-northeast-2}"

# 1. 시스템 업데이트 + timezone
log "1. 시스템 업데이트 및 timezone 설정"
sudo yum update -y
sudo timedatectl set-timezone Asia/Seoul
log "Timezone: $(timedatectl | grep "Time zone")"

sudo yum install -y awscli docker

# 2. AWS CLI 구성
if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"
  log "AWS CLI 키 구성 완료"
else
  log "IAM Role 사용 확인: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '실패 - IAM Role 없음')"
fi

# 3. Docker & Compose
log "3. Docker 설치"
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# sudo mkdir -p /usr/local/lib/docker/cli-plugins
# LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep browser_download_url | grep linux | grep -v checksum | head -1 | cut -d '"' -f 4)
# sudo curl -L "$LATEST_COMPOSE" -o /usr/local/lib/docker/cli-plugins/docker-compose
# sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
# log "Docker Compose: $(docker compose version --short)"

# sudo rm /usr/local/lib/docker/cli-plugins/docker-compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
log "Docker Compose: $(docker-compose version --short)" # 또는 docker compose version


# 4. Route53 환경 배포 및 스크립트 업데이트
log "4. Route53 구성 배포"
# /etc/route53-vars 업데이트 (.env 동기화)
sudo tee /etc/route53-vars > /dev/null << EOF
ZONE_ID="$ZONE_ID"
RECORD_NAME="$RECORD_NAME"
AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
EOF
sudo chmod 600 /etc/route53-vars

# update-route53.sh 업데이트 (동적 버전)
sudo tee /usr/local/bin/update-route53.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

source /etc/route53-vars

get_ip() {
  TOKEN=$(timeout 10 curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || echo "TOKEN_FAIL")
  
  # Public IP 우선순위
  [[ "$TOKEN" != "TOKEN_FAIL" ]] && IP=$(timeout 5 curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || echo "") && [[ -n "$IP" ]] && echo "$IP" && return
  
  # 외부 확인
  timeout 5 curl -s https://checkip.amazonaws.com || timeout 5 curl -s ifconfig.me || \
  ([[ "$TOKEN" != "TOKEN_FAIL" ]] && timeout 5 curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-ipv4) || hostname -i | awk '{print $1}'
}

IP=$(get_ip)
[[ -z "$IP" || "$IP" == "TOKEN_FAIL" ]] && { echo "IP 획득 실패"; exit 1; }

echo "업데이트: $RECORD_NAME -> $IP"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch '{
  "Comment": "EC2 boot auto-update",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "'"$RECORD_NAME"'",
      "Type": "A",
      "TTL": 300,
      "ResourceRecords": [{"Value": "'"$IP"'"}]
    }
  }]
}' || { echo "Route53 실패"; exit 1; }

echo "Route53 성공: $IP"
EOF

sudo chmod +x /usr/local/bin/update-route53.sh

# 5. Systemd 서비스 업데이트
sudo tee /etc/systemd/system/update-route53.service > /dev/null << EOF
[Unit]
Description=Route53 Dynamic DNS Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
EnvironmentFile=/etc/route53-vars
ExecStart=/usr/local/bin/update-route53.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable update-route53.service --now
log "Systemd 서비스 재배포 완료"

# 6. 테스트
log "6. 즉시 테스트"
sleep 5
sudo /usr/local/bin/update-route53.sh

log "=== 완료! 재부팅 권장: sudo reboot ==="
log "확인:"
log "cat $ENV_FILE"
log "docker compose version"
log "timedatectl"
log "systemctl status update-route53"