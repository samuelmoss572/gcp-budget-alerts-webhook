# Copyright 2025 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.  


terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- 1. ENABLE APIS & GET PROJECT DATA ---
data "google_project" "project" {}

# Enable all necessary APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# --- 2. CREATE PUB/SUB TOPIC ---
# We will grant Billing permissions manually via the UI (see README)
resource "google_pubsub_topic" "budget_topic" {
  name = var.topic_name
}

# --- 3. CREATE SECRET FOR WEBHOOK ---
resource "google_secret_manager_secret" "webhook_secret" {
  secret_id = var.secret_id
  replication {
    auto {} # Correct syntax for automatic replication
  }
}

resource "google_secret_manager_secret_version" "webhook_secret_version" {
  secret      = google_secret_manager_secret.webhook_secret.id
  secret_data = var.teams_webhook_url
}

# --- 4. CREATE SERVICE ACCOUNT & SET FUNCTION PERMISSIONS ---
resource "google_service_account" "function_sa" {
  account_id   = var.service_account_name
  display_name = "Budget Alert Function SA (Terraform)"
}

# Grant the function's SA access to the secret
resource "google_secret_manager_secret_iam_member" "sa_access_secret" {
  project   = google_secret_manager_secret.webhook_secret.project
  secret_id = google_secret_manager_secret.webhook_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.function_sa.member
  # This explicit dependency ensures the SA exists before binding
  depends_on = [google_service_account.function_sa]
}

# --- 5. PACKAGE & UPLOAD FUNCTION CODE ---
# This zips main.py and requirements.txt for deployment
data "archive_file" "source_zip" {
  type        = "zip"
  output_path = "/tmp/function-source-budget.zip"

  source {
    content  = file("main.py")
    filename = "main.py"
  }

  source {
    content  = file("requirements.txt")
    filename = "requirements.txt"
  }
}

# This bucket holds the zipped source code
resource "google_storage_bucket" "source_bucket" {
  name          = "${var.project_id}-budget-func-src"
  location      = var.region
  force_destroy = true # Set to false for production
  # This fixes the Org Policy error
  uniform_bucket_level_access = true
}

# This uploads the zip file to the bucket
resource "google_storage_bucket_object" "source_object" {
  name   = "source.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.source_zip.output_path
  depends_on = [
    data.archive_file.source_zip
  ]
}

# --- 6. DEPLOY THE 2ND GEN (PRIVATE) CLOUD FUNCTION ---
resource "google_cloudfunctions2_function" "budget_function" {
  name     = var.function_name
  location = var.region
  
  depends_on = [
    google_project_service.apis
  ]

  build_config {
    runtime     = "python310"
    entry_point = "process_budget_alert" # This must match the def in main.py
    source {
      storage_source {
        bucket = google_storage_bucket.source_bucket.name
        object = google_storage_bucket_object.source_object.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256Mi"
    timeout_seconds    = 60
    
    # Pass environment variables to the function's runtime
    environment_variables = {
      GCP_PROJECT_ID = var.project_id
      SECRET_ID      = var.secret_id
    }
    
    # Set the function's identity to the SA we created
    service_account_email = google_service_account.function_sa.email
    
    # By NOT specifying 'ingress_settings', this defaults to a private
    # service, which requires authentication.
  }

  # Connects the function to the Pub/Sub topic
  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# --- 7. FIX 403 AUTH ERROR (THE FINAL PERMISSION) ---
# This grants the function's *own* service account permission to
# invoke itself. This is required for private 2nd Gen functions.
resource "google_cloud_run_service_iam_member" "self_invoke" {
  location = google_cloudfunctions2_function.budget_function.location
  service  = google_cloudfunctions2_function.budget_function.name
  role     = "roles/run.invoker"
  member   = google_service_account.function_sa.member
}

# --- 8. (OPTIONAL) OUTPUTS ---
output "function_name" {
  value = google_cloudfunctions2_function.budget_function.name
}

output "topic_name" {
  value = google_pubsub_topic.budget_topic.name
}
