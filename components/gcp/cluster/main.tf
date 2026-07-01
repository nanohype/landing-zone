locals {
  cluster_name = "${var.project_id}-gke"
}

################################################################################
# Cloud KMS — GKE Secrets Encryption
################################################################################

resource "google_kms_key_ring" "gke" {
  name     = "${local.cluster_name}-keyring"
  project  = var.project_id
  location = var.region
}

resource "google_kms_crypto_key" "gke" {
  name            = "${local.cluster_name}-secrets"
  key_ring        = google_kms_key_ring.gke.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

################################################################################
# GKE Cluster
################################################################################

resource "google_container_cluster" "this" {
  name     = local.cluster_name
  project  = var.project_id
  location = var.region

  network    = var.network_id
  subnetwork = var.private_subnet_ids[0]

  # Remove default node pool — we manage our own
  remove_default_node_pool = true
  initial_node_count       = 1

  # Networking
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = !var.cluster_endpoint_public_access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Legacy client-certificate auth stays off (IAM + OAuth only) — explicit so
  # the posture is declared, not inherited from a provider default.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Secrets encryption with Cloud KMS
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke.id
  }

  # Logging and monitoring
  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
    ]
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  # GKE Dataplane V2 (eBPF-based, provides network policy natively)
  datapath_provider = "ADVANCED_DATAPATH"

  # Binary Authorization
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Release channel — REGULAR is "latest stable": new K8s minors land here
  # ~3 months after RAPID once GCP has burn-tested them. RAPID = newest features
  # with more churn. STABLE = ~6 months behind RAPID, GCP's "LTS equivalent"
  # for slower-moving fleets.
  release_channel {
    channel = "REGULAR"
  }

  # Maintenance window — weekdays 02:00-06:00 UTC
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
    }
  }

  # Master authorized networks (when private endpoint)
  dynamic "master_authorized_networks_config" {
    for_each = var.cluster_endpoint_public_access ? [] : [1]
    content {
      gcp_public_cidrs_access_enabled = false
    }
  }

  resource_labels = {
    team      = var.team
    component = "cluster"
  }
}

################################################################################
# System Node Pool
################################################################################

resource "google_container_node_pool" "system" {
  name     = "system"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.this.name

  autoscaling {
    min_node_count = var.system_node_min_size
    max_node_count = var.system_node_max_size
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = var.system_node_disk_size
    disk_type    = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      "node-role" = "system"
    }

    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    tags = ["gke-node", "system"]
  }
}
