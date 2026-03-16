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

# IAM role for EC2 nodes to access KMS,S3,CloudWatch,SSM
resource "aws_iam_role" "vault_ec2_role" {
  name = "vault-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Policy for KMS
resource "aws_iam_policy" "vault_kms_policy" {
  name = "vault-kms-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.vault_unseal.arn
      }
    ]
  })
}
# IAM Policy for s3 bucket to upload raft snapshots
resource "aws_iam_policy" "vault_s3_backup" {
  name = "vault-s3-backup"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::vault-backups",
          "arn:aws:s3:::vault-backups/*"
        ]
      }
    ]
  })
}

# For logs and SSM management.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vault_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.vault_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "kms" {
  role       = aws_iam_role.vault_ec2_role.name
  policy_arn = aws_iam_policy.vault_kms_policy.arn
}

resource "aws_iam_role_policy_attachment" "s3_backup" {
  role       = aws_iam_role.vault_ec2_role.name
  policy_arn = aws_iam_policy.vault_s3_backup.arn
}

# Creation of Instance Profile (Required for EC2)
resource "aws_iam_instance_profile" "vault_instance_profile" {
  name = "vault-ec2-profile"
  role = aws_iam_role.vault_ec2_role.name
}

# Networking 
provider "aws" {
  region = "ap-south-1"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vault-vpc"
  }
}

# Private Subnet 1
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name = "private-subnet-1"
  }
}

# Private Subnet 2
resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-south-1b"

  tags = {
    Name = "private-subnet-2"
  }
}

# Private Subnet 3
resource "aws_subnet" "private_3" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-south-1c"

  tags = {
    Name = "private-subnet-3"
  }
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_3" {
  subnet_id      = aws_subnet.private_3.id
  route_table_id = aws_route_table.private_rt.id
}