# ==============================
# Basic IRSA Example
# Minimal configuration to enable IRSA on a non-EKS Kubernetes cluster
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

module "irsa" {
  source = "../../"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    helm          = helm
  }

  name            = "my-k8s-cluster"
  environment     = "dev"
  oidc_domain     = "my-k8s-cluster-oidc.example.com"
  route53_zone_id = "Z0123456789ABCDEF"
  kubeconfig_path = "${path.module}/kubeconfig"
  aws_region      = "eu-west-1"
}

# ==============================
# Example: Create an IAM role for a service account
# ==============================

resource "aws_iam_role" "my_app" {
  name = "my-app-irsa-role"

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
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:my-namespace:my-service-account"
          "${replace(module.irsa.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ==============================
# Example: Annotate a Kubernetes service account
# ==============================

resource "kubernetes_service_account" "my_app" {
  metadata {
    name      = "my-service-account"
    namespace = "my-namespace"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.my_app.arn
    }
  }
}

output "issuer_url" {
  value = module.irsa.issuer_url
}

output "oidc_provider_arn" {
  value = module.irsa.oidc_provider_arn
}
