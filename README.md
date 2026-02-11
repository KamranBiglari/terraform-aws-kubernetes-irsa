# Kubernetes IRSA - IAM Roles for Service Accounts (Non-EKS)

[![Terraform Registry](https://img.shields.io/badge/Terraform%20Registry-KamranBiglari%2Fkubernetes--irsa-blue)](https://registry.terraform.io/modules/KamranBiglari/kubernetes-irsa/aws/latest)
[![GitHub](https://img.shields.io/badge/GitHub-KamranBiglari%2Fterraform--aws--kubernetes--irsa-black)](https://github.com/KamranBiglari/terraform-aws-kubernetes-irsa)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](https://github.com/KamranBiglari/terraform-aws-kubernetes-irsa/blob/main/LICENSE)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.0-purple)
![AWS](https://img.shields.io/badge/AWS-IAM%20%7C%20S3%20%7C%20CloudFront-orange)

> A production-ready Terraform module that sets up OIDC-based IAM Roles for Service Accounts (IRSA) on non-EKS Kubernetes clusters - enabling pods to assume AWS IAM roles using service account tokens, the same mechanism used by Amazon EKS.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
  - [Architecture Diagram](#architecture-diagram)
  - [Component Breakdown](#component-breakdown)
  - [Execution Flow](#execution-flow)
- [Design Decisions](#design-decisions)
- [Module Structure](#module-structure)
  - [File-by-File Reference](#file-by-file-reference)
- [Requirements](#requirements)
- [Providers](#providers)
- [Input Variables](#input-variables)
- [Outputs](#outputs)
- [Examples](#examples)
  - [Minimal Example](#1-minimal-example)
  - [With Webhook Customization](#2-with-webhook-customization)
  - [Creating an IAM Role for a Service Account](#3-creating-an-iam-role-for-a-service-account)
  - [Kubernetes API Server Configuration](#4-kubernetes-api-server-configuration)
- [Prerequisites](#prerequisites)
- [Security Considerations](#security-considerations)
- [Limitations & Caveats](#limitations--caveats)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

![Kubernetes IRSA](infographic.png)


This module solves a specific problem: **how to enable Kubernetes pods on non-EKS clusters (Talos, kubeadm, k3s, etc.) to securely access AWS services using IAM roles**, without embedding long-lived credentials.

It creates the full OIDC discovery infrastructure required for AWS STS to validate Kubernetes service account tokens. This includes an S3 bucket for hosting OIDC discovery documents, a CloudFront distribution with a custom domain and TLS certificate, an IAM OIDC provider, and an optional Pod Identity Webhook deployment that automatically injects AWS credential environment variables into annotated pods.

### Key Features

- **EKS-compatible IRSA for any Kubernetes cluster** - works with Talos, kubeadm, k3s, RKE2, or any conformant cluster.
- **Automated OIDC discovery hosting** - publishes `.well-known/openid-configuration` and `keys.json` to S3 via CloudFront with a custom domain.
- **ACM-managed TLS certificates** - automatic DNS-validated certificates for the OIDC endpoint.
- **IAM OIDC provider registration** - creates the AWS trust relationship for Kubernetes service account tokens.
- **Pod Identity Webhook** - optional Helm deployment that mutates pods to inject `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and `AWS_DEFAULT_REGION` environment variables.
- **CloudFront caching** - configurable TTLs for OIDC document caching.
- **Webhook scheduling control** - node selectors and tolerations for webhook pod placement.
- **JWKS auto-retrieval** - automatically fetches the JSON Web Key Set from the running Kubernetes API server.

---

## How It Works

### Architecture Diagram

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Kubernetes Pod   │     │   AWS STS         │     │   AWS IAM        │
│                   │     │                   │     │                  │
│  ServiceAccount   │────>│  AssumeRoleWith   │────>│  IAM Role +      │
│  + OIDC Token     │     │  WebIdentity      │     │  Policies        │
└──────────────────┘     └────────┬──────────┘     └──────────────────┘
                                  │
                                  │ Validates token via
                                  │
                         ┌────────▼──────────┐
                         │  OIDC Discovery    │
                         │                    │
                         │  CloudFront + S3   │
                         │  oidc.example.com  │
                         └────────────────────┘
```

### Component Breakdown

| Component | Technology | Purpose |
|---|---|---|
| **OIDC Discovery Bucket** | AWS S3 | Hosts `openid-configuration` and `keys.json` documents |
| **CDN** | AWS CloudFront | Serves OIDC documents over HTTPS with caching |
| **TLS Certificate** | AWS ACM (us-east-1) | Provides trusted TLS for the OIDC custom domain |
| **DNS** | AWS Route53 | Maps the OIDC domain to the CloudFront distribution |
| **Origin Access** | CloudFront OAC | Secures S3 access - only CloudFront can read the bucket |
| **Identity Provider** | AWS IAM OIDC | Enables STS to trust Kubernetes service account tokens |
| **Webhook** | Helm (Pod Identity Webhook) | Mutates pods to inject AWS credential environment variables |
| **JWKS Source** | Kubernetes API (`/openid/v1/jwks`) | Provides the public keys used to sign service account tokens |

### Execution Flow

1. **JWKS Retrieval** - during `terraform apply`, the module runs `kubectl get --raw /openid/v1/jwks` against your cluster to fetch the JSON Web Key Set.
2. **S3 Upload** - the OIDC discovery document (`.well-known/openid-configuration`) and the JWKS (`keys.json`) are uploaded to an S3 bucket.
3. **CloudFront + ACM** - a CloudFront distribution is created with a custom domain and a DNS-validated ACM certificate, serving the S3 bucket contents over HTTPS.
4. **IAM OIDC Provider** - an IAM OpenID Connect provider is registered in AWS, pointing to the custom domain. AWS STS uses this to validate tokens.
5. **Pod Identity Webhook** - if enabled, the webhook is deployed via Helm. It watches for pods with annotated service accounts (`eks.amazonaws.com/role-arn`) and injects the `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and `AWS_DEFAULT_REGION` environment variables.
6. **Token Validation** - when a pod calls an AWS API, the SDK reads the projected service account token, calls `sts:AssumeRoleWithWebIdentity`, and STS validates the token against the OIDC discovery endpoint before issuing temporary credentials.

---

## Design Decisions

### Why CloudFront + S3?

AWS STS validates OIDC tokens by fetching the discovery documents from the issuer URL. These documents must be served over HTTPS with a valid TLS certificate. Using CloudFront in front of S3 provides a globally available, cached, and TLS-secured endpoint without running any servers.

### Why a Custom Domain?

The Kubernetes API server's `--service-account-issuer` flag must match the OIDC provider URL exactly. Using a custom domain (e.g., `my-cluster-oidc.example.com`) gives you a stable, human-readable issuer URL that doesn't change if you recreate infrastructure.

### Why Origin Access Control (OAC)?

The S3 bucket is fully private (all public access blocked). CloudFront uses OAC with SigV4 signing to securely read from the bucket. This ensures the OIDC documents are only accessible through the CloudFront distribution, not directly from S3.

### Why Pod Identity Webhook?

On EKS, pod identity injection happens automatically. On non-EKS clusters, the [Amazon EKS Pod Identity Webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) provides the same functionality. It's a mutating admission webhook that watches for service accounts annotated with `eks.amazonaws.com/role-arn` and injects the necessary environment variables and projected token volume.

### Why cert-manager?

The Pod Identity Webhook requires TLS certificates for its admission webhook endpoint. cert-manager automates the issuance and renewal of these certificates within the cluster.

---

## Module Structure

```
terraform-aws-kubernetes-irsa/
├── .github/
│   └── workflows/
│       └── release.yaml        # GitHub Actions workflow for versioned releases
├── examples/
│   ├── basic/
│   │   └── main.tf             # Minimal configuration example
│   └── complete/
│       └── main.tf             # Full setup with multiple IAM roles
├── main.tf                     # Core resources: S3, CloudFront, ACM, Route53, IAM OIDC
├── webhook.tf                  # Pod Identity Webhook Helm release
├── variables.tf                # Input variable declarations
├── outputs.tf                  # Output values
├── versions.tf                 # Required Terraform and provider versions
├── LICENSE                     # Apache 2.0
└── README.md                   # Documentation
```

### File-by-File Reference

#### `main.tf` - Core OIDC Infrastructure

This file orchestrates all the resources for the OIDC discovery endpoint:

- **`data.external.cluster_jwks`** - executes `kubectl get --raw /openid/v1/jwks` to fetch the cluster's JSON Web Key Set.
- **`aws_s3_bucket.oidc_discovery`** - creates a private S3 bucket for hosting OIDC documents.
- **`aws_s3_bucket_public_access_block.oidc_discovery`** - blocks all public access to the bucket.
- **`aws_cloudfront_origin_access_control.oidc`** - configures OAC with SigV4 signing for secure S3 access.
- **`aws_s3_bucket_policy.oidc_cloudfront`** - grants CloudFront read access to the bucket via OAC.
- **`aws_acm_certificate.oidc`** - requests a DNS-validated ACM certificate in `us-east-1` (required by CloudFront).
- **`aws_route53_record.oidc_cert_validation`** - creates DNS records for ACM certificate validation.
- **`aws_cloudfront_distribution.oidc`** - serves the OIDC documents over HTTPS with the custom domain.
- **`aws_cloudfront_cache_policy.oidc`** - configures caching TTLs for OIDC documents.
- **`aws_route53_record.oidc`** - creates an alias record pointing the custom domain to CloudFront.
- **`aws_s3_object.openid_configuration`** - uploads the `.well-known/openid-configuration` document.
- **`aws_s3_object.jwks`** - uploads the `keys.json` (JWKS) document.
- **`data.tls_certificate.oidc`** - fetches the TLS certificate thumbprint for the IAM OIDC provider.
- **`aws_iam_openid_connect_provider.k8s`** - registers the IAM OIDC provider with `sts.amazonaws.com` as the audience.

#### `webhook.tf` - Pod Identity Webhook

- **`helm_release.pod_identity_webhook`** - conditionally deploys the Amazon EKS Pod Identity Webhook via the `jkroepke/helm-charts` repository. Supports node selectors, tolerations, default AWS region, and cert-manager integration.

#### `variables.tf` - Configuration Knobs

Defines all required and optional input variables including resource naming, OIDC domain, Route53 zone, kubeconfig path, webhook settings, CloudFront cache tuning, and resource tags.

#### `outputs.tf` - Integration Points

Exposes the OIDC provider ARN, OIDC provider URL, issuer URL, and JWKS URI - everything needed to create IAM trust policies and configure the Kubernetes API server.

#### `versions.tf` - Provider Requirements

Requires Terraform >= 1.0 with AWS (>= 4.0, including `us_east_1` alias), Helm (>= 2.0), TLS (>= 3.0), and External (>= 2.0) providers.

---

## Requirements

| Requirement | Version |
|---|---|
| Terraform | >= 1.0 |
| AWS Provider | >= 4.0 |
| Helm Provider | >= 2.0 |
| TLS Provider | >= 3.0 |
| External Provider | >= 2.0 |

**Important**: The machine running `terraform apply` must have `bash`, `kubectl`, and `jq` available, as the module executes `kubectl get --raw /openid/v1/jwks` to fetch the cluster's JWKS.

---

## Providers

This module requires multiple AWS provider configurations because CloudFront requires ACM certificates in `us-east-1`:

```hcl
provider "aws" {
  region = "eu-west-1"  # Your primary region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"  # Required for ACM + CloudFront
}

provider "helm" {
  kubernetes {
    config_path = "./kubeconfig"
  }
}
```

---

## Input Variables

| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `string` | n/a | **Yes** | Name prefix for all resources (e.g., `"myapp-k8s-infra"`) |
| `environment` | `string` | n/a | **Yes** | Environment name used in resource naming (e.g., `dev`, `staging`, `prod`) |
| `oidc_domain` | `string` | n/a | **Yes** | Custom domain for the OIDC discovery endpoint (e.g., `"myapp-oidc.example.com"`) |
| `route53_zone_id` | `string` | n/a | **Yes** | Route53 hosted zone ID for DNS records (ACM validation and CloudFront alias) |
| `kubeconfig_path` | `string` | n/a | **Yes** | Absolute path to kubeconfig file used to fetch JWKS from the Kubernetes API |
| `aws_region` | `string` | n/a | **Yes** | AWS region for the Pod Identity Webhook default configuration |
| `webhook_enabled` | `bool` | `true` | No | Enable deployment of the Amazon EKS Pod Identity Webhook via Helm |
| `webhook_namespace` | `string` | `"kube-system"` | No | Kubernetes namespace for the Pod Identity Webhook |
| `webhook_node_selector` | `map(string)` | `{}` | No | Node selector labels for Pod Identity Webhook scheduling |
| `webhook_tolerations` | `list(object)` | `[]` | No | Tolerations for Pod Identity Webhook pods |
| `cloudfront_price_class` | `string` | `"PriceClass_100"` | No | CloudFront distribution price class |
| `cache_default_ttl` | `number` | `3600` | No | Default TTL in seconds for CloudFront cache |
| `cache_max_ttl` | `number` | `86400` | No | Maximum TTL in seconds for CloudFront cache |
| `cache_min_ttl` | `number` | `60` | No | Minimum TTL in seconds for CloudFront cache |
| `tags` | `map(string)` | `{}` | No | Additional tags to apply to all resources |

---

## Outputs

| Name | Description |
|---|---|
| `oidc_provider_arn` | ARN of the IAM OIDC provider - use in IAM trust policies |
| `oidc_provider_url` | URL of the IAM OIDC provider (includes `https://`) - use in IAM trust policy conditions |
| `issuer_url` | OIDC issuer URL - use for Kubernetes API server `--service-account-issuer` flag |
| `jwks_uri` | JWKS endpoint URL - use for Kubernetes API server `--service-account-jwks-uri` flag |

---

## Examples

### 1. Minimal Example

Deploy the IRSA infrastructure with default settings:

```hcl
module "irsa" {
  source  = "KamranBiglari/kubernetes-irsa/aws"
  version = "0.1.0"

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
```

### 2. With Webhook Customization

Full setup with webhook scheduling constraints and CloudFront cache tuning:

```hcl
module "irsa" {
  source  = "KamranBiglari/kubernetes-irsa/aws"
  version = "0.1.0"

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
```

### 3. Creating an IAM Role for a Service Account

After the module is deployed, create IAM roles that trust the OIDC provider:

```hcl
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
```

Then annotate your Kubernetes service account:

```hcl
resource "kubernetes_service_account" "my_app" {
  metadata {
    name      = "my-service-account"
    namespace = "my-namespace"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.my_app.arn
    }
  }
}
```

### 4. Kubernetes API Server Configuration

When setting up the Kubernetes control plane, configure the API server with the module's OIDC endpoints:

```hcl
# Example with Talos Linux
control_plane_config_patches = [
  {
    cluster = {
      apiServer = {
        extraArgs = {
          "service-account-issuer"  = module.irsa.issuer_url
          "service-account-jwks-uri" = module.irsa.jwks_uri
          "api-audiences"           = "sts.amazonaws.com,https://kubernetes.default.svc"
        }
      }
    }
  }
]
```

> **Note:** The API server configuration must happen before or alongside the IRSA module deployment, since the JWKS are fetched from the running cluster. Use `depends_on` to ensure proper ordering.

---

## Prerequisites

Before deploying this module, ensure the following are in place:

| Prerequisite | Details |
|---|---|
| **Kubernetes cluster** | A running cluster with `kubectl` access via kubeconfig |
| **API server flags** | `--service-account-issuer` pointing to the OIDC domain, `--service-account-jwks-uri` pointing to the JWKS endpoint, `--api-audiences` including `sts.amazonaws.com` |
| **Route53 hosted zone** | A hosted zone for the OIDC domain DNS records |
| **cert-manager** | Installed in the cluster (required by the Pod Identity Webhook for TLS certificates) |
| **Local tools** | `bash`, `kubectl`, and `jq` available on the machine running Terraform |

---

## Security Considerations

### OIDC Endpoint

- The OIDC discovery documents are public by design - AWS STS must be able to fetch them to validate tokens.
- The S3 bucket itself is fully private; documents are only accessible through CloudFront.
- CloudFront enforces HTTPS-only access with TLS 1.2+.

### IAM Trust Policies

- Always scope IAM trust policies to specific service accounts using the `:sub` condition (e.g., `system:serviceaccount:<namespace>:<name>`).
- Always include the `:aud` condition set to `sts.amazonaws.com` to prevent token reuse across providers.
- Follow the principle of least privilege when attaching IAM policies to IRSA roles.

### Token Security

- Kubernetes service account tokens are short-lived (typically 1 hour) and audience-bound.
- Tokens are projected into pods as files and automatically rotated by the kubelet.
- AWS STS validates the token signature, issuer, audience, and expiration before issuing credentials.

### Webhook Security

- The Pod Identity Webhook uses cert-manager for TLS, ensuring secure communication with the API server.
- The webhook only mutates pods that have explicitly annotated service accounts.

---

## Limitations & Caveats

| Limitation | Details |
|---|---|
| **API server configuration required** | The Kubernetes API server must be configured with `--service-account-issuer`, `--service-account-jwks-uri`, and `--api-audiences` before tokens can be validated. |
| **cert-manager dependency** | The Pod Identity Webhook requires cert-manager for TLS certificate management. Install it before enabling the webhook. |
| **JWKS retrieval at apply time** | The module fetches JWKS via `kubectl` during `terraform apply`. The cluster must be reachable and the kubeconfig valid at that time. |
| **CloudFront propagation** | Initial CloudFront distribution creation can take 10-15 minutes. Subsequent updates are faster. |
| **ACM certificate in us-east-1** | CloudFront requires ACM certificates in `us-east-1`, hence the dual provider configuration. |
| **Single cluster per module instance** | Each module instance supports one Kubernetes cluster. For multiple clusters, use separate module instances with different OIDC domains. |
| **DNS propagation** | ACM DNS validation and Route53 record propagation may add a few minutes to the initial deployment. |

---

## Troubleshooting

### STS Returns "Invalid Identity Token"

Verify that the OIDC discovery endpoint is accessible and returns valid JSON:

```bash
curl -s https://your-oidc-domain.example.com/.well-known/openid-configuration | jq .
curl -s https://your-oidc-domain.example.com/keys.json | jq .
```

Ensure the `issuer` field in the discovery document matches the `--service-account-issuer` configured on the API server.

### Pods Not Getting AWS Credentials

Check that the Pod Identity Webhook is running:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=amazon-eks-pod-identity-webhook
```

Verify the service account has the correct annotation:

```bash
kubectl get sa -n <namespace> <service-account> -o jsonpath='{.metadata.annotations}'
```

### JWKS Retrieval Fails During Apply

Ensure `kubectl` can reach the cluster:

```bash
kubectl --kubeconfig=/path/to/kubeconfig get --raw /openid/v1/jwks
```

If this fails, check that the API server is running and the kubeconfig is valid.

### CloudFront Returns 403

Check that the S3 bucket policy allows CloudFront OAC access and that the bucket name matches. Verify the CloudFront distribution has the correct origin configured.

### ACM Certificate Stuck in Pending Validation

Ensure the Route53 hosted zone ID is correct and the DNS validation records were created:

```bash
aws acm describe-certificate --certificate-arn <arn> --region us-east-1 --query 'Certificate.DomainValidationOptions'
```

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

---

## License

This module is licensed under the [MIT License](https://github.com/KamranBiglari/terraform-aws-kubernetes-irsa/blob/main/LICENSE).

---

## Author

**Kamran Biglari** - [GitHub](https://github.com/KamranBiglari)

Published on the [Terraform Registry](https://registry.terraform.io/modules/KamranBiglari/kubernetes-irsa/aws/latest).
