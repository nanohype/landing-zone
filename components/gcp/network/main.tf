locals {
  cluster_name = "${var.environment}-${var.cluster_name}"
  name_prefix  = "${var.environment}-${var.team}"
}

################################################################################
# VPC Network
################################################################################

resource "google_compute_network" "this" {
  name                    = "${local.name_prefix}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

################################################################################
# Subnets
################################################################################

resource "google_compute_subnetwork" "private" {
  name                     = "${local.name_prefix}-private"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = "10.0.0.0/20"
  private_ip_google_access = var.enable_private_google_access

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

resource "google_compute_subnetwork" "public" {
  name    = "${local.name_prefix}-public"
  project = var.project_id
  region  = var.region
  network = google_compute_network.this.id
  # Private Google access costs nothing and lets anything in this subnet
  # without an external IP still reach Google APIs.
  ip_cidr_range            = "10.1.0.0/20"
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

################################################################################
# Cloud Router + Cloud NAT
################################################################################

resource "google_compute_router" "this" {
  name    = "${local.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.this.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "this" {
  name                               = "${local.name_prefix}-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.this.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

################################################################################
# Firewall Rules
################################################################################

resource "google_compute_firewall" "allow_internal" {
  name    = "${local.name_prefix}-allow-internal"
  project = var.project_id
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    google_compute_subnetwork.private.ip_cidr_range,
    google_compute_subnetwork.public.ip_cidr_range,
  ]

  priority = 1000
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "${local.name_prefix}-allow-health-checks"
  project = var.project_id
  network = google_compute_network.this.name

  allow {
    protocol = "tcp"
  }

  # Google Cloud health check probe ranges
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  target_tags = ["gke-node"]
  priority    = 1000
}

resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${local.name_prefix}-deny-all-ingress"
  project = var.project_id
  network = google_compute_network.this.name

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  priority      = 65534
}

################################################################################
# Default Route to Internet Gateway (for public subnet traffic)
################################################################################

resource "google_compute_route" "default_internet" {
  name             = "${local.name_prefix}-default-internet"
  project          = var.project_id
  network          = google_compute_network.this.name
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
  tags             = ["public"]
}
