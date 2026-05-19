# EC2 instance running the full observability stack via Docker Compose
# (Prometheus + Grafana + Loki + Alertmanager)

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring-sg"
  vpc_id      = var.vpc_id
  description = "Monitoring server: Grafana, Prometheus, Alertmanager, Loki"

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  ingress {
    description = "Alertmanager"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = var.vpc_cidr_blocks
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.name}-monitoring-sg" })
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name
  key_name               = var.key_name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh", {
    prometheus_url         = "http://${var.app_alb_dns}:80"
    grafana_admin_password = var.grafana_admin_password
    loki_retention_hours   = var.loki_retention_hours
  }))

  tags = merge(var.tags, { Name = "${var.name}-monitoring" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eip" "monitoring" {
  instance = aws_instance.monitoring.id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-monitoring-eip" })
}

# IAM profile so the instance can describe ECS tasks (for Prometheus scraping)
resource "aws_iam_role" "monitoring" {
  name = "${var.name}-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "monitoring" {
  name = "${var.name}-monitoring-policy"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ec2:DescribeInstances",
          "cloudwatch:GetMetricData",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
  tags = var.tags
}
