# Hashicorp-VAULT-AWS-EC2
## Architecture
!["vault-architecture"](/doc/architecture.png)
## Summary
This project implements a highly available and production-ready deployment of HashiCorp Vault on Amazon EC2 using Infrastructure as Code with Terraform.

The architecture consists of a 3-node Vault cluster configured with integrated storage (Raft) to ensure high availability and fault tolerance. Each node is securely deployed with TLS encryption using a self-signed Certificate Authority, enabling encrypted communication between clients and cluster members.

### The setup includes:
- Automated infrastructure provisioning using Terraform
- Secure cluster formation with Raft consensus
- TLS-enabled communication across all nodes
- Initalization and unsealing workflow
- Configuration of the KV secrets engine for secure secret storage
This project demonstrates best practices for deploying Vault in a cloud environment, focusing on security, scalability, and reliability, and serves as a strong foundation for extending into advanced features such as auto-unseal, dynamic secrets, and fine-grained access control.
## Install
- aws cli
- terraform

## Private CA
- Install cfssl and cfssljson
```bash
wget -q --show-progress --https-only --timestamping \
  https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 \
  https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
# or
sudo apt-get install golang-cfssl
```
```bash
mkdir -p /tmp/vault-tls && cd /tmp/vault-tls
vi ca-config.json
vi ca-csr.json
```
### Generate CA
```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
# verify
ca-config.json  ca-csr.json  ca-key.pem  ca.csr  ca.pem
```
!["cert generation"](doc/1-generate-CA.png)
### Generate certificate for each Node
```bash
vi vault-node-1-csr.json
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server vault-node-1-csr.json | cfssljson -bare vault-node-1
```
**Note:** Repeat for node2 and node3

### Upload certs in ssm (Note: Make sure you have created KMS first using terraform)
```bash
aws ssm put-parameter --name /vault/tls/ca-cert --value file://ca.pem --type SecureString --key-id alias/vault-auto-unseal --overwrite

# FOR NODE 1
aws ssm put-parameter --name /vault/tls/node-1-cert \
--value file://vault-node-1.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite

aws ssm put-parameter --name /vault/tls/node-1-key \
--value file://vault-node-1-key.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite

# FOR NODE 2
aws ssm put-parameter --name /vault/tls/node-2-cert \
--value file://vault-node-2.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite

aws ssm put-parameter --name /vault/tls/node-2-key \
--value file://vault-node-2-key.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite
# FOR NODE 3
aws ssm put-parameter --name /vault/tls/node-3-cert \
--value file://vault-node-3.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite

aws ssm put-parameter --name /vault/tls/node-3-key \
--value file://vault-node-3-key.pem \
--type SecureString --key-id alias/vault-auto-unseal --overwrite
```bash
user data scripts failed:
terraform taint aws_instance.vault_nodes[0]
```

## User data scripts failed (fixed)
**Use session manager:**
# Pull TLS cert
```bash
aws --region ap-south-1 ssm get-parameter --name /vault/tls/ca-cert --with-decryption \
--query Parameter.Value --output text | sudo tee /etc/vault/tls/ca.crt > /dev/null
```
## Pull key
```bash
# Pull TLS certs from SSM
aws --region ap-south-1 ssm get-parameter --name /vault/tls/ca-cert --with-decryption \
--query Parameter.Value --output text | sudo tee /etc/vault/tls/ca.crt > /dev/null

aws --region ap-south-1 ssm get-parameter --name /vault/tls/node-1-cert --with-decryption \
--query Parameter.Value --output text | sudo tee  /etc/vault/tls/vault.crt > /dev/null

aws --region ap-south-1 ssm get-parameter --name /vault/tls/node-1-key --with-decryption \
--query Parameter.Value --output text | sudo tee /etc/vault/tls/vault.key > /dev/null
```


### vault.hcl
```bash
sudo tee /etc/vault.d/vault.hcl > /dev/null <<EOF
ui = false
cluster_name = "vault-prod"
log_level = "warn"
log_format = "json"

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/tls/vault.crt"
  tls_key_file = "/etc/vault/tls/vault.key"
  tls_client_ca_file = "/etc/vault/tls/ca.crt"
  tls_min_version = "tls13"
}

storage "raft" {
  path = "/opt/vault/data"
  node_id = "vault-node-1"

  #retry_join { leader_api_addr = "https://10.0.1.10:8200" }
  #retry_join { leader_api_addr = "https://10.0.2.10:8200" }
  #retry_join { leader_api_addr = "https://10.0.3.10:8200" }
}

seal "awskms" {
  region     = "ap-south-1"
  kms_key_id = "alias/vault-auto-unseal"
}

api_addr = "https://10.0.1.10:8200"
cluster_addr = "https://10.0.1.10:8201"
EOF
```
### Permissions
```bash
sudo chown root:vault /etc/vault.d/vault.hcl
chmod 640 /etc/vault.d/vault.hcl
```
### Create vault service
```bash
sudo tee /etc/systemd/system/vault.service > /dev/null <<EOF
[Unit]
Description=Vault
After=network.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
Restart=always
LimitNOFILE=65536
# Add this line:
CapabilityBoundingSet=CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
[Install]
WantedBy=multi-user.target
EOF
```
### enable the service
```bash
sudo setcap cap_ipc_lock=+ep /usr/local/bin/vault
sudo systemctl daemon-reload
sudo systemctl enable vault
sudo systemctl start vault
sudo systemctl restart vault
sudo systemctl status vault
sudo /usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
```
### Audit log directory
```bash
sudo mkdir -p /var/log/vault
sudo chown vault:vault /var/log/vault
```

### CloudWatch config
```bash
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/vault/audit.log",
            "log_group_name": "/vault/audit",
            "log_stream_name": "vault-node-1"
          }
        ]
      }
    }
  }
}
EOF
```
## run
```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
-a start \
-c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
```

## Vault initialization
```bash
sudo -E vault operator init \
-recovery-shares=5 \
-recovery-threshold=3 \
-format=json | tee /tmp/vault-init.json
```
!["vault status"](/doc/vault-status.png)

### vault-init.json
```bash
{
  "unseal_keys_b64": [],
  "unseal_keys_hex": [],
  "unseal_shares": 1,
  "unseal_threshold": 1,
  "recovery_keys_b64": [
    "*****",
    "*****",
    "*****",
    "*****",
    "*****",

  ],
  "recovery_keys_hex": [
    "18c2fa23aa532b3aa7704d5d812985f9becb935a42c06e5f94926bd578829a4c54",
    "c0d8682534c48c33dc6cb71d325bc5ba8c22107b4b9dfe8fa5a3ba68788b00831b",
    "547f6362a73eea740ac39111523fda404e47e8e2c03118643310c49f8417bd836b",
    "364c9b0ebdb48096a84d37d1c17b2f5e2fce97846dd2af10713da89c9b83136aa1",
    "5b2054c08bf993dc04997f1475e2fe1f4869fc27fc36a233b0f213f916872309e6"
  ],
  "recovery_keys_shares": 5,
  "recovery_keys_threshold": 3,
  "root_token": "TOKEN"
}
```
### Test
```bash
vault login <root_token>
# vault login 12D4ABCFGJDKDL
vault secrets enable -path=secret kv-v2
vault secrets list
vault kv put secret/hello value="Vault is working!"
vault kv get secret/hello
```
!["Vault login"](doc/3-vault-login.png)
### Create new secrets
!["new secret"](doc/4-create-secrets.png)
### Secrets list
!["Vault login"](doc/4-secrets-list.png)
### Verify Raft cluster information
```bash
vault operator raft list-peers
```
!["raft cluster"](doc/6-raft-cluster-info.png)

## Store this vault-init.json in secret manager
```bash
cat /tmp/vault-init.json | aws --region ap-south-1 secretsmanager create-secret \
--name vault/init-output \
--secret-string file:///tmp/vault-init.json \
--kms-key-id alias/vault-auto-unseal
```
## Vault configuration-Auth,Policies,secrets
### Always enable audit first-before any secret or auth setup
```bash
vault audit enable file file_path=/var/log/vault/audit.log
vault audit enable syslog tag='vault' facility='AUTH'

# Verify
vault audit list
```

## Enable secret engine
### KV v2- for static secrets (API keys, config, certs)
```bash
vault secrets enable -path=secret kv-v2
```
### Dynamic database credentials
```bash
vault secrets enable -path=database database
```

### AWS dynamic IAM credentials
```bash
vault secrets enable aws
```
### PKI-for issuing internal TLS/SSL certs
```bash
vault secrets enable pki 
vault secrets tune -max-lease-ttl=87600h pki
```

## Configure AWS IAM auth method (for EC2 and ECS)
```bash
vault auth enable aws # if not done already
```
```bash
vault write auth/aws/config/client \
iam_endpoint="https://iam.amazonaws.com" \
sts_endpoint="https://sts.amazonaws.com"
```
### Create the policy first
```bash
# vi app-server-policy.hcl
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}

vault policy write app-server-policy app-server-policy.hcl
```
**Verify:**
```bash
vault policy list
vault policy read app-server-policy
```

### Role for an app running on EC2 with IAM role 'AppServerRole'
```bash
vault write auth/aws/role/app-server \
auth_type=iam \
bound_iam_principal_arn='<ROLE_ARN>' \
policies=app-server-policy \
ttl=1h \
max_ttl=4h
```
**Note:** Make sure that a policy named **app-server-policy** is already defined in Vault.

## Configure Kubernetes auth methode (for EKS)
```bash
vault auth enable kubernetes
```
### In EKS cluster (we will use this while auth config in vault)
```bash
KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten \
-o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)

KUBE_HOST=$(kubectl config view --raw --minify --flatten \
-o jsonpath='{.clusters[].cluster.server}')
```
### configure auth
```bash
vault write auth/kubernetes/config \
kubernetes_host="$KUBE_HOST" \
kubernetes_ca_cert="$KUBE_CA_CERT" \
disable_iss_validation=true
```


### Policy
```bash
# vi payments-policy.hcl
# For static secrets
path "secret/data/payments/*" {
    capabilities = ["read"]
}

# Get dynamic DB credentials
path "database/creds/payments-readonly" {
    capabilities = ["read"]
}

# Renew own token
path "auth/token/renew-self" {
    capabilities = ["update"]
}

# Allow token lookup for health checks
path "auth/token/lookup-self" {
    capabilities = ["read"]
}

# Deny all other paths
path "*" {
    capabilities = ["deny"]
}

```
```bash
vault policy write payments-policy payments-policy.hcl
```
**verify:**
```bash
vault policy read payments-policy
```
### Create role for the payment-microservice
```bash
vault write auth/kubernetes/role/payments-svc \
bound_service_account_names=payment-sa \
bound_service_account_namespaces=payments \
policies=payments-policy \
ttl=1h \
max_ttl=4h
```
## Configure dynamic credentials for database secrets
### PostgreSQL on RDS
```bash
vault write database/config/payments-postgres \
plugin_name=postgresql-database-plugin \
allowed_roles='payments-readonly,payments-readwrite' \
connection_url='postgresql://{{username}}:{{password}}@payments-rds.cluster.ap-south-1.rds.amazonaws.com:5432/paymentsdb?sslmode=require' \
username='vault-admin' \
password='<INITIAL_PASSWD'>
```
**allowed_roles='payments-readonly,payments-readwrite'**
This is just a whitelist of Vault roles that are allowed to use this DB connection.
- It does NOT create the roles
- It only says: “these roles may use this DB config”
### Create roles
```bash
vault write database/roles/payments-readonly \
  db_name=payments-postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```
**Note:**Vault will:
- Create temporary DB users
- Auto-expire them
**Explanation:**
- Database has a privileged user vault-admin (not necessarily the RDS master, but a user with enough rights).
- Stored in Vault config:
```bash
username='vault-admin'
password='<INITIAL_PASSWD>'
```
- Vault uses this account to manage other DB users
- Vault creates dynamic users for applications
- When your app requests credentials:
```bash
vault read database/creds/payments-readonly
```
- Vault will:Connect to DB using vault-admin & Run SQL like:
```bash
CREATE ROLE "v-token-xyz" WITH LOGIN PASSWORD 'random-pass';
GRANT SELECT ON ALL TABLES...
```
- Returns to app:
```bash
{
  "username": "v-token-xyz",
  "password": "random-pass"
}
```
- These users are temporary.Have TTL (e.g., 1 hour)
### Test: Manually request a credentials
```bash
vault read database/creds/payments-readonly
```

## Revoke root token
After all initial config is complete, revoke the root token.
**Note:** This is a non-reversible step - make sure all auth methods are set up first
```bash
vault token revoke <ROOT_TOKEN>
```
### To re-generate
```bash
vault operator generate-root -init
```
## Backup , Monitoring & Operational setup
### Create a dedicated toke for backup
- Create a policy file:
```bash
# raft-snapshot-policy.hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
```
- Write the policy
```bash
vault policy write raft-snapshot-policy raft-snapshot-policy.hcl
```
- Create a token for backups
```bash
vault token create \
  -policy=raft-snapshot-policy \
  -ttl=24h
```
- save token to secrets manager "vault/backup-token"
### Automated Raft snapshot backup to s3
```bash
# vi /usr/local/bin/vault-backup.sh
#!/bin/bash
set -eou pipefail

export VAULT_ADDR=https://127.0.0.0.1:8200
export VAULT_CACERT=/etc/vault/tls/ca.crt

BACKUP_BUCKET="vault-raft-backups-prod-gaurav17march2026"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNANPSHOT_FILE=/tmp/vault-snapshot-${TIMESTAMP}.snap

# Get token from secrets manager 
VAULT_TOKEN=$(aws secretsmanager get-secret-value \
--secret-id vault/backup-token \
--query SecretString --output text)

export VAULT_TOKEN

# Take snapshot
vault operator raft snapshot save $SNANPSHOT_FILE

# Upload to S3
aws s3 cp $SNANPSHOT_FILE s3://${BACKUP_BUCKET}/snapshots/vault-snapshot-${TIMESTAMP}.snap

# Clean up
rm -f $SNANPSHOT_FILE

echo "Bacup complete: vault-snapshot-${TIMESTAMP}.snap"
```
```bash
chmod +x /usr/local/bin/vault-backup.sh
```
### Schedule with cron (every 6 hrs)
```bash
echo '0 */6 * * * vault /usr/local/bin/vault-backup.sh >> /var/log/vault/backup.log 2>&1' | crontab -u vault -
```

## Workload integration - EKS
### Install vault secrets operator on EKS
```bash
helm repo add hashicorp https://helm.release.hashicorp/com
helm repo update
```
### Create namespace
```bash
kubectl create ns vault-secrets-operator
```
### Install VSO
```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
--namespace vault-secrets-operator \
--set defaultVaultConnection.enabled=true \
--set defaultVaultConnection.address=https://vault.internal:8200 \
--set defaultVaultConnection.skipTLSVerify=false \
--set defaultVaultConnection.caCertSecret=vault-ca-cert
```
### Create CA cert secret so, VSO can verify vault's TLS
```bash
kubectl create secret generic vault-ca-cert \
--from-file=ca.crt=/path/to/vault-ca.crt \
-n vault-secrets-operator
```

### Create VaultAuth and VaultStaticSecret for a service
```bash
kubectl create namespace payments
kubectl create serviceaccount payments-sa -n payments
```
- VaultAuth-tells VSO how to authenticate
```bash
# vault-auth.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: payments
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: payments-readonly
    serviceAccount: payments-sa
```
- VaultStaticSecret - syncs a KV secret into a k8s secret
```bash
# vault-static-secret.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: payments-config
  namespace: payments
spec:
  type: kv-v2
  mount: secret
  path: payments/config
  destination:
    name: payments-config
    create: true
  refreshAfter: 30s
  vaultAuthRef: vault-auth
```


