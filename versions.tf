terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = var.aws_allowed_account_ids

  default_tags {
    tags = {
      Project   = "demo-aws-gcp-vpn"
      Purpose   = "roxsfest-demo"
      Ephemeral = "true"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
