# Create KMS for unseal vault at initialization
resource "aws_kms_key" "vault_unseal" {
  description             = "KMS key for Vault auto-unseal"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name        = "vault-auto-unseal"
    Environment = "prod"
  }
}

resource "aws_kms_alias" "vault_unseal_alias" {
  name          = "alias/vault-auto-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}
