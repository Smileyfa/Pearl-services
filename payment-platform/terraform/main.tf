terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # // VULN: Secret Management - AWS credentials are hardcoded in IaC provider configuration.
  access_key = "AKIA0000EXAMPLE"
  secret_key = "wJalrXexample"
}

# // VULN: Terraform / IaC - no custom VPC is created; resources deploy into the default VPC.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# // VULN: Terraform / IaC - security group allows 0.0.0.0/0 inbound on all ports.
resource "aws_security_group" "open_everything" {
  name        = "pearlpay-open-everything"
  description = "Open security group for vulnerable training lab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "All inbound traffic from the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "receipts" {
  bucket        = "pearlpay-transaction-receipts-training"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_acl" "receipts" {
  depends_on = [
    aws_s3_bucket_ownership_controls.receipts,
    aws_s3_bucket_public_access_block.receipts
  ]

  bucket = aws_s3_bucket.receipts.id
  # // VULN: Terraform / IaC - transaction receipts bucket has public read ACL.
  acl = "public-read"
}

resource "aws_db_subnet_group" "default" {
  name       = "pearlpay-default-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "payments" {
  identifier             = "pearlpay-payments"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t3.micro"
  db_name                = "payments"
  username               = "payadmin"
  password               = "SuperSecretPassword123!"
  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.open_everything.id]
  skip_final_snapshot    = true

  # // VULN: Terraform / IaC - RDS instance is publicly accessible.
  publicly_accessible = true
  # // VULN: Terraform / IaC - RDS storage encryption is disabled.
  storage_encrypted = false
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
  name     = "pearlpay-training"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.open_everything.id]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

resource "aws_iam_role" "eks_node_group" {
  name = "pearlpay-eks-node-admin-role"

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

resource "aws_iam_role_policy_attachment" "eks_node_admin" {
  role       = aws_iam_role.eks_node_group.name
  # // VULN: Terraform / IaC - EKS node group role has AdministratorAccess attached.
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.pearlpay.name
  node_group_name = "pearlpay-admin-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = data.aws_subnets.default.ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_admin
  ]
}

output "receipts_bucket" {
  value = aws_s3_bucket.receipts.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.payments.endpoint
}
