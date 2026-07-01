locals {
  labels = {
    component = "org-compliance"
    team      = var.team
  }
}

################################################################################
# Data Access Audit Logs — All Services
################################################################################

resource "google_organization_iam_audit_config" "all_services" {
  count = var.enable_audit_logs ? 1 : 0

  org_id  = var.org_id
  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

################################################################################
# Audit Log Storage Bucket
################################################################################

resource "google_storage_bucket" "audit_logs" {
  count = var.enable_audit_logs ? 1 : 0

  name                        = "${var.project_id}-org-audit-logs"
  project                     = var.project_id
  location                    = var.log_bucket_location
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = 90
    }
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition {
      age = 365
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.log_retention_days
    }
  }

  labels = local.labels
}

################################################################################
# Organization Log Sink — Export Audit Logs to Bucket
################################################################################

resource "google_logging_organization_sink" "audit_logs" {
  count = var.enable_audit_logs ? 1 : 0

  name             = "org-audit-log-sink"
  org_id           = var.org_id
  destination      = "storage.googleapis.com/${google_storage_bucket.audit_logs[0].name}"
  include_children = true

  filter = "logName:\"logs/cloudaudit.googleapis.com\""
}

################################################################################
# Grant Sink Service Account Access to Bucket
################################################################################

resource "google_storage_bucket_iam_member" "sink_writer" {
  count = var.enable_audit_logs ? 1 : 0

  bucket = google_storage_bucket.audit_logs[0].name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.audit_logs[0].writer_identity
}
