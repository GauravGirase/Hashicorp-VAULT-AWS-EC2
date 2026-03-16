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

# Create VPC endpoints and a security group for the endpoints
resource "aws_security_group" "endpoint_sg" {
  name   = "vpc-endpoint-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTPS from Vault subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [
      "10.0.1.0/24",
      "10.0.2.0/24",
      "10.0.3.0/24"
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "endpoint-sg"
  }
}

resource "aws_vpc_endpoint" "kms" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.kms"
  vpc_endpoint_type = "Interface"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  security_group_ids = [aws_security_group.endpoint_sg.id]

  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.ssm"
  vpc_endpoint_type = "Interface"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  security_group_ids = [aws_security_group.endpoint_sg.id]
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.ssmmessages"
  vpc_endpoint_type = "Interface"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  security_group_ids = [aws_security_group.endpoint_sg.id]
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.ec2messages"
  vpc_endpoint_type = "Interface"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  security_group_ids = [aws_security_group.endpoint_sg.id]
}

resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.logs"
  vpc_endpoint_type = "Interface"

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  security_group_ids = [aws_security_group.endpoint_sg.id]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway" # S3 uses Gateway endpoint.

  route_table_ids = [
    aws_route_table.private_rt.id
  ]
}

# Security Groups for Vault nodes and a Network Load Balancer
resource "aws_security_group" "vault_nodes" {
  name   = "vault-nodes-sg"
  vpc_id = aws_vpc.main.id

  # Vault API access from NLB
  ingress {
    description = "Vault API from NLB"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Vault cluster communication
  ingress {
    description = "Vault cluster communication"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    self        = true
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vault-nodes-sg"
  }
}

resource "aws_lb" "vault_nlb" {
  name               = "vault-nlb"
  internal           = true
  load_balancer_type = "network"

  subnets = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]

  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "vault_tg" {
  name     = "vault-target-group"
  port     = 8200
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  health_check {
    port     = "8200"
    protocol = "TCP"
  }
}

resource "aws_lb_listener" "vault_listener" {
  load_balancer_arn = aws_lb.vault_nlb.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "vault_nodes" {
  target_group_arn = aws_lb_target_group.vault_tg.arn
  target_id        = aws_instance.vault.id
  port             = 8200
}
