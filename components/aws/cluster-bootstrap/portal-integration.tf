################################################################################
# Portal integration: read-only identity + durable token
#
# Ships the cluster with the identity the portal's tenant watcher needs, so
# registering a cluster with the portal is "feed the tofu outputs to the portal"
# rather than a manual `kubectl create` of a ServiceAccount, ClusterRole,
# binding, and a short-lived `kubectl create token` that expires out from under
# the watcher.
#
# portal_reader_token is a long-lived, Secret-backed ServiceAccount token, so it
# lands in tofu state (encrypted S3). That's the standard pattern for a platform
# service identity; the cleaner long-term is the portal reusing ArgoCD's own
# cluster registry instead of a separate token — tracked as a portal-side
# follow-up. The ArgoCD credential for the private tenants repo is wired in a
# companion change (it needs the GitHub provider).
################################################################################

resource "kubernetes_service_account_v1" "portal_reader" {
  count = var.enable_portal_reader ? 1 : 0
  metadata {
    name      = "portal-reader"
    namespace = "kube-system"
  }
  depends_on = [helm_release.cilium]
}

resource "kubernetes_cluster_role_v1" "portal_reader" {
  count = var.enable_portal_reader ? 1 : 0
  metadata {
    name = "portal-reader"
  }
  # The watcher lists Platform/Tenant CRs; nodes + namespaces back the
  # portal connection-test summary. Strictly read-only.
  rule {
    api_groups = ["platform.nanohype.dev"]
    resources  = ["tenants", "platforms"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "namespaces"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "portal_reader" {
  count = var.enable_portal_reader ? 1 : 0
  metadata {
    name = "portal-reader"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.portal_reader[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.portal_reader[0].metadata[0].name
    namespace = "kube-system"
  }
}

# Durable, non-expiring token for portal-reader. wait_for_service_account_token
# blocks until the token controller populates .data.token, so it's available as
# an output without a separate data source or sleep.
resource "kubernetes_secret_v1" "portal_reader_token" {
  count = var.enable_portal_reader ? 1 : 0
  metadata {
    name      = "portal-reader-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.portal_reader[0].metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
