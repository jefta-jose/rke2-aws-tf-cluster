locals {
  env      = "development"
  project  = "rok"
  name     = "development-rok"
  common_tags = {
    Terraform   = "true"
    Environment = "development"
    Application = "rok"
  }
}

############################
# Network (for the ALB)
############################
module "network" {
  source     = "./modules/network"
  name       = local.name
  cidr_block = "10.42.0.0/16"
  azs        = ["us-east-1a", "us-east-1b"]
  tags       = local.common_tags
}

############################
# Secrets Manager — development-rok-general-secret
############################
module "development_secret" {
  source      = "./modules/secret"
  project     = local.project
  environment = local.env
  application = "general"
  secret_value = jsonencode({
    ConnectionStrings__Default = "Server=rds;Database=rok;User Id=sa;Password=Lab_Passw0rd!;"
    Smtp__Host                 = "mailpit-smtp.mailhog"
    Smtp__Port                 = "1025"
    SECRET_MESSAGE             = "injected from Floci Secrets Manager via ESO"
  })
}

############################
# SQS — email queue + DLQ
############################
module "email_dlq" {
  source                      = "./modules/sqs_queue"
  environment                 = local.env
  project                     = local.project
  application                 = "email-dlq"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600
}

module "email" {
  source                      = "./modules/sqs_queue"
  environment                 = local.env
  project                     = local.project
  application                 = "email"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 300
  message_retention_seconds   = 1209600
  dead_letter_target_arn      = module.email_dlq.queue_arn
  max_receive_count           = 5
}

############################
# IAM — one node role stands in for module.rke2 / module.rke2_agents
############################
resource "aws_iam_role" "rke2_node" {
  name = "${local.name}-rke2-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.common_tags, { Name = "${local.name}-rke2-node" })
}

# SES send (mirrors "lowerenv-rok-email-ses-send").
resource "aws_iam_policy" "email_ses_send" {
  name        = "lowerenv-rok-email-ses-send"
  description = "Allows sending emails via SES for the therok-email worker"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "arn:aws:ses:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:identity/amarok.com"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_sqs_producer" {
  role       = aws_iam_role.rke2_node.name
  policy_arn = module.email.producer_policy_arn
}

resource "aws_iam_role_policy_attachment" "node_sqs_consumer" {
  role       = aws_iam_role.rke2_node.name
  policy_arn = module.email.consumer_policy_arn
}

resource "aws_iam_role_policy_attachment" "node_ses_send" {
  role       = aws_iam_role.rke2_node.name
  policy_arn = aws_iam_policy.email_ses_send.arn
}

############################
# ALB + WAF — provisioned ONLY to mirror ROK's infra; NOT used in the lab's request path.
# Floci's ALB can't route into the libvirt subnet (192.168.122.0/24) — a VM-IP target just
# times out — and Floci's LB rewrites the Host header, so a host-scoped Ingress never matches.
# So the lab reaches the cluster via a socat bridge (host -> Traefik NodePort 30080), not the
# ALB. We keep these resources for parity with real ROK but register no targets against them.
############################
module "alb" {
  source           = "./modules/alb"
  name             = local.name
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.public_subnet_ids
  traefik_nodeport = 30080
  tags             = local.common_tags
}

############################
# WAFv2 — IaC-only WebACL associated to the ALB
############################
module "waf" {
  source       = "./modules/waf"
  name         = "nonprod-rok"
  alb_arn      = module.alb.alb_arn
  accepted_ips = []
  tags         = local.common_tags
}
