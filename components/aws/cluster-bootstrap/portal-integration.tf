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
    kind = "ServiceAccount"
    name = kubernetes_service_account_v1.portal_reader[0].metadata[0].name
    # A ServiceAccount subject MUST carry an empty apiGroup — it lives in the core API
    # group, and the API server rejects anything else:
    #
    #   subjects[0].apiGroup: Unsupported value: "rbac.authorization.k8s.io":
    #                         supported values: ""
    #
    # The kubernetes provider does not leave api_group unset when it is omitted; it sends
    # the RBAC group, which is right for a User or Group subject and wrong for this one.
    # So it has to be set explicitly, even though "" reads like a no-op.
    #
    # This only surfaces on an UPDATE to an existing binding, which is why it survived
    # every create-path test: a fresh apply writes the subject once and never validates it
    # against a prior one.
    api_group = ""
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

################################################################################
# ArgoCD credential for the private tenants repo (optional)
#
# When tenants_repo_url is set: generate a read-only deploy key, register it on
# the repo via the GitHub provider, and write the matching ArgoCD repository
# Secret — replacing a manual `gh repo deploy-key add` + hand-crafted Secret, so
# ArgoCD can pull the portal-committed tenant manifests. Per-cluster key, removed
# from the repo when the cluster is destroyed.
################################################################################

locals {
  # git@github.com:nanohype/tenants.git     -> nanohype/tenants
  # https://github.com/nanohype/tenants.git -> nanohype/tenants
  tenants_repo_slug  = var.tenants_repo_url == "" ? "" : trimsuffix(replace(replace(var.tenants_repo_url, "git@github.com:", ""), "https://github.com/", ""), ".git")
  tenants_repo_owner = var.tenants_repo_url == "" ? "" : split("/", local.tenants_repo_slug)[0]
  tenants_repo_name  = var.tenants_repo_url == "" ? "" : split("/", local.tenants_repo_slug)[1]
  wire_tenants_repo  = var.tenants_repo_url != ""
}

resource "tls_private_key" "argocd_tenants" {
  count     = local.wire_tenants_repo ? 1 : 0
  algorithm = "ED25519"
}

resource "github_repository_deploy_key" "argocd_tenants" {
  count      = local.wire_tenants_repo ? 1 : 0
  repository = local.tenants_repo_name
  title      = "argocd-${var.cluster_name}-ro"
  key        = tls_private_key.argocd_tenants[0].public_key_openssh
  read_only  = true
}

resource "kubernetes_secret_v1" "argocd_tenants_repo" {
  count = local.wire_tenants_repo ? 1 : 0
  metadata {
    name      = "tenants-repo"
    namespace = helm_release.argocd.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    type          = "git"
    url           = var.tenants_repo_url
    sshPrivateKey = tls_private_key.argocd_tenants[0].private_key_openssh
  }
  depends_on = [github_repository_deploy_key.argocd_tenants]
}
