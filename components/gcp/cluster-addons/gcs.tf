################################################################################
# Addon GCS Buckets
################################################################################

# Loki log storage
resource "google_storage_bucket" "loki" {
  name          = "${local.bucket_prefix}-loki"
  project       = var.project_id
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 90
    }
  }

  labels = {
    team      = var.team
    component = "cluster-addons"
    addon     = "loki"
  }
}

resource "google_storage_bucket_iam_member" "loki" {
  bucket = google_storage_bucket.loki.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${module.loki_wi.service_account_email}"
}

# Tempo trace storage
resource "google_storage_bucket" "tempo" {
  name          = "${local.bucket_prefix}-tempo"
  project       = var.project_id
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }

  labels = {
    team      = var.team
    component = "cluster-addons"
    addon     = "tempo"
  }
}

resource "google_storage_bucket_iam_member" "tempo" {
  bucket = google_storage_bucket.tempo.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${module.tempo_wi.service_account_email}"
}
