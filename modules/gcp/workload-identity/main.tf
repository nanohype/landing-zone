# google_service_account has no labels argument — GCP service accounts can't
# carry labels (unlike AWS IAM roles, which take var.tags). So the
# org-dimension tags don't attach here; the SA is audited via its IAM
# bindings below. See the resource-tagging standard.
resource "google_service_account" "this" {
  account_id   = var.role_name
  display_name = var.role_name
  project      = var.project_id
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.service_account}]"
}

resource "google_project_iam_member" "roles" {
  for_each = toset(var.roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.this.email}"
}
