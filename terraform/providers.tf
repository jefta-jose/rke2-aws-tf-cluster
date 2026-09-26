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
    sts = "http://localhost:4566"
    iam = "http://localhost:4566"
    ec2 = "http://localhost:4566"
    # ecr / elbv2 are wired up only to mirror ROK's infra — the lab does NOT use them
    # in the real traffic/image paths (see the ALB/WAF note in main.tf):
    #   - ECR: no repos are provisioned here; images ship via a host-local registry:2
    #     instead, because Floci's ECR routes by *.localhost Host headers that the
    #     Docker Desktop engine can't resolve (resolving the ECR domain failed).
    #   - ALB (elbv2): provisioned for parity but bypassed. Floci can't route into the
    #     libvirt subnet and its LB rewrites the Host header, so traffic reaches the
    #     cluster via a socat bridge (host -> Traefik NodePort), not the ALB.
    ecr            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    elbv2          = "http://localhost:4566"
    wafv2          = "http://localhost:4566"
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
