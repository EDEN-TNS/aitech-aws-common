#!/bin/bash

# === 사용자 변수 설정 (여기만 수정하세요) ===
# PUBLIC_IP는 update-route53.sh의 get_ip()에서 동적으로 획득

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || curl -s http://169.254.169.254/latest/meta-data/public-hostname)

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
ENV_FILE="$ACTUAL_HOME/ec2-setup.env"

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
    read -p "$prompt [기본: $default]: " value </dev/tty || value=""
    value=${value:-$default}
  else
    read -p "$prompt: " value </dev/tty || value=""
  fi

  echo "$varname=\"$value\""
}

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S KST')] $1"; }

create_env() {
  log "설정 파일 생성: $ENV_FILE"
  cat > "$ENV_FILE" << 'EOF'
# EC2 Auto Setup Environment (수정 후 재실행)
EOF

  echo "$(read_var 'Route53 Hosted Zone ID' ZONE_ID)" >> "$ENV_FILE"
  echo "$(read_var 'Route53 Record Name (e.g. intuaos.com)' RECORD_NAME)" >> "$ENV_FILE"
  echo "$(read_var 'AWS Region (e.g. ap-northeast-2)' AWS_DEFAULT_REGION 'ap-northeast-2')" >> "$ENV_FILE"
  echo "$(read_var 'AWS Access Key ID (IAM Role 사용 시 빈 값)' AWS_ACCESS_KEY_ID)" >> "$ENV_FILE"
  echo "$(read_var 'AWS Secret Key (IAM Role 사용 시 빈 값)' AWS_SECRET_ACCESS_KEY)" >> "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  source "$ENV_FILE"
  log ".env 파일 생성 완료"
}

log "=== EC2 Auto Setup 시작 (Ubuntu) ==="

if [[ ! -f "$ENV_FILE" ]]; then
  create_env
else
  log ".env 파일 존재. 재사용? (y/n)"
  read -r reuse </dev/tty || reuse="y"
  [[ "$reuse" != "y" && "$reuse" != "Y" ]] && create_env
  source "$ENV_FILE"
fi

log "설정 확인:"
log "  ZONE_ID: ${ZONE_ID:-없음}"
log "  RECORD_NAME: ${RECORD_NAME:-없음}"
log "  REGION: ${AWS_DEFAULT_REGION:-ap-northeast-2}"

# 1. 시스템 업데이트 + timezone
log "1. 시스템 업데이트 및 timezone 설정"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
sudo timedatectl set-timezone Asia/Seoul
log "Timezone: $(timedatectl | grep "Time zone")"

# AWS CLI 설치 (Ubuntu)
sudo apt-get install -y unzip curl
ARCH=$(uname -m); [[ "$ARCH" == "aarch64" ]] && AWS_ARCH="aarch64" || AWS_ARCH="x86_64"
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws

# 2. AWS CLI 구성
if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"
  log "AWS CLI 키 구성 완료"
else
  log "IAM Role 사용 확인: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '실패 - IAM Role 없음')"
fi

# 3. Docker 설치 (Ubuntu 공식 방법)
log "3. Docker 설치"
sudo apt-get install -y ca-certificates gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker "$ACTUAL_USER"

DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
log "Docker Compose: $(docker compose version)"

# 4. Route53 환경 배포 및 스크립트 업데이트
log "4. Route53 구성 배포"
sudo tee /etc/route53-vars > /dev/null << EOF
ZONE_ID="$ZONE_ID"
RECORD_NAME="$RECORD_NAME"
AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
EOF
sudo chmod 600 /etc/route53-vars

sudo tee /usr/local/bin/update-route53.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

source /etc/route53-vars

get_ip() {
  local TOKEN IP
  TOKEN=$(timeout 10 curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null) || TOKEN=""

  if [[ -n "$TOKEN" ]]; then
    IP=$(timeout 5 curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    [[ -n "$IP" ]] && echo "$IP" && return
  fi

  IP=$(timeout 5 curl -s https://checkip.amazonaws.com 2>/dev/null)
  [[ -n "$IP" ]] && echo "$IP" && return

  IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null)
  [[ -n "$IP" ]] && echo "$IP" && return

  if [[ -n "$TOKEN" ]]; then
    IP=$(timeout 5 curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
    [[ -n "$IP" ]] && echo "$IP" && return
  fi

  hostname -i | awk '{print $1}'
}

IP=$(get_ip)
[[ -z "$IP" ]] && { echo "IP 획득 실패"; exit 1; }

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
log "systemctl status update-route53.service"
