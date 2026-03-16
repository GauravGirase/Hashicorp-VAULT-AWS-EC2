#!/bin/bash
set -eou pipefail
exec > >(tee /var/log/vault-init.log) 2>&1

NODE_NUM=3
NODE_IP=10.0.3.10
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1
KMS_KEY_ALIAS=alias/vault-auto-unseal
BACKUP_BUCKET=vault-raft-backups-prod

apt-get update
apt-get install -y unzip awscli wget

# Create vault user
useradd --system --home /etc/vault.d --shell /bin/false vault

cd /tmp

aws s3 cp s3://my-internal-artifacts/vault/vault_1.15.5_linux_amd64.zip .

unzip vault_1.15.5_linux_amd64.zip
mv vault /usr/local/bin/
chmod +x /usr/local/bin/vault

vault --version

# Install CloudWatch Agent
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb

# Prepare directories
mkdir -p /opt/vault/data /etc/vault/tls /etc/vault.d
chown -R vault:vault /opt/vault
chmod 700 /opt/vault/data

# Pull TLS certs from SSM
aws ssm get-parameter --name /vault/tls/ca-cert --with-decryption \
--query Parameter.Value --output text > /etc/vault/tls/ca.crt

aws ssm get-parameter --name /vault/tls/node-${NODE_NUM}-cert --with-decryption \
--query Parameter.Value --output text > /etc/vault/tls/vault.crt

aws ssm get-parameter --name /vault/tls/node-${NODE_NUM}-key --with-decryption \
--query Parameter.Value --output text > /etc/vault/tls/vault.key

chmod 640 /etc/vault/tls/*
chown root:vault /etc/vault/tls/vault.key

# Vault config
cat > /etc/vault.d/vault.hcl <<EOF
ui = false
cluster_name = "vault-prod"
log_level = "warn"
log_format = "json"

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/tls/vault.crt"
  tls_key_file = "/etc/vault/tls/vault.key"
  tls_client_ca_file = "/etc/vault/tls/ca.crt"
  tls_min_version = "tls1.3"
}

storage "raft" {
  path = "/opt/vault/data"
  node_id = "vault-node-${NODE_NUM}"

  retry_join { leader_api_addr = "https://10.0.1.10:8200" }
  retry_join { leader_api_addr = "https://10.0.2.10:8200" }
  retry_join { leader_api_addr = "https://10.0.3.10:8200" }
}

seal "awskms" {
  region     = "${REGION}"
  kms_key_id = "${KMS_KEY_ALIAS}"
}

api_addr = "https://${NODE_IP}:8200"
cluster_addr = "https://${NODE_IP}:8201"
EOF

chown root:vault /etc/vault.d/vault.hcl
chmod 640 /etc/vault.d/vault.hcl

# Systemd service
cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description=Vault
After=network.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault
systemctl start vault

# Audit log directory
mkdir -p /var/log/vault
chown vault:vault /var/log/vault

# CloudWatch config
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/vault/audit.log",
            "log_group_name": "/vault/audit",
            "log_stream_name": "vault-node-${NODE_NUM}"
          }
        ]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
-a start \
-c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "Vault node ${NODE_NUM} initialization complete"