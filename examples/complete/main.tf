# ==============================
# Complete IRSA Example
# Full configuration with webhook customization, multiple IAM roles,
# and Kubernetes API server integration
# ==============================

provider "aws" {
  region = "eu-west-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "helm" {
  kubernetes = {
    config_path = "./kubeconfig"
  }
}

# ==============================
# IRSA Module
# ==============================

module "irsa" {
  source = "../../"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    helm          = helm
  }

  name            = "myapp-k8s-infra"
  environment     = "prod"
  oidc_domain     = "myapp-k8s-infra-oidc.example.com"
  route53_zone_id = "Z0123456789ABCDEF"
  kubeconfig_path = "${path.module}/kubeconfig"
  aws_region      = "eu-west-1"

  # Webhook configuration
  webhook_enabled = true
  webhook_node_selector = {
    role = "management"
  }
  webhook_tolerations = [{
    key      = "role"
    operator = "Equal"
    value    = "management"
    effect   = "NoSchedule"
  }]

  # CloudFront cache tuning
  cloudfront_price_class = "PriceClass_100"
  cache_default_ttl      = 3600
  cache_max_ttl          = 86400
  cache_min_ttl          = 60

  tags = {
    Team    = "platform"
    Project = "infrastructure"
  }
}

# ==============================
# Kubernetes API Server Configuration
# Use these outputs when configuring your K8s control plane
# ==============================

# Example: Talos / kubeadm API server extra args
# --service-account-issuer=<module.irsa.issuer_url>
# --service-account-jwks-uri=<module.irsa.jwks_uri>
# --api-audiences=sts.amazonaws.com,https://kubernetes.default.svc

# ==============================
# IAM Role: Fluent Bit (CloudWatch Logging)
# ==============================

resource "aws_iam_role" "fluent_bit" {
  name = "myapp-fluent-bit"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.irsa.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:logging:fluent-bit"
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "fluent_bit_cloudwatch" {
  name = "myapp-fluent-bit-cloudwatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutRetentionPolicy"
      ]
      Resource = "arn:aws:logs:eu-west-1:*:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fluent_bit" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = aws_iam_policy.fluent_bit_cloudwatch.arn
}

# ==============================
# IAM Role: External DNS (Route53)
# ==============================

resource "aws_iam_role" "external_dns" {
  name = "myapp-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.irsa.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:external-dns"
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "external_dns" {
  name = "myapp-external-dns-route53"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

# ==============================
# IAM Role: S3 Backup (read/write to S3)
# ==============================

resource "aws_iam_role" "backup" {
  name = "myapp-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.irsa.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:backup:velero"
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ==============================
# Outputs
# ==============================

output "issuer_url" {
  value = module.irsa.issuer_url
}

output "jwks_uri" {
  value = module.irsa.jwks_uri
}

output "oidc_provider_arn" {
  value = module.irsa.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.irsa.oidc_provider_url
}

output "fluent_bit_role_arn" {
  value = aws_iam_role.fluent_bit.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "backup_role_arn" {
  value = aws_iam_role.backup.arn
}
