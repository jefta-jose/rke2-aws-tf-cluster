# Trimmed from rok-scaleout waf.tf. Floci WAFv2 is config-only (no real filtering) so this is
# IaC to read by eye: IP set + default-allow WebACL with a representative rule set + ALB association.
# Dropped from the real ACL: KMS-encrypted CloudWatch logging, and most managed groups.
resource "aws_wafv2_ip_set" "accepted" {
  name               = "${var.name}-accepted-ips"
  description        = "Accepted source IPs (real: NAT gateway EIPs)"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = [for ip in var.accepted_ips : "${ip}/32"]

  tags = merge(var.tags, { Name = "${var.name}-accepted-ips" })
}

resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AcceptedClusterIPs"
    priority = 0
    action {
      allow {}
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.accepted.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AcceptedClusterIPs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ArgocdAllow"
    priority = 1
    action {
      allow {}
    }
    statement {
      byte_match_statement {
        search_string         = "true"
        positional_constraint = "EXACTLY"
        field_to_match {
          single_header { name = "argocd" }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ArgocdAllow"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimit-2000-per-5min"
    priority = 3
    action {
      block {
        custom_response { response_code = 429 }
      }
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit-2000-per-5min"
      sampled_requests_enabled   = true
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-waf" })
}

resource "aws_wafv2_web_acl_association" "alb" {
  web_acl_arn  = aws_wafv2_web_acl.this.arn
  resource_arn = var.alb_arn
}