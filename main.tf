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

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "ap-south-1c"
  map_public_ip_on_launch = true

  tags = {
    Name = "temp-public-subnet"
  }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"

  tags = {
    Name = "temp-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "temp-nat"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "temp-igw"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
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
  target_id        = aws_instance.vault_nodes[*].id
  port             = 8200
}

# Create an S3 bucket for backing up Vault Raft snapshots
/*
vault operator raft snapshot save backup.snap
aws s3 cp backup.snap s3://vault-raft-backups-prod/
*/

resource "aws_s3_bucket" "vault_backup" {
  bucket = "vault-raft-backups-prod"

  tags = {
    Name        = "vault-raft-backups"
    Environment = "prod"
  }
}

resource "aws_s3_bucket_versioning" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.id

  rule {
    id     = "vault-backup-retention"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# Provision 3 EC2 instances
resource "aws_kms_key" "ebs_encryption" {
  description             = "KMS key for encrypting EBS volumes"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "ebs_alias" {
  name          = "alias/ebs-encryption"
  target_key_id = aws_kms_key.ebs_encryption.key_id
}

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "vault_nodes" {
  count = 0

  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium" # m6i.xlarge

  subnet_id = element([
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ], count.index)

  vpc_security_group_ids = [
    aws_security_group.vault_nodes.id
  ]

  iam_instance_profile = aws_iam_instance_profile.vault_instance_profile.name

  user_data = file("${path.module}/setup/node-${count.index}.sh")

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.ebs_encryption.arn
  }

  tags = {
    Name = "vault-node-${count.index + 1}"
  }
}

# vault.internal resolve to your AWS Network Load Balancer from multiple VPCs
resource "aws_route53_zone" "vault_internal" {
  name = "vault.internal"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  comment = "Private hosted zone for Vault"
}

resource "aws_route53_record" "vault_dns" {
  zone_id = aws_route53_zone.vault_internal.zone_id
  name    = "vault.internal"
  type    = "A"

  alias {
    name                   = aws_lb.vault_nlb.dns_name
    zone_id                = aws_lb.vault_nlb.zone_id
    evaluate_target_health = true
  }
}

# Create Transit Gateway
resource "aws_ec2_transit_gateway" "main" {
  description = "Main Transit Gateway"

  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = {
    Name = "main-tgw"
  }
}
# Attach First VPC (Vault VPC)
resource "aws_ec2_transit_gateway_vpc_attachment" "vault_vpc" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = [aws_subnet.private_1.id, aws_subnet.private_2.id, aws_subnet.private_3.id]

  tags = {
    Name = "vault-vpc-attachment"
  }
}

resource "aws_route" "vault_to_tgw" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "10.0.0.0/26"  # application vpc cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id
}

/*
#To allow other VPCs to resolve vault.internal, associate them with the hosted zone.
resource "aws_route53_zone_association" "vpc2" {
  zone_id = aws_route53_zone.vault_internal.zone_id
  vpc_id  = aws_vpc.vpc2.id
}
*/

