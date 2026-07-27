locals {
  availability_zones = {
    a = "${var.aws_region}a"
    b = "${var.aws_region}b"
  }

  public_subnet_cidrs = {
    a = "10.100.1.0/24"
    b = "10.100.2.0/24"
  }

  application_subnet_cidrs = {
    a = "10.100.11.0/24"
    b = "10.100.12.0/24"
  }

  data_subnet_cidrs = {
    a = "10.100.21.0/24"
    b = "10.100.22.0/24"
  }

  common_tags = {
    Environment = var.environment
    CustomerId  = var.customer_id
    Tier        = var.tier
    ManagedBy   = "Terraform"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# --- Network: public edge, private application, and isolated data subnets ---

resource "aws_vpc" "main" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-vpc"
  }
}

resource "aws_subnet" "public" {
  for_each = local.availability_zones

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[each.key]
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "application" {
  for_each = local.availability_zones

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.application_subnet_cidrs[each.key]
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment}-application-${each.key}"
    Tier = "private-application"
  }
}

resource "aws_subnet" "data" {
  for_each = local.availability_zones

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.data_subnet_cidrs[each.key]
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment}-data-${each.key}"
    Tier = "isolated-data"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.environment}-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# A single NAT Gateway keeps the assessment affordable. A production HA cell
# should use one NAT Gateway per AZ or replace internet paths with VPC endpoints.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.environment}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.environment}-nat"
  }
}

resource "aws_route_table" "application" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.environment}-application"
  }
}

resource "aws_route_table_association" "application" {
  for_each = aws_subnet.application

  subnet_id      = each.value.id
  route_table_id = aws_route_table.application.id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-isolated-data"
  }
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

# S3 traffic remains on the AWS network and does not consume NAT bandwidth.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.application.id]

  tags = {
    Name = "${var.environment}-s3"
  }
}

# --- Security groups: no public Kubernetes API and no SSH ---

resource "aws_security_group" "k3s_node" {
  name                   = "${var.environment}-k3s-node"
  description            = "Private K3s node; API is reachable only from approved private networks"
  vpc_id                 = aws_vpc.main.id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.environment}-k3s-node"
  }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_api" {
  for_each = toset(var.k3s_api_allowed_cidrs)

  security_group_id = aws_security_group.k3s_node.id
  description       = "K3s API from an approved private management/deploy network"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_https" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTPS for SSM, ECR, package repositories, and approved APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_dns_udp" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "DNS through the VPC resolver"
  cidr_ipv4         = "${cidrhost(aws_vpc.main.cidr_block, 2)}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_dns_tcp" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "TCP DNS fallback through the VPC resolver"
  cidr_ipv4         = "${cidrhost(aws_vpc.main.cidr_block, 2)}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_ntp" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "Amazon Time Sync Service"
  cidr_ipv4         = "169.254.169.123/32"
  from_port         = 123
  to_port           = 123
  ip_protocol       = "udp"
}

resource "aws_security_group" "rds" {
  name                   = "${var.environment}-rds"
  description            = "PostgreSQL accepts connections only from the K3s workload security group"
  vpc_id                 = aws_vpc.main.id
  revoke_rules_on_delete = true

  tags = {
    Name = "${var.environment}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_k3s" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from billing workloads"
  referenced_security_group_id = aws_security_group.k3s_node.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_to_rds" {
  security_group_id            = aws_security_group.k3s_node.id
  description                  = "Billing workloads to PostgreSQL"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# --- RDS PostgreSQL: private, encrypted, backed up, and TLS-enforced ---

resource "aws_db_subnet_group" "main" {
  name       = "${var.environment}-db-subnet"
  subnet_ids = [for subnet in values(aws_subnet.data) : subnet.id]

  tags = {
    Name = "${var.environment}-db-subnet"
  }
}

resource "aws_db_parameter_group" "billing" {
  name   = "${var.environment}-billing-postgres16"
  family = "postgres16"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "billing" {
  identifier     = "${var.environment}-billing-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  db_name                       = "billing"
  username                      = var.db_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.billing.name
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  backup_retention_period   = 7
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.environment}-billing-final-${random_id.suffix.hex}"

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Name = "${var.environment}-billing-db"
  }
}

# --- S3 exports: KMS encryption, versioning, TLS-only, and no public access ---

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "billing_exports" {
  bucket        = "${var.environment}-billing-exports-${random_id.suffix.hex}"
  force_destroy = false

  tags = {
    Name = "${var.environment}-billing-exports"
  }
}

resource "aws_s3_bucket_public_access_block" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "billing_exports" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.billing_exports.arn,
      "${aws_s3_bucket.billing_exports.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id
  policy = data.aws_iam_policy_document.billing_exports.json

  depends_on = [aws_s3_bucket_public_access_block.billing_exports]
}

# --- Private single-node K3s assessment runtime ---

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "k3s_node" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.application["a"].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.k3s_node.id]
  iam_instance_profile        = aws_iam_instance_profile.k3s_node.name

  # K3s is pinned, encrypts Kubernetes secrets, and exposes no bundled ingress.
  user_data = <<-USERDATA
    #!/usr/bin/env bash
    set -euo pipefail

    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION='${var.k3s_version}' \
      INSTALL_K3S_EXEC='server --disable=traefik --disable=servicelb --write-kubeconfig-mode=0600 --secrets-encryption --flannel-backend=wireguard-native --tls-san-security --kube-apiserver-arg=anonymous-auth=false' \
      sh -
  USERDATA

  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = aws_kms_key.data.arn
    volume_type = "gp3"
    volume_size = 30
  }

  depends_on = [aws_nat_gateway.main]

  tags = {
    Name = "${var.environment}-k3s-node"
    Role = "k3s-server"
  }
}
