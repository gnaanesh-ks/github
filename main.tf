# terraform/main.tf

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# VPC and Subnet Resources
# -----------------------------------------------------------------------------

# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Get the first public subnet (e.g., in us-east-1a)
# This will be used for the EC2 instance and as one of the DB subnets.
data "aws_subnet" "public_subnet_az1" {
  vpc_id                  = data.aws_vpc.default.id
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a" # Use first AZ
}

# Get a second public subnet in a different AZ (e.g., in us-east-1b)
# This will be used as the second DB subnet for high availability.
data "aws_subnet" "public_subnet_az2" {
  vpc_id                  = data.aws_vpc.default.id
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}b" # Use second AZ
}

# -----------------------------------------------------------------------------
# S3 Buckets for CI/CD Deployment
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend_bucket" {
  bucket = var.frontend_s3_bucket_name
  acl    = "public-read" # Public read for web content. More secure with CloudFront.

  website {
    index_document = "index.html"
    error_document = "index.html" # For SPA fallback
  }

  tags = {
    Name = "PianoTeachingFrontend"
  }
}

# Block public access for backend deployment bucket
resource "aws_s3_bucket_public_access_block" "backend_bucket_public_access_block" {
  bucket = var.backend_deployment_s3_bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "backend_deployment_bucket" {
  bucket = var.backend_deployment_s3_bucket_name

  tags = {
    Name = "PianoTeachingBackendDeployment"
  }
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 (to access S3 for deployments)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ec2_s3_access_role" {
  name = "piano-ec2-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
      },
    ],
  })
}

resource "aws_iam_role_policy" "ec2_s3_read_policy" {
  name = "piano-ec2-s3-read-policy"
  role = aws_iam_role.ec2_s3_access_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Effect = "Allow",
        Resource = [
          aws_s3_bucket.backend_deployment_bucket.arn,
          "${aws_s3_bucket.backend_deployment_bucket.arn}/*"
        ],
      },
    ],
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "piano-ec2-profile"
  role = aws_iam_role.ec2_s3_access_role.name
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# Security Group for EC2 (Frontend + Backend)
resource "aws_security_group" "ec2_sg" {
  name        = "piano-ec2-sg"
  description = "Allow HTTP, HTTPS, SSH, and DB traffic to EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  # Allow SSH from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Be more restrictive in production
  }

  # Allow HTTP (port 80) from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "piano-ec2-sg"
  }
}

# Security Group for RDS MySQL
resource "aws_security_group" "rds_sg" {
  name        = "piano-rds-sg"
  description = "Allow MySQL traffic from EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  # Allow MySQL (port 3306) traffic ONLY from the EC2 Security Group
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  # Allow outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "piano-rds-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------

# Find the latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "piano_web_server" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  # EC2 instance will be placed in the first public subnet
  subnet_id                   = data.aws_subnet.public_subnet_az1.id
  associate_public_ip_address = true # Ensure it gets a public IP
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name # Attach IAM profile

  # User data script to configure the EC2 instance on first launch
  user_data = templatefile("${path.module}/user_data.sh", {
    db_endpoint      = aws_db_instance.piano_db.address
    db_name          = var.db_name
    db_username      = var.db_username
    db_password      = var.db_password
    frontend_s3_bucket_name = aws_s3_bucket.frontend_bucket.bucket
    aws_region       = var.aws_region # Pass region to user data for S3 website endpoint
  })

  tags = {
    Name = "PianoWebServer-CI-CD"
  }
}

# -----------------------------------------------------------------------------
# RDS MySQL Instance
# -----------------------------------------------------------------------------

resource "aws_db_instance" "piano_db" {
  allocated_storage      = var.db_allocated_storage
  engine                 = "mysql"
  engine_version         = "8.0.35" # Specify a recent, stable version
  instance_class         = var.db_instance_type
  name                   = var.db_name
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.mysql8.0"
  skip_final_snapshot    = true # For demo purposes, disable final snapshot
  publicly_accessible    = false # RDS should NOT be publicly accessible
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.piano_db_subnet_group.name

  tags = {
    Name = "PianoDB-CI-CD"
  }
}

# DB Subnet Group (required for RDS in a VPC)
# This uses two subnets from different AZs for high availability.
resource "aws_db_subnet_group" "piano_db_subnet_group" {
  name        = "piano-db-subnet-group-ci-cd"
  description = "A group of subnets for the Piano Teaching DB CI/CD spanning two AZs"
  subnet_ids  = [
    data.aws_subnet.public_subnet_az1.id,
    data.aws_subnet.public_subnet_az2.id
  ]

  tags = {
    Name = "PianoDBSubnetGroup-CI-CD"
  }
}
