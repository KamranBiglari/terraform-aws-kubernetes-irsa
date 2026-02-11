output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider - use in IAM trust policies"
  value       = aws_iam_openid_connect_provider.k8s.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider (includes https://) - use in IAM trust policy conditions"
  value       = aws_iam_openid_connect_provider.k8s.url
}

output "issuer_url" {
  description = "OIDC issuer URL - use for Kubernetes API server --service-account-issuer flag"
  value       = local.issuer_url
}

output "jwks_uri" {
  description = "JWKS endpoint URL - use for Kubernetes API server --service-account-jwks-uri flag"
  value       = "${local.issuer_url}/keys.json"
}
