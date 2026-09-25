terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state for the lab (real ROK uses an S3 backend).
}

# Point the AWS provider at Floci. Dummy creds + skip the online checks that
# would otherwise try to reach real AWS metadata/STS endpoints.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    sts            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    ec2            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    elbv2          = "http://localhost:4566"
    wafv2          = "http://localhost:4566"
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
