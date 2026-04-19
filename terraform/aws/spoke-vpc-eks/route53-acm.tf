# Route53 and ACM - DNS and SSL Certificate Management
# Required for HTTPS endpoints

# Route53 Hosted Zone
resource "aws_route53_zone" "swiftpay" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name

  tags = {
    Name        = "swiftpay-${var.environment}-zone"
    Environment = var.environment
  }
}

# ACM Certificate for HTTPS
resource "aws_acm_certificate" "swiftpay" {
  count             = var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.domain_name}"  # Wildcard for all subdomains (api.swiftpay.com, www.swiftpay.com, etc.)
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "swiftpay-${var.environment}-cert"
    Environment = var.environment
  }
}

# DNS Validation Record for Root Domain
resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name != "" ? {
    for dvo in aws_acm_certificate.swiftpay[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = aws_route53_zone.swiftpay[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# ACM Certificate Validation
resource "aws_acm_certificate_validation" "swiftpay" {
  count           = var.domain_name != "" ? 1 : 0
  certificate_arn = aws_acm_certificate.swiftpay[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.cert_validation : record.fqdn
  ]

  timeouts {
    create = "5m"
  }
}

# Route53 Record for API Gateway (managed by External DNS, but can be created here)
# Note: External DNS will manage this automatically if enabled
# resource "aws_route53_record" "api" {
#   count   = var.domain_name != "" && var.enable_external_dns ? 0 : (var.domain_name != "" ? 1 : 0)
#   zone_id = aws_route53_zone.swiftpay[0].zone_id
#   name    = "api.${var.domain_name}"
#   type    = "A"
#
#   alias {
#     name                   = aws_lb.api_gateway.dns_name
#     zone_id                = aws_lb.api_gateway.zone_id
#     evaluate_target_health = true
#   }
# }

