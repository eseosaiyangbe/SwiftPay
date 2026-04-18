# Amazon GuardDuty - Threat Detection Service (prod only)
# Monitors for malicious activity and unauthorized behavior

resource "aws_guardduty_detector" "swiftpay" {
  count  = local.env == "prod" ? 1 : 0
  enable = true

  # Data Sources Configuration
  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = {
    Name        = "swiftpay-guardduty"
    Environment = var.environment
  }
}

# KMS key for security findings SNS topics (GuardDuty, Security Hub)
resource "aws_kms_key" "security_findings" {
  description             = "KMS key for GuardDuty and Security Hub SNS encryption"
  deletion_window_in_days  = 10
  enable_key_rotation      = true
}

resource "aws_kms_alias" "security_findings" {
  name          = "alias/swiftpay-security-findings"
  target_key_id = aws_kms_key.security_findings.key_id
}

# GuardDuty Findings SNS Topic (for alerts) — prod only
resource "aws_sns_topic" "guardduty_findings" {
  count             = local.env == "prod" ? 1 : 0
  name              = "swiftpay-guardduty-findings"
  kms_master_key_id = aws_kms_key.security_findings.id

  tags = {
    Name        = "swiftpay-guardduty-findings"
    Environment = var.environment
  }
}

# GuardDuty EventBridge Rule - Send findings to SNS
resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count       = local.env == "prod" ? 1 : 0
  name        = "swiftpay-guardduty-findings-rule"
  description = "Capture GuardDuty findings"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
  })

  tags = {
    Name = "swiftpay-guardduty-findings-rule"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  count     = local.env == "prod" ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "GuardDutyFindingsTarget"
  arn       = aws_sns_topic.guardduty_findings[0].arn
}

# SNS Topic Policy
resource "aws_sns_topic_policy" "guardduty_findings" {
  count  = local.env == "prod" ? 1 : 0
  arn    = aws_sns_topic.guardduty_findings[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.guardduty_findings[0].arn
      }
    ]
  })
}

# Optional: GuardDuty Member Accounts (if using AWS Organizations)
# Uncomment if you want to enable GuardDuty for member accounts
# resource "aws_guardduty_member" "member_accounts" {
#   for_each = var.guardduty_member_accounts
#
#   account_id                 = each.value.account_id
#   detector_id                = aws_guardduty_detector.swiftpay.id
#   email                      = each.value.email
#   invite                     = true
#   disable_email_notification = false
# }

