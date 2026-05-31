# Training deployment warning: this Terraform creates real AWS resources for security training only.
# Estimated hourly costs vary by account and usage, but expect roughly:
# EKS control plane ~$0.10/hr, two t3.medium nodes ~$0.08/hr, NAT gateway ~$0.045/hr plus data,
# RDS db.t3.micro ~$0.02/hr plus storage, and minor S3/VPC data charges.

terraform {
  required_version = ">= 1.6.0"

  # Local state is used for training simplicity. Production should use an encrypted
  # S3 backend with DynamoDB locking and strict bucket access controls.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  # // FIXED: Secret Management - AWS credentials are no longer hardcoded; AWS CLI/profile/role authentication is used.
  region = "eu-west-2"
}

# // FIXED: Terraform / IaC - a dedicated VPC replaces the default VPC for production isolation.
resource "aws_vpc" "pearlpay" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "pearlpay-vpc"
  }
}

resource "aws_internet_gateway" "pearlpay" {
  vpc_id = aws_vpc.pearlpay.id

  tags = {
    Name = "pearlpay-igw"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.pearlpay.id
  cidr_block              = "10.0.101.0/24"
  availability_zone       = "eu-west-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "pearlpay-public-eu-west-2a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.pearlpay.id
  cidr_block              = "10.0.102.0/24"
  availability_zone       = "eu-west-2b"
  map_public_ip_on_launch = true

  tags = {
    Name = "pearlpay-public-eu-west-2b"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.pearlpay.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-2a"

  tags = {
    Name = "pearlpay-private-eu-west-2a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.pearlpay.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-2b"

  tags = {
    Name = "pearlpay-private-eu-west-2b"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.pearlpay]

  tags = {
    Name = "pearlpay-nat-eip"
  }
}

resource "aws_nat_gateway" "pearlpay" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "pearlpay-nat"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.pearlpay.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.pearlpay.id
  }

  tags = {
    Name = "pearlpay-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.pearlpay.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.pearlpay.id
  }

  tags = {
    Name = "pearlpay-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# // FIXED: Terraform / IaC - load balancer ingress is limited to HTTP and HTTPS from the internet.
resource "aws_security_group" "load_balancer" {
  name        = "pearlpay-load-balancer"
  description = "Allow public HTTP and HTTPS traffic to the load balancer"
  vpc_id      = aws_vpc.pearlpay.id
}

resource "aws_security_group_rule" "load_balancer_http_ingress" {
  type              = "ingress"
  description       = "HTTP from internet"
  security_group_id = aws_security_group.load_balancer.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "load_balancer_https_ingress" {
  type              = "ingress"
  description       = "HTTPS from internet"
  security_group_id = aws_security_group.load_balancer.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "load_balancer_api_egress" {
  type                     = "egress"
  description              = "Forward traffic to API security group"
  security_group_id        = aws_security_group.load_balancer.id
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.api.id
}

# // FIXED: Terraform / IaC - API ingress is restricted to port 8000 from the load balancer security group only.
resource "aws_security_group" "api" {
  name        = "pearlpay-api"
  description = "Allow API traffic only from the load balancer"
  vpc_id      = aws_vpc.pearlpay.id
}

resource "aws_security_group_rule" "api_ingress_from_load_balancer" {
  type                     = "ingress"
  description              = "API traffic from load balancer"
  security_group_id        = aws_security_group.api.id
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.load_balancer.id
}

resource "aws_security_group_rule" "api_egress_to_database" {
  type                     = "egress"
  description              = "PostgreSQL traffic to database"
  security_group_id        = aws_security_group.api.id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.database.id
}

# // FIXED: Terraform / IaC - database ingress is restricted to PostgreSQL traffic from the API security group only.
resource "aws_security_group" "database" {
  name        = "pearlpay-database"
  description = "Allow database traffic only from the API"
  vpc_id      = aws_vpc.pearlpay.id
}

resource "aws_security_group_rule" "database_ingress_from_api" {
  type                     = "ingress"
  description              = "PostgreSQL from API"
  security_group_id        = aws_security_group.database.id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.api.id
}

resource "aws_s3_bucket" "receipts" {
  bucket        = "pearlpay-transaction-receipts-training"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  # // FIXED: Terraform / IaC - transaction receipts bucket blocks all public ACLs and policies.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_db_subnet_group" "private" {
  name       = "pearlpay-private-db-subnets"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "random_password" "payments" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_db_instance" "payments" {
  identifier                      = "pearlpay-payments"
  allocated_storage               = 20
  engine                          = "postgres"
  engine_version                  = "16.6"
  instance_class                  = "db.t3.micro"
  db_name                         = "payments"
  username                        = "payadmin"
  password                        = random_password.payments.result
  db_subnet_group_name            = aws_db_subnet_group.private.name
  vpc_security_group_ids          = [aws_security_group.database.id]
  skip_final_snapshot             = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  deletion_protection             = false # Training only; production should enable deletion protection.

  # // FIXED: Terraform / IaC - RDS instance is private and placed only in private subnets.
  publicly_accessible = false
  # // FIXED: Terraform / IaC - RDS storage encryption is enabled.
  storage_encrypted = true
}

resource "aws_iam_role" "eks_cluster" {
  name = "pearlpay-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "pearlpay" {
  name                      = "pearlpay-training"
  role_arn                  = aws_iam_role.eks_cluster.arn
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # // FIXED: Terraform / IaC - EKS control plane uses private subnets with private endpoint access enabled.
  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids      = [aws_security_group.api.id]
    endpoint_private_access = true
    endpoint_public_access  = true # Training only; allows kubectl access during labs.
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

resource "aws_iam_role" "eks_node_group" {
  name = "pearlpay-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# // FIXED: Terraform / IaC - EKS node group role uses minimum required managed policies instead of broad admin access.
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_read_only" {
  role       = aws_iam_role.eks_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.pearlpay.name
  node_group_name = "pearlpay-worker-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.eks_ecr_read_only
  ]
}

output "receipts_bucket" {
  value = aws_s3_bucket.receipts.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.payments.endpoint
}
