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
# Note: The Billing Agent permission must be granted manually via the UI.
resource "google_pubsub_topic" "budget_topic" {
  name = var.topic_name
}

# --- 3. CREATE SECRET FOR WEBHOOK ---
resource "google_secret_manager_secret" "webhook_secret" {
  secret_id = var.secret_id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_secret_version" {
  secret      = google_secret_manager_secret.webhook_secret.id
  secret_data = var.teams_webhook_url
}

# --- 4. CREATE FUNCTION'S *RUNTIME* SERVICE ACCOUNT ---
# This is the identity the function's Python code will run as.
resource "google_service_account" "function_sa" {
  account_id   = var.service_account_name
  display_name = "Budget Alert Function SA (Terraform)"
}

# Grant the function's runtime SA permission to read the secret
resource "google_secret_manager_secret_iam_member" "sa_access_secret" {
  project   = google_secret_manager_secret.webhook_secret.project
  secret_id = google_secret_manager_secret.webhook_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.function_sa.member
  depends_on = [
    google_service_account.function_sa
  ]
}

# --- 5. PACKAGE & UPLOAD FUNCTION CODE ---
# Zips the main.py and requirements.txt files for deployment
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

# A temporary bucket to hold the zipped source code
resource "google_storage_bucket" "source_bucket" {
  name                          = "${var.project_id}-budget-func-src"
  location                      = var.region
  uniform_bucket_level_access = true
  force_destroy                 = true # Set to false for production
}

# Uploads the zip file to the bucket
resource "google_storage_bucket_object" "source_object" {
  name   = "source.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.source_zip.output_path
  depends_on = [
    data.archive_file.source_zip
  ]
}

# --- 6. DEFINE THE BUILD & TRIGGER SERVICE ACCOUNT ---
locals {
  # This is the default service account used for building and triggering
  # functions in many projects.
  compute_sa_email = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# --- 7. GRANT PERMISSIONS TO THE BUILD & TRIGGER ACCOUNT ---

# Grant the Compute SA the "Run Builder" role (for building the function)
resource "google_project_iam_member" "build_agent_run_builder" {
  project = var.project_id
  role    = "roles/run.builder"
  member  = local.compute_sa_email
}

# Grant the Compute SA permission to read the source code from the bucket
resource "google_storage_bucket_iam_member" "functions_builder_access" {
  bucket = google_storage_bucket.source_bucket.name
  role   = "roles/storage.objectViewer"
  member = local.compute_sa_email
}

# Grant the Compute SA permission to invoke the (private) function
resource "google_cloud_run_service_iam_member" "trigger_invoker" {
  location = google_cloudfunctions2_function.budget_function.location
  service  = google_cloudfunctions2_function.budget_function.name
  role     = "roles/run.invoker"
  member   = local.compute_sa_email
}


# --- 8. DEPLOY THE 2ND GEN (PRIVATE) CLOUD FUNCTION ---
resource "google_cloudfunctions2_function" "budget_function" {
  name     = var.function_name
  location = var.region
  
  # Explicitly wait for the build permissions to be set before building
  depends_on = [
    google_project_iam_member.build_agent_run_builder,
    google_storage_bucket_iam_member.functions_builder_access
  ]

  build_config {
    runtime     = "python310"
    entry_point = "process_budget_alert" # Must match the def in main.py
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
    
    # Environment variables passed to the Python code
    environment_variables = {
      GCP_PROJECT_ID = var.project_id
      SECRET_ID      = var.secret_id
    }
    
    # This is the *runtime* identity (what the Python code runs as)
    service_account_email = google_service_account.function_sa.email
    
    # Defaults to a private service, requiring the 'run.invoker' permission
  }

  # Connects the function to the Pub/Sub topic
  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# --- 9. OUTPUTS ---
output "function_name" {
  value = google_cloudfunctions2_function.budget_function.name
}
output "topic_name" {
  value = google_pubsub_topic.budget_topic.name
}
