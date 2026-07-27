terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Backend values are supplied through backend.hcl or -backend-config.
  # Both lock mechanisms are configured because the assessment explicitly
  # requires DynamoDB while current Terraform supports native S3 lock files.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
