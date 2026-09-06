terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

data "aws_ami" "detsys_nixos" {
  most_recent = true

  # Determinate Systems' AMI owner ID
  owners      = ["535002876703"]

  filter {
    name   = "name"
    values = ["determinate/nixos/epoch-1/*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

locals {
  flake_reference = "Fifty-Nine/aws-gh-runner/0.1#nixosConfigurations.gh-runner"
}

variable "instance_type" {
  type        = string
  default     = "t4g.small"
  description = "Graviton instance size for fast kernel compilation"
}

variable "volume_size" {
  type        = number
  default     = 16
  description = "Root volume size in GiB"
}

variable "volume_throughput" {
  type        = number
  default     = 125
  description = "Root volume gp3 throughput in MiB/s; lower this for cache-pull-only instances"
}

variable "ssh_key_name" {
  type        = string
  description = "Name of existing EC2 Key Pair in the target AWS region"
}

variable "github_runner_pat" {
  type        = string
  sensitive   = true
  description = "GitHub PAT (fine-grained, Administration:write on the runner repo) used to mint registration tokens on boot"
}

variable "flakehub_token" {
  type        = string
  sensitive   = true
  description = "FlakeHub authentication token"
}

variable "ssh_allowed_cidr" {
  type        = string
  default     = null
  description = "CIDR block allowed to SSH to the builder. Defaults to the current public IP."
}

provider "aws" {
  region = var.aws_region
}

data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

# 1. Dedicated VPC, subnet, and routing so everything is created and torn
# down together (no dependency on the account-default VPC).
resource "aws_vpc" "builder_vpc" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true

  tags = {
    Name = "arm-gh-runner-vpc"
  }
}

resource "aws_subnet" "builder_subnet" {
  vpc_id                  = aws_vpc.builder_vpc.id
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "arm-gh-runner-subnet"
  }
}

resource "aws_internet_gateway" "builder_igw" {
  vpc_id = aws_vpc.builder_vpc.id

  tags = {
    Name = "arm-gh-runner-igw"
  }
}

resource "aws_route_table" "builder_rt" {
  vpc_id = aws_vpc.builder_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.builder_igw.id
  }

  tags = {
    Name = "arm-gh-runner-rt"
  }
}

resource "aws_route_table_association" "builder_rta" {
  subnet_id      = aws_subnet.builder_subnet.id
  route_table_id = aws_route_table.builder_rt.id
}

# 2. Security Group allowing SSH and full egress
resource "aws_security_group" "builder_sg" {
  name        = "arm-gh-runner-builder-sg"
  description = "Allow inbound SSH and outbound internet access"
  vpc_id      = aws_vpc.builder_vpc.id

  ingress {
    description = "SSH from my current public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr != null ? var.ssh_allowed_cidr : "${chomp(data.http.my_public_ip.response_body)}/32"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  lifecycle {
    precondition {
      condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", chomp(data.http.my_public_ip.response_body)))
      error_message = "checkip.amazonaws.com did not return a valid IPv4 address; set var.ssh_allowed_cidr explicitly."
    }
  }
}

resource "aws_instance" "builder" {
  ami           = data.aws_ami.detsys_nixos.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  subnet_id              = aws_subnet.builder_subnet.id
  vpc_security_group_ids = [aws_security_group.builder_sg.id]

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    throughput            = var.volume_throughput # MiB/s (gp3 default is 125)
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/sh
    set -eux

    printf '%s\n' '${var.github_runner_pat}' > /var/run/gh_pat
    chmod 0600 /var/run/gh_pat

    determinate-nixd login --token-file /var/run/fh_token
    fh apply nixos "${local.flake_reference}"
  EOF

  user_data_replace_on_change = true

  tags = {
    Name = "arm-gh-runner-builder"
  }
}

output "instance_id" {
  value = aws_instance.builder.id
}

output "public_ip" {
  value = aws_instance.builder.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/builder.pem root@${aws_instance.builder.public_ip}"
}
