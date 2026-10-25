# --- Latest Amazon Linux 2023 image (x86_64) ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# --- IAM role so we can open a shell via Session Manager (no SSH keys, no port 22) ---
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# --- Firewall rules ---
resource "aws_security_group" "stack" {
  name        = "${var.project}-stack-sg"
  description = "Grafana and Flink UI from my IP; Kafka from inside the VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Grafana from my IP"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Flink web UI from my IP"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Kafka from inside the VPC only (the Lambda will live here)"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Allow all outbound (download Docker images and connector JARs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- The instance that runs Kafka, Flink, Postgres and Grafana in Docker ---
resource "aws_instance" "stack" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.stack.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  # Bootstrap script runs once at first boot.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    compose  = file("${path.module}/stack/docker-compose.yml")
    init_sql = file("${path.module}/stack/init.sql")
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only (security best practice)
  }

  tags = {
    Name = "${var.project}-stack"
  }
}

output "stack_public_ip" {
  value = aws_instance.stack.public_ip
}

output "kafka_bootstrap" {
  description = "Use this from inside the VPC (the Lambda in Step 5)"
  value       = "${aws_instance.stack.private_ip}:9092"
}

output "flink_ui" {
  value = "http://${aws_instance.stack.public_ip}:8081"
}

output "grafana_url" {
  value = "http://${aws_instance.stack.public_ip}:3000"
}
