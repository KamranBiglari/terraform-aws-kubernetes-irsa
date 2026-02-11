# ==============================
# IRSA Module: IAM Roles for Service Accounts
# Sets up OIDC discovery infrastructure for non-EKS Kubernetes clusters
# to enable AWS IAM authentication via service account tokens.
# ==============================

locals {
  issuer_url  = "https://${var.oidc_domain}"
  bucket_name = "${var.name}-oidc-discovery-${var.environment}-s3"
  jwks_proper = data.external.cluster_jwks.result.jwks
}

# ==============================
# JWKS Retrieval from Kubernetes API
# ==============================

data "external" "cluster_jwks" {
  program = ["bash", "-c", <<-EOT
    JWKS=$(kubectl --kubeconfig=${var.kubeconfig_path} get --raw /openid/v1/jwks 2>/dev/null || echo '{"keys":[]}')
    echo "$JWKS" | jq -c '{jwks: (. | tojson)}'
  EOT
  ]
}

# ==============================
# S3 Bucket for OIDC Discovery
# ==============================

resource "aws_s3_bucket" "oidc_discovery" {
  bucket = local.bucket_name

  tags = merge(var.tags, {
    Name = "IRSA OIDC Discovery"
  })
}

resource "aws_s3_bucket_public_access_block" "oidc_discovery" {
  bucket = aws_s3_bucket.oidc_discovery.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==============================
# CloudFront Origin Access Control
# ==============================

resource "aws_cloudfront_origin_access_control" "oidc" {
  name                              = "${var.name}-oidc-oac-${var.environment}"
  description                       = "OAC for OIDC Discovery bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "oidc_cloudfront" {
  bucket = aws_s3_bucket.oidc_discovery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.oidc_discovery.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.oidc.arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.oidc_discovery]
}

# ==============================
# ACM Certificate for Custom Domain
# ==============================

resource "aws_acm_certificate" "oidc" {
  provider          = aws.us_east_1
  domain_name       = var.oidc_domain
  validation_method = "DNS"

  tags = merge(var.tags, {
    Name = "IRSA OIDC Certificate"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "oidc_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.oidc.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "oidc" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.oidc.arn
  validation_record_fqdns = [for record in aws_route53_record.oidc_cert_validation : record.fqdn]
}

# ==============================
# CloudFront Distribution
# ==============================

resource "aws_cloudfront_distribution" "oidc" {
  enabled             = true
  comment             = "OIDC Discovery for ${var.name}-${var.environment}"
  default_root_object = ""
  price_class         = var.cloudfront_price_class
  aliases             = [var.oidc_domain]

  origin {
    domain_name              = aws_s3_bucket.oidc_discovery.bucket_regional_domain_name
    origin_id                = "S3-OIDC"
    origin_access_control_id = aws_cloudfront_origin_access_control.oidc.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-OIDC"
    viewer_protocol_policy = "https-only"
    cache_policy_id        = aws_cloudfront_cache_policy.oidc.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.oidc.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(var.tags, {
    Name = "IRSA OIDC Discovery"
  })
}

# ==============================
# Route53 Record for CloudFront
# ==============================

resource "aws_route53_record" "oidc" {
  zone_id = var.route53_zone_id
  name    = var.oidc_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.oidc.domain_name
    zone_id                = aws_cloudfront_distribution.oidc.hosted_zone_id
    evaluate_target_health = false
  }
}

# ==============================
# CloudFront Cache Policy
# ==============================

resource "aws_cloudfront_cache_policy" "oidc" {
  name        = "${var.name}-oidc-cache-${var.environment}"
  comment     = "Cache policy for OIDC discovery documents"
  default_ttl = var.cache_default_ttl
  max_ttl     = var.cache_max_ttl
  min_ttl     = var.cache_min_ttl

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# ==============================
# S3 Objects: OIDC Discovery Documents
# ==============================

resource "aws_s3_object" "openid_configuration" {
  bucket       = aws_s3_bucket.oidc_discovery.id
  key          = ".well-known/openid-configuration"
  content_type = "application/json"

  content = jsonencode({
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/keys.json"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
    claims_supported = [
      "sub",
      "aud",
      "exp",
      "iat",
      "iss"
    ]
  })

  etag = md5(jsonencode({
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/keys.json"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
    claims_supported = [
      "sub",
      "aud",
      "exp",
      "iat",
      "iss"
    ]
  }))
}

resource "aws_s3_object" "jwks" {
  bucket       = aws_s3_bucket.oidc_discovery.id
  key          = "keys.json"
  content_type = "application/json"
  content      = local.jwks_proper

  etag = md5(local.jwks_proper)
}

# ==============================
# AWS IAM OIDC Provider
# ==============================

data "tls_certificate" "oidc" {
  url = local.issuer_url

  depends_on = [
    aws_route53_record.oidc,
    aws_cloudfront_distribution.oidc
  ]
}

resource "aws_iam_openid_connect_provider" "k8s" {
  url             = local.issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name    = "Kubernetes OIDC Provider"
    Cluster = "${var.name}-${var.environment}"
  })

  depends_on = [
    aws_route53_record.oidc,
    aws_cloudfront_distribution.oidc
  ]
}
