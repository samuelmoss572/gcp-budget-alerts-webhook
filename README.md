Copyright 2025 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.  


# GCP Budget Alerts to MS Teams (Terraform)

This project deploys a secure, serverless pipeline to send GCP Budget notifications to a Microsoft Teams channel (or other webhook!)

It uses a private 2nd Gen Cloud Function that is triggered by a Pub/Sub topic. The function formats the budget alert (handling both 'Actual' and 'Forecasted' spends) and sends it to an MS Teams webhook URL, which is stored securely in Secret Manager.

Default region this deploys to is Europe-West1 and should be changed in variables.tf

This solution is deployed using Terraform with the following details:

* **Private Function:** The Cloud Function is deployed as a private Cloud Run service (the 2nd Gen default).
* **Authenticated Trigger:** The Pub/Sub (Eventarc) trigger is authenticated using the project's **Default Compute Engine Service Account** (`...-compute@...`), which is granted the `run.invoker` role.
* **Build Agent:** The function build also uses the **Default Compute Engine Service Account**, which is granted `run.builder` and `storage.objectViewer` roles.

Note: The limitations here - particularly the Domain Restricted Sharing note: https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications#limitations

## Architecture

**GCP Budget** $\rightarrow$ **Pub/Sub Topic** $\rightarrow$ **Cloud Function (Gen 2, private)** $\rightarrow$ **Secret Manager** $\rightarrow$ **MS Teams**

## File Structure

* `main.tf`: Defines all GCP resources (Function, Pub/Sub, Secrets, IAM).
* `variables.tf`: Declares all input variables.
* `terraform.tfvars.example`: An example file to provide your secret values.
* `main.py`: The Python (2nd Gen) function code.
* `requirements.txt`: Python dependencies.

## Prerequisites

1.  **GCP Project:** A GCP project with Billing enabled.
3.  **MS Teams Webhook URL:** You must generate this from your MS Teams channel first.
4.  **Terraform:** Terraform CLI (v1.0.0+) installed.
5.  **gcloud:** Google Cloud SDK installed and authenticated (`gcloud auth login`).

## APIs Required (if not already enabled)

 "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",

## Deployment Steps

1.  **Clone/Download Files:** Place all 5 files from this guide into a new directory.

2.  **Create Your Configuration:** Copy the example `.tfvars` file.
    ```bash
    cp terraform.tfvars.example terraform.tfvars
    ```

3.  **Edit `terraform.tfvars`:** Open the `terraform.tfvars` file and fill in your `project_id` and the `teams_webhook_url` you generated.

4.  **Initialize Terraform:**
    ```bash
    terraform init
    ```

5.  **Apply Configuration:**
    ```bash
    terraform apply
    ```
    Review the plan and type `yes` to deploy. This will create all the resources, including the private function and all the necessary IAM permissions.

6.  **Connect Your Budget (Manual UI Step):**
    Terraform cannot programmatically connect the Billing service. You must do this one-time step in the GCP Console:
    * Go to **Billing** $\rightarrow$ **Budgets & alerts**.
    * Find the Budget you want to monitor and click **EDIT BUDGET**.
    * Scroll down to **Actions** $\rightarrow$ **Manage notifications**.
    * Check **Connect a Pub/Sub topic to this budget**.
    * Select the Pub/Sub topic created by Terraform (e.g., `gcp-budget-alerts-tf`).
    * Click **SAVE**.
    * **IMPORTANT:** A popup will likely appear asking to grant permission to the billing service account. You **must click GRANT**. This is what allows Billing to publish to your new topic.

## How to Test

After the deployment is complete, you can send a test message from your Cloud Shell to validate the entire pipeline:

```bash
# Get your topic name from the Terraform output (or variables.tf)
TOPIC_NAME=$(terraform output -raw topic_name)

# Publish a test message
gcloud pubsub topics publish $TOPIC_NAME \
    --message='{"costAmount": 95.50, "budgetAmount": 100.00, "budgetDisplayName": "Terraform-Test-Alert", "currencyCode": "USD", "alertThresholdExceeded": 0.9}'
