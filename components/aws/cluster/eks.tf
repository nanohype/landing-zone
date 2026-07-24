################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  endpoint_public_access = var.cluster_endpoint_public_access
  # Pass the allow-list straight through — no 0.0.0.0/0 fallback. Defaulting an empty list to
  # world-open turned "operator enabled public access but forgot to scope it" into a silently
  # internet-reachable API server; the variable validation now rejects that case at plan time
  # instead. When public access is off, the module ignores this value.
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  endpoint_private_access      = true

  authentication_mode = "API"
  # Grant the principal that applies this component cluster-admin via an
  # access entry. Without it an API-auth cluster has no human-reachable
  # admin (only the EKS service + node roles are mapped), so nothing can
  # bootstrap ArgoCD/addons. Maps the applier dynamically — no hardcoded ARN.
  enable_cluster_creator_admin_permissions = true

  create_kms_key = false

  # Cross-account fleet-vend gating: the cluster IAM role + the encryption managed
  # policy land under var.cluster_iam_role_path so the vend role's CreateRole /
  # CreatePolicy (scoped to /eks-fleet/*) is satisfied. Defaults "/" = same-account.
  iam_role_path                 = var.cluster_iam_role_path
  iam_role_permissions_boundary = local.cluster_permissions_boundary
  encryption_policy_path        = var.cluster_iam_role_path

  encryption_config = {
    provider_key_arn = module.kms.key_arn
    resources        = ["secrets"]
  }

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # EKS managed add-ons (AWS-managed lifecycle)
  # vpc-cni must be installed before node groups via before_compute
  #
  # Versions are PINNED via var.eks_addon_versions (defaulted to the EKS-default
  # versions for the default cluster_version) rather than most_recent = true.
  # most_recent silently rolls each addon to the newest build on every apply, so
  # two applies weeks apart produce different clusters and an unvetted addon
  # release lands with no review. Pinning makes the addon set reproducible and
  # turns upgrades into deliberate, reviewable version bumps. An addon left out
  # of the map falls back to most_recent, so adding one never hard-fails.
  addons = {
    vpc-cni = {
      addon_version               = lookup(var.eks_addon_versions, "vpc-cni", null)
      most_recent                 = lookup(var.eks_addon_versions, "vpc-cni", null) == null
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      # Prefix delegation packs a /28 (16 IPs) onto each ENI slot instead of a single
      # secondary IP, so pod density stops being bounded by the instance's secondary-IP
      # count. WARM_PREFIX_TARGET=1 is the AWS-recommended balance: keep exactly one
      # spare /28 warm per node, so a fresh node can place pods immediately instead of
      # serial-attaching IPs under burst scheduling — without hoarding a nodeful of
      # unused addresses.
      #
      # MINIMUM_IP_TARGET is deliberately unset. It (with WARM_IP_TARGET) overrides
      # WARM_PREFIX_TARGET and only earns its keep when IPv4 space is scarce enough to
      # ration; the create-mode /16 and owner-sized adopt subnets are not, and one warm
      # /28 already covers the system node group's steady pod set. Setting a floor here
      # would turn WARM_PREFIX_TARGET into dead config. Mode-independent — cheap
      # insurance against IP exhaustion whether the VPC is owned (create) or adopted.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      addon_version               = lookup(var.eks_addon_versions, "coredns", null)
      most_recent                 = lookup(var.eks_addon_versions, "coredns", null) == null
      resolve_conflicts_on_create = "OVERWRITE"
    }
    kube-proxy = {
      addon_version               = lookup(var.eks_addon_versions, "kube-proxy", null)
      most_recent                 = lookup(var.eks_addon_versions, "kube-proxy", null) == null
      resolve_conflicts_on_create = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      addon_version               = lookup(var.eks_addon_versions, "aws-ebs-csi-driver", null)
      most_recent                 = lookup(var.eks_addon_versions, "aws-ebs-csi-driver", null) == null
      resolve_conflicts_on_create = "OVERWRITE"
      # Credentials come from the ebs_csi_irsa Pod Identity association
      # (pods.eks.amazonaws.com trust) + the eks-pod-identity-agent addon, so the
      # addon takes no service_account_role_arn — that annotates the SA for
      # IRSA/web-identity, which a Pod-Identity-only role can't satisfy and the
      # controller crashloops on.
    }
    # Pod Identity is the platform-wide identity path: pods obtain role credentials from
    # the agent's local endpoint, not via AssumeRoleWithWebIdentity against STS. The
    # network also carries an eks-auth interface VPC endpoint, so credential vending
    # never leaves the VPC — the global-STS-endpoint hang (a slow us-east-1 STS call
    # stalling pod startup) does not apply to platform-managed identity, which is why no
    # AWS_STS_REGIONAL_ENDPOINTS mutation is imposed cluster-wide here.
    #
    # It surfaces only for tenant workloads still on IRSA web-identity. Those wanting the
    # regional-STS guarantee set AWS_STS_REGIONAL_ENDPOINTS=regional in their own pod
    # spec — a per-workload opt-in the tenant owns, not a blanket cluster policy.
    eks-pod-identity-agent = {
      addon_version               = lookup(var.eks_addon_versions, "eks-pod-identity-agent", null)
      most_recent                 = lookup(var.eks_addon_versions, "eks-pod-identity-agent", null) == null
      resolve_conflicts_on_create = "OVERWRITE"
    }
    # Container Insights. The observability component alarms and dashboards read
    # the ContainerInsights CloudWatch namespace, and this addon is what fills
    # it: without a producer those alarms sit INSUFFICIENT_DATA and the
    # composite rollups can never fire.
    #
    # enhanced_container_insights is NOT optional here. It is what publishes the
    # ClusterName-only dimension rollups the alarms key on — the classic metric
    # set publishes node_cpu_utilization and node_memory_utilization only under
    # ClusterName+InstanceId+NodeName, so a cluster-scoped alarm on either finds
    # nothing. cluster_failed_node_count is ClusterName-only in both sets;
    # everything else the alarms watch needs enhanced.
    #
    # containerLogs is off on purpose, at BOTH tiers. It would tail
    # /var/log/pods into /aws/containerinsights/<cluster>/application — exactly
    # the logs the OpenTelemetry node agent already collects and forwards to the
    # gateway. Two collectors on the same files is double ingestion and double
    # cost, so this addon stays the metrics producer and the collector keeps
    # owning logs. That is also what lets floor and full run the same collector
    # pipeline with only the exporters differing. Disabling it does not touch
    # the metrics path.
    #
    # Pinned to the EKS-default version for cluster_version 1.36, resolved from
    # the registry. The pin is load-bearing beyond reproducibility here: from
    # v6.2.0 this addon can run either the Classic pipeline (CloudWatch-format
    # metric names, EMF) or the OTel one (Prometheus-native names), and the two
    # publish DIFFERENT metric names. The observability component's alarms read
    # CloudWatch-format names — node_cpu_utilization, cluster_failed_node_count,
    # apiserver_request_total_5xx — so this cluster must stay on Classic, which
    # is what this version's own defaults select (containerInsights.enabled
    # true, otelContainerInsights.enabled false). A bump that flips that default
    # silently retargets every alarm at a metric that no longer exists.
    amazon-cloudwatch-observability = {
      addon_version               = lookup(var.eks_addon_versions, "amazon-cloudwatch-observability", null)
      most_recent                 = lookup(var.eks_addon_versions, "amazon-cloudwatch-observability", null) == null
      resolve_conflicts_on_create = "OVERWRITE"
      # Credentials come from the cloudwatch_observability Pod Identity
      # association (pod-identity.tf), so the addon takes no
      # service_account_role_arn and declares no pod_identity_association of its
      # own — declaring one here as well would collide with that association on
      # the same (namespace, service account).
      configuration_values = jsonencode({
        agent = {
          config = {
            logs = {
              metrics_collected = {
                kubernetes = {
                  enhanced_container_insights = true
                }
              }
            }
          }
        }
        containerLogs = {
          enabled = false
        }
      })
    }
  }

  # System node group — runs critical platform addons
  eks_managed_node_groups = {
    system = {
      name           = "${var.environment}-system"
      instance_types = var.system_node_instance_types
      ami_type       = "BOTTLEROCKET_ARM_64"
      min_size       = var.system_node_min_size
      max_size       = var.system_node_max_size
      desired_size   = var.system_node_desired_size
      capacity_type  = "ON_DEMAND"

      # Do NOT reach for `disk_size` here — it is silently ignored.
      #
      # terraform-aws-eks v21 always builds a custom launch template for a managed node
      # group, and `disk_size` has no effect whenever one is used. It is accepted, it
      # validates, it plans clean, and AWS never sees it: the node group reports
      # `diskSize: null`, the launch template's BlockDeviceMappings stays null, and the
      # instances fall back to the AMI's own defaults.
      #
      # For BOTTLEROCKET that default is a 2 GiB OS volume (/dev/xvda) plus a **20 GiB
      # data volume** (/dev/xvdb) — and /dev/xvdb is where container images and
      # ephemeral storage live. 20 GiB does not fit this platform's image set: system
      # nodes hit DiskPressure while the addons are still pulling, the kubelet evicts
      # pods (the ArgoCD ApplicationSet controller among them), and convergence runs
      # backwards instead of forwards. Karpenter's nodes are unaffected, because its
      # EC2NodeClass sizes its volumes explicitly — only a managed group left on the
      # defaults is exposed.
      #
      # The knob that actually reaches AWS is block_device_mappings. Size /dev/xvdb;
      # /dev/xvda is deliberately left alone, since the Bottlerocket OS image is
      # read-only and 2 GiB is what it is designed for.
      block_device_mappings = {
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = var.system_node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # node-group role under the fleet-vend path (v21 sets these per-group, not
      # via an eks_managed_node_group_defaults var)
      iam_role_path                 = var.cluster_iam_role_path
      iam_role_permissions_boundary = local.cluster_permissions_boundary

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = {
        "node-role" = "system"
      }
    }
  }

  access_entries = var.access_entries

  # Allow Karpenter node role to join the cluster
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  # Cilium's own ports. The default node security group does not open them, and nothing
  # in the module knows Cilium is the CNI — so without these the datapath is silently
  # half-broken and the cluster still reports itself healthy.
  #
  # What that looked like: every pod on a Karpenter node had NO DNS. CoreDNS runs on the
  # managed node group, and:
  #
  #     cilium-dbg status  →  Cluster health: 4/6 reachable
  #                           Encryption: Wireguard [Peers: 5]
  #
  # The WireGuard peers were all established — the tunnels simply could not carry
  # traffic, because UDP 51871 was not permitted between nodes. A pod resolving anything
  # got `i/o timeout`, falco's init container could not fetch its rules, and the
  # Applications stayed Healthy the whole time, because a readiness probe is local and
  # never leaves the node.
  #
  # The default rules open TCP 1025-65535 and UDP 53 from self, which is enough for a
  # VXLAN-less, unencrypted CNI. Cilium needs three more things, and each is silent when
  # missing rather than loud:
  #
  #   51871/udp  WireGuard transport. Without it, encrypted pod-to-pod traffic between
  #              nodes is dropped — the tunnel exists, the packets vanish.
  #   4240/tcp   The cilium-health endpoint every agent probes to build `Cluster health`.
  #              Without it the agents cannot tell a partitioned node from a busy one.
  #   icmp       cilium-health's latency/reachability probe.
  #
  # These are `self = true`: all nodes must live in THIS security group for the rules to
  # cover them, which is what the karpenter.sh/discovery tag above is for. The Karpenter
  # EC2NodeClass must select this SG by that tag (eks-gitops,
  # addons/operations/karpenter-resources) — selecting the EKS *cluster* SG instead puts
  # Karpenter nodes in a different group with no path to the node group at all, and that
  # is exactly the bug this comment exists because of.
  node_security_group_additional_rules = {
    cilium_wireguard = {
      description = "Cilium WireGuard: encrypted pod-to-pod transport between nodes"
      protocol    = "udp"
      from_port   = 51871
      to_port     = 51871
      type        = "ingress"
      self        = true
    }
    cilium_health = {
      description = "Cilium health endpoint: how agents compute cluster reachability"
      protocol    = "tcp"
      from_port   = 4240
      to_port     = 4240
      type        = "ingress"
      self        = true
    }
    cilium_health_icmp = {
      description = "Cilium health: ICMP reachability probe"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      type        = "ingress"
      self        = true
    }
  }

  tags = local.tags
}
