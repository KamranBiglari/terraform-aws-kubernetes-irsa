# ==============================
# Pod Identity Webhook
# Mutates pods with ServiceAccount annotations to inject
# AWS credentials via STS AssumeRoleWithWebIdentity
# ==============================

resource "helm_release" "pod_identity_webhook" {
  count = var.webhook_enabled ? 1 : 0

  name       = "amazon-eks-pod-identity-webhook"
  repository = "https://jkroepke.github.io/helm-charts"
  chart      = "amazon-eks-pod-identity-webhook"
  namespace  = var.webhook_namespace

  values = [yamlencode({
    nodeSelector = var.webhook_node_selector

    tolerations = var.webhook_tolerations

    config = {
      defaultAwsRegion = var.aws_region
    }

    pki = {
      certManager = {
        enabled = true
      }
    }
  })]

  depends_on = [
    aws_iam_openid_connect_provider.k8s
  ]
}
