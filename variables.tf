#Copyright 2025 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.  


variable "project_id" {
  type        = string
  description = "The GCP project ID to deploy these resources into."
}

variable "region" {
  type        = string
  description = "The GCP region for the Cloud Function (e.g., 'europe-west1')."
  default     = "europe-west1"
}

variable "teams_webhook_url" {
  type        = string
  description = "The MS Teams webhook URL for budget alerts."
  sensitive   = true
}

variable "topic_name" {
  type        = string
  description = "The name of the Pub/Sub topic for budget alerts."
  default     = "gcp-budget-alerts-tf"
}

variable "function_name" {
  type        = string
  description = "A unique name for your Cloud Function."
  default     = "budget-to-teams-tf"
}

variable "secret_id" {
  type        = string
  description = "The name for the Secret Manager secret for the webhook URL."
  default     = "ms-teams-webhook-url-tf"
}

variable "service_account_name" {
  type        = string
  description = "A short name for the function's service account."
  default     = "budget-func-sa-tf"
}
