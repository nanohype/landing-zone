################################################################################
# Bootstrap: Cilium CNI
################################################################################

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [yamlencode({
    eni = {
      enabled = true
    }
    ipam = {
      mode = "eni"
    }
    routingMode                = "native"
    egressMasqueradeInterfaces = "eth0"
    enableIPv4Masquerade       = false
    hubble = {
      enabled = true
      relay = {
        enabled = true
      }
      ui = {
        enabled = true
      }
    }
    encryption = {
      enabled = true
      type    = "wireguard"
    }
    bpf = {
      preallocateMaps = true
    }
    operator = {
      replicas = var.cilium_operator_replicas
    }
  })]

  lifecycle {
    ignore_changes = all
  }
}

################################################################################
# Disable aws-node DaemonSet (Cilium replaces VPC CNI)
################################################################################

resource "kubectl_manifest" "disable_aws_node" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "aws-node"
      namespace = "kube-system"
    }
    spec = {
      selector = {
        matchLabels = {
          "k8s-app" = "aws-node"
        }
      }
      template = {
        metadata = {
          labels = {
            "k8s-app" = "aws-node"
          }
        }
        spec = {
          nodeSelector = {
            "io.cilium/aws-node-enabled" = "true"
          }
          containers = [{
            name = "aws-node"
            # This DaemonSet is PARKED: the nodeSelector above matches no node, so this
            # container never schedules — the image is a required-but-inert field. Pin it to
            # an immutable no-op (never `:latest`), which also means that if a node ever did
            # carry the label, it would run pause, not a second CNI competing with Cilium.
            image = "registry.k8s.io/pause:3.10"
          }]
        }
      }
    }
  })

  force_new  = true
  depends_on = [helm_release.cilium]
}

################################################################################
# Reconcile EKS-managed addons against the new Cilium datapath
#
# The race: `lz-cluster` installs CoreDNS + `aws-ebs-csi-driver` (and other EKS
# managed addons) BEFORE this workspace runs, while VPC CNI is still the active
# datapath. Once Cilium takes over and `aws-node` is patched off (above), those
# pre-existing pods retain stale ENI-backed routes and can no longer reach the
# cluster service VIP (172.20.0.1) — manifesting as CrashLoopBackOff with errors
# like "dial tcp 172.20.0.1:443: i/o timeout".
#
# CoreDNS is the worst case and must be restarted too: its pods keep the stale
# datapath, so cluster DNS fails and everything resolving a Service name cascades
# — e.g. argocd-repo-server CrashLoops on its liveness probe and the app-of-apps
# can't render ("dns: lookup argocd-repo-server ... i/o timeout").
#
# We run an in-cluster Job (kubectl image) that, after Cilium reports Ready,
# `rollout restart`s the affected workloads (CoreDNS first, then EBS CSI) so
# they're recreated against the new datapath. Idempotent: on a subsequent apply where Cilium is unchanged
# the resource is a no-op (the Job name embeds a hash of the Cilium release
# ID, so it only re-runs when Cilium itself changes).
################################################################################

resource "kubernetes_service_account_v1" "bootstrap_reconciler" {
  metadata {
    name      = "cilium-bootstrap-reconciler"
    namespace = "kube-system"
  }
  depends_on = [helm_release.cilium]
}

resource "kubernetes_cluster_role_v1" "bootstrap_reconciler" {
  metadata {
    name = "cilium-bootstrap-reconciler"
  }
  # Just enough to `kubectl rollout restart` / `rollout status` on the
  # workloads we know need reconciliation. Scoped reads on pods so
  # `rollout status` can watch pod readiness.
  rule {
    api_groups = ["apps"]
    resources  = ["daemonsets", "deployments"]
    verbs      = ["get", "list", "watch", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "bootstrap_reconciler" {
  metadata {
    name = "cilium-bootstrap-reconciler"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.bootstrap_reconciler.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.bootstrap_reconciler.metadata[0].name
    namespace = kubernetes_service_account_v1.bootstrap_reconciler.metadata[0].namespace
  }
}

resource "kubernetes_job_v1" "restart_pre_cilium_addons" {
  metadata {
    # Name suffix is a stable hash of the cilium release id. Re-running this
    # workspace when cilium hasn't changed produces the same name → terraform
    # treats it as already-applied and skips re-creation.
    name      = "restart-pre-cilium-addons-${substr(sha1(helm_release.cilium.id), 0, 10)}"
    namespace = "kube-system"
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 3600 # auto-cleanup an hour after completion

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "cilium-bootstrap-reconciler"
          "app.kubernetes.io/component" = "bootstrap"
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.bootstrap_reconciler.metadata[0].name
        restart_policy       = "OnFailure"

        container {
          name    = "kubectl"
          image   = "docker.io/alpine/k8s:1.36.2"
          command = ["sh", "-c"]
          args = [<<-EOT
            set -e
            echo "Waiting for cilium DaemonSet to converge..."
            kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
            echo "Restarting CoreDNS to pick up the Cilium datapath..."
            kubectl -n kube-system rollout restart deployment/coredns
            echo "Restarting EBS CSI workloads to pick up the Cilium datapath..."
            kubectl -n kube-system rollout restart daemonset/ebs-csi-node
            kubectl -n kube-system rollout restart deployment/ebs-csi-controller
            echo "Waiting for CoreDNS + EBS CSI workloads to be Ready..."
            kubectl -n kube-system rollout status deployment/coredns --timeout=300s
            kubectl -n kube-system rollout status daemonset/ebs-csi-node --timeout=300s
            kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
            echo "Done."
          EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    helm_release.cilium,
    kubectl_manifest.disable_aws_node,
    kubernetes_cluster_role_binding_v1.bootstrap_reconciler,
  ]
}

################################################################################
# Bootstrap: ArgoCD
################################################################################

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    server = {
      replicas = var.argocd_server_replicas
    }
    controller = {
      replicas = 1
    }
    repoServer = {
      replicas = var.argocd_repo_replicas
    }
    applicationSet = {
      replicas = var.argocd_appset_replicas
    }

    # Teach ArgoCD how to read the health of OUR CRDs.
    #
    # Without this the agent-platform Application can NEVER report Healthy — so the
    # convergence gate (`kubectl wait --for=condition=Healthy applications --all`) can
    # never pass. It times out on every install, against a platform that is in fact
    # fully reconciled:
    #
    #   Platform/ops       phase=Ready   ModelAccessScoped=True  NamespaceReady=True
    #   ModelGateway/ops   phase=Ready   RoutesReconciled=True   (2 routes live)
    #   Tenant/protohypd   phase=Active  Aggregated=True
    #   BudgetPolicy/ops                 BudgetReconciled=True
    #
    #   argocd:  agent-platform  Progressing/Synced   <- forever
    #
    # ArgoCD ships health checks for the CRDs it knows and cannot guess at ours. This is
    # precisely what resource.customizations.health.* exists for; registering them is the
    # idiomatic answer, not a workaround.
    #
    # Keyed on status.phase, deliberately:
    #
    #   - observedGeneration is NOT usable here. Tenant and BudgetPolicy never publish
    #     it, and Platform's lags its own generation — so the usual "has the controller
    #     caught up" test reports a healthy platform as stalled.
    #
    #   - The conditions have MIXED POLARITY. `Suspended=False` and
    #     `TenantBudgetExceeded=False` are the GOOD states. The obvious check — "any
    #     condition is False, therefore unhealthy" — would mark every healthy Platform
    #     and every solvent Tenant as broken.
    #
    # A CR with no phase but a written status (BudgetPolicy) has been reconciled by its
    # controller, so it is Healthy. One with no status at all has not been seen yet, so
    # it is Progressing.
    configs = {
      # The API GROUP of each CRD, verified against the live cluster — they are NOT all
      # platform.nanohype.dev, which is the obvious and wrong assumption:
      #
      #   Platform, Tenant           platform.nanohype.dev
      #   ModelGateway               agents.nanohype.dev
      #   BudgetPolicy               governance.nanohype.dev
      #   AgentgatewayParameters     agentgateway.dev
      #
      # A customization keyed on the wrong group is silently ignored — ArgoCD does not
      # warn that a health check matches nothing, so the Application simply stays
      # Progressing and the key looks correct in the ConfigMap.
      cm = {
        "resource.customizations.health.platform.nanohype.dev_Platform"       = local.platform_cr_health
        "resource.customizations.health.platform.nanohype.dev_Tenant"         = local.platform_cr_health
        "resource.customizations.health.agents.nanohype.dev_ModelGateway"     = local.platform_cr_health
        "resource.customizations.health.governance.nanohype.dev_BudgetPolicy" = local.platform_cr_health
        # AgentgatewayParameters is deliberately ABSENT.
        #
        # It is a config-only CR: nothing reconciles it, so nothing ever writes a status
        # to it. Registering the health check above rated it Progressing ("awaiting
        # controller") forever — and one Progressing node is enough to hold the whole
        # agent-platform Application at Progressing, which is the exact failure the health
        # checks were added to fix.
        #
        # With no customization, ArgoCD returns nil health for it and treats it as
        # Healthy, which is correct: a config object with no controller has nothing to be
        # unhealthy about. The right check for a CR is "does a controller own this", not
        # "is it one of ours".
      }
    }
  })]

  # ArgoCD must come up on the SETTLED cilium datapath, not race it.
  #
  # depends_on = [helm_release.cilium] is not enough: a helm_release completes when the
  # RELEASE is deployed, not when the cilium DaemonSet is Ready on every node. ArgoCD
  # and the reconciler Job below both depended only on the release, so they ran in
  # parallel — and ArgoCD's pods could be scheduled while VPC CNI was still the active
  # datapath. They then kept stale ENI-backed routes and could not reach the cluster
  # service VIPs at all:
  #
  #   app-of-apps  ComparisonError: failed to generate manifest:
  #     rpc error: code = Unavailable desc = connection error:
  #     dial tcp 172.20.62.128:8081 (argocd-repo-server): i/o timeout
  #   application-controller: dial tcp 172.20.55.0:6379 (redis): i/o timeout
  #
  # Every pod Running, every endpoint present, and ArgoCD unable to talk to itself. The
  # app-of-apps generated nothing, so a fresh install produced an empty cluster that
  # looked healthy. Restarting ArgoCD fixed it instantly, which is what proved the race.
  #
  # The Job already does the waiting we need — it blocks on `kubectl rollout status
  # daemonset/cilium` and then restarts the workloads that pre-date cilium. Ordering
  # ArgoCD after it means ArgoCD starts on a converged datapath and never needs the
  # remediation. Fix the ordering, don't add ArgoCD to the restart list.
  depends_on = [kubernetes_job_v1.restart_pre_cilium_addons]
}

################################################################################
# ArgoCD Cluster Secret (drives ApplicationSet generators)
################################################################################


resource "kubernetes_secret_v1" "argocd_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
    labels = merge({
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = var.environment
      "account_id"                     = local.account_id
      "region"                         = var.region
      "cluster_name"                   = var.cluster_name
      "vpc_id"                         = var.vpc_id
      }, var.enable_agent_platform ? {
      # Opts this cluster into the eks-agent-platform operator ApplicationSet.
      # Disable to install the operator out of band (see enable_agent_platform).
      "eks-agent-platform/enabled" = "true"
      } : {}, var.enable_accelerators ? {
      # Opts this cluster into the GPU/accelerator ApplicationSet (gpu-operator,
      # nvidia-dra-driver). Off by default so non-GPU shapes skip GPU addons.
      "eks-agent-platform/accelerators" = "true"
    } : {})
    # Per-cluster wiring for the agent-platform operator: the EKS cluster name
    # (the operator creates the tenant Pod Identity associations on it) + the
    # deterministic operator role ARN (path-scoped, named by agent-iam as
    # <cluster_name>-agent-platform-operator). The eks-gitops operator ApplicationSet
    # reads these via the ArgoCD cluster generator and injects them as Helm
    # values, so the operator gets its config without the account ID ever being
    # committed to the public gitops repos. Annotations (not labels) because ARNs
    # contain characters that label values disallow.
    annotations = merge({
      # The addon catalog this cluster syncs from. Published here so the
      # ApplicationSets can template their own source repoURL off the cluster
      # generator ({{ index .metadata.annotations "gitops/repo-url" }}) instead of
      # hardcoding an org into the manifests. Without this every appset in a forked
      # catalog still pulls from the upstream org's repo, which makes the fork inert.
      "gitops/repo-url"    = var.gitops_repo_url
      "gitops/repo-branch" = var.gitops_repo_branch

      "eks-agent-platform/operator-role-arn" = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/eks-agent-platform/${var.cluster_name}-agent-platform-operator"
      }, var.enable_eval_runtime ? {
      # eval-runner reports bucket, read from the eval-runtime SSM param. The
      # eval-runner role is bound by Pod Identity, so no role ARN is published.
      "eks-agent-platform/eval-reports-bucket" = data.aws_ssm_parameter.eval_reports_bucket[0].value
      } : {}, var.enable_managed_monitoring ? {
      # Amazon Managed Grafana workspace URL, read from the managed-monitoring SSM
      # param. The dashboards ApplicationSet injects it into the Grafana CR.
      "monitoring/grafana-url" = data.aws_ssm_parameter.grafana_url[0].value
      # AMP query endpoint + workspace id. The opencost ApplicationSet reads the
      # workspace id to point opencost at Managed Prometheus through a sigv4 proxy.
      "monitoring/amp-endpoint"     = data.aws_ssm_parameter.amp_endpoint[0].value
      "monitoring/amp-workspace-id" = data.aws_ssm_parameter.amp_workspace_id[0].value
      } : {}, var.enable_velero_backup ? {
      # Velero backup bucket, read from the SSM parameter the cluster-addons
      # component publishes. The addons-velero ApplicationSet injects it as the
      # backup + snapshot storage location. Absent where Velero isn't run
      # (development/hub) — the addons-velero generator excludes those clusters.
      "velero/backup-bucket" = data.aws_ssm_parameter.velero_bucket[0].value
      } : {}, var.enable_external_dns ? {
      # This environment's primary domain, read from the SSM parameter the dns
      # component publishes. The addons-external-dns ApplicationSet uses it as
      # external-dns's domainFilter, confining the controller to this cluster's
      # Route53 zone. Absent on the hub, which runs no external-dns.
      "external-dns/domain-filter" = data.aws_ssm_parameter.external_dns_domain_filter[0].value
    } : {})
  }

  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
  }

  depends_on = [helm_release.argocd]
}

################################################################################
# ArgoCD Platform AppProject
################################################################################

resource "kubectl_manifest" "platform_project" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "platform"
      namespace = "argocd"
    }
    spec = {
      description = "Platform infrastructure addons"
      sourceRepos = ["*"]
      destinations = [{
        server    = "https://kubernetes.default.svc"
        namespace = "*"
      }]
      clusterResourceWhitelist = [{
        group = "*"
        kind  = "*"
      }]
    }
  })

  depends_on = [helm_release.argocd]
}

################################################################################
# App-of-Apps Bootstrap Application
################################################################################

resource "kubectl_manifest" "app_of_apps" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "app-of-apps"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_repo_branch
        path           = "applicationsets"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [kubernetes_secret_v1.argocd_cluster]
}
