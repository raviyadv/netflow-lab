# "Bootstrap" = one-time account foundations that the main pipeline depends on.
# Applied rarely, by an admin, from a laptop. Its own small state stays local.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"

  default_tags {
    tags = {
      Project   = "netflow-lab"
      Component = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
