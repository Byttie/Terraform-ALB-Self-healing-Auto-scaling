terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.7.0"
    }
  }
}

provider "aws" {
  profile = "Geralt"
  region  = "us-east-1"
}

# -----------------------------------------------------------------------------
# AMI - Ubuntu 22.04 LTS (Jammy Jellyfish)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS Account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# 3-Tier Networking - VPC, Public, Private App, and Private DB Subnets
# -----------------------------------------------------------------------------
resource "aws_vpc" "Geralt" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "Geralt-VPC"
  }
}

# 1. Public Subnets (Frontend / ALB / NAT Gateway)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "public-subnet-1a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = { Name = "public-subnet-1b" }
}

# 2. Private Subnets (Backend App / ASG)
resource "aws_subnet" "private_app_a" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.3.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false
  tags = { Name = "private-app-subnet-1a" }
}

resource "aws_subnet" "private_app_b" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.4.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false
  tags = { Name = "private-app-subnet-1b" }
}

# 3. Private Subnets (Database Layer)
resource "aws_subnet" "private_db_a" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.5.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false
  tags = { Name = "private-db-subnet-1a" }
}

resource "aws_subnet" "private_db_b" {
  vpc_id                  = aws_vpc.Geralt.id
  cidr_block              = "192.168.6.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false
  tags = { Name = "private-db-subnet-1b" }
}

# Internet Gateway for Public Subnets
resource "aws_internet_gateway" "internet-access" {
  vpc_id = aws_vpc.Geralt.id
  tags = { Name = "main-igw" }
}

# NAT Gateway for Private Subnets (so backend can install apt packages)
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_a.id
  tags = { Name = "main-nat-gateway" }
  depends_on    = [aws_internet_gateway.internet-access]
}

# Route Tables
resource "aws_route_table" "public-rt" {
  vpc_id = aws_vpc.Geralt.id
  tags = { Name = "public-route-table" }
}

resource "aws_route" "default-route" {
  route_table_id         = aws_route_table.public-rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.internet-access.id
}

resource "aws_route_table" "private-rt" {
  vpc_id = aws_vpc.Geralt.id
  tags = { Name = "private-route-table" }
}

resource "aws_route" "nat-route" {
  route_table_id         = aws_route_table.private-rt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gw.id
}

# Route Table Associations
resource "aws_route_table_association" "public-rt-assoc-a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public-rt.id
}
resource "aws_route_table_association" "public-rt-assoc-b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public-rt.id
}

resource "aws_route_table_association" "private-rt-assoc-a" {
  subnet_id      = aws_subnet.private_app_a.id
  route_table_id = aws_route_table.private-rt.id
}
resource "aws_route_table_association" "private-rt-assoc-b" {
  subnet_id      = aws_subnet.private_app_b.id
  route_table_id = aws_route_table.private-rt.id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Security group for the Application Load Balancer"
  vpc_id      = aws_vpc.Geralt.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "alb-sg" }
}

resource "aws_security_group" "backend_sg" {
  name        = "backend-sg"
  description = "Security group for backend Auto Scaling Group instances"
  vpc_id      = aws_vpc.Geralt.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH for debugging"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "backend-sg" }
}

resource "aws_security_group" "db_sg" {
  name        = "db-sg"
  description = "Security group for database instances"
  vpc_id      = aws_vpc.Geralt.id

  ingress {
    description     = "MySQL/PostgreSQL from Backend"
    from_port       = 3306 
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend_sg.id]
  }

  tags = { Name = "db-sg" }
}

# -----------------------------------------------------------------------------
# Key pair
# -----------------------------------------------------------------------------
resource "aws_key_pair" "public-key" {
  key_name   = "id_rsa"
  public_key = file("C:/Users/User/.ssh/id_rsa.pub")
}

# -----------------------------------------------------------------------------
# Launch Template & Auto Scaling Group
# -----------------------------------------------------------------------------
resource "aws_launch_template" "backend_lt" {
  name_prefix   = "backend-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.public-key.key_name

  vpc_security_group_ids = [aws_security_group.backend_sg.id]

  user_data = base64encode(file("${path.module}/user_data.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "backend-asg-instance" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "backend_alb" {
  name               = "backend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags = { Name = "backend-alb" }
}

resource "aws_lb_target_group" "backend_tg" {
  name     = "backend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.Geralt.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "backend-tg" }
}

resource "aws_lb_listener" "backend_listener" {
  load_balancer_arn = aws_lb.backend_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

resource "aws_autoscaling_group" "backend_asg" {
  name                      = "backend-asg"
  min_size                  = 2
  desired_capacity          = 2
  max_size                  = 4
  vpc_zone_identifier       = [aws_subnet.private_app_a.id, aws_subnet.private_app_b.id]
  target_group_arns         = [aws_lb_target_group.backend_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300 # Increased to 5 minutes to accommodate apt update

  launch_template {
    id      = aws_launch_template.backend_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "backend-asg-instance"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "backend-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.backend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 50.0
    disable_scale_in = false
  }
}