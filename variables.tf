# ==============================
# Required Variables
# ==============================

variable "name" {
  description = "Name prefix for all resources (e.g., 'myapp-k8s-infra')"
  type        = string
}

variable "environment" {
  description = "Environment name used in resource naming (e.g., dev, staging, prod)"
  type        = string
}

variable "oidc_domain" {
  description = "Custom domain for the OIDC discovery endpoint (e.g., 'myapp-oidc.example.com')"
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS records (ACM validation and CloudFront alias)"
  type        = string
}

variable "kubeconfig_path" {
  description = "Absolute path to kubeconfig file used to fetch JWKS from the Kubernetes API"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the Pod Identity Webhook default configuration"
  type        = string
}

# ==============================
# Optional Variables
# ==============================

variable "webhook_enabled" {
  description = "Enable deployment of the Amazon EKS Pod Identity Webhook via Helm"
  type        = bool
  default     = true
}

variable "webhook_namespace" {
  description = "Kubernetes namespace for the Pod Identity Webhook"
  type        = string
  default     = "kube-system"
}

variable "webhook_node_selector" {
  description = "Node selector labels for Pod Identity Webhook scheduling"
  type        = map(string)
  default     = {}
}

variable "webhook_tolerations" {
  description = "Tolerations for Pod Identity Webhook pods"
  type = list(object({
    key      = string
    operator = string
    value    = string
    effect   = string
  }))
  default = []
}

variable "cloudfront_price_class" {
  description = "CloudFront distribution price class"
  type        = string
  default     = "PriceClass_100"
}

variable "cache_default_ttl" {
  description = "Default TTL in seconds for CloudFront cache"
  type        = number
  default     = 3600
}

variable "cache_max_ttl" {
  description = "Maximum TTL in seconds for CloudFront cache"
  type        = number
  default     = 86400
}

variable "cache_min_ttl" {
  description = "Minimum TTL in seconds for CloudFront cache"
  type        = number
  default     = 60
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
