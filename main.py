
# Copyright 2025 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.  


import base64
import json
import os
import requests
from google.cloud import secretmanager

# --- Initialize Clients in Global Scope (fetches on cold start) ---
try:
    secret_client = secretmanager.SecretManagerServiceClient()

    # Get Configuration from Environment Variables
    PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
    SECRET_ID = os.environ.get("SECRET_ID")

    if not PROJECT_ID or not SECRET_ID:
        raise ValueError("GCP_PROJECT_ID and SECRET_ID environment variables must be set.")

    SECRET_PATH = f"projects/{PROJECT_ID}/secrets/{SECRET_ID}/versions/latest"
    
    response = secret_client.access_secret_version(request={"name": SECRET_PATH})
    TEAMS_WEBHOOK_URL = response.payload.data.decode("UTF-8")

except Exception as e:
    print(f"FATAL: Failed to initialize secrets on cold start: {e}")
    TEAMS_WEBHOOK_URL = None


def process_budget_alert(cloudevent):
    """
    (2nd Gen) Triggered by a Pub/Sub message when a GCP Budget alert fires.
    Formats and sends an alert to an MS Teams channel webhook.
    """
    
    if not TEAMS_WEBHOOK_URL:
        print("ERROR: Teams Webhook URL is not configured. Halting function.")
        return

    try:
        # 1. Decode the 2nd Gen (CloudEvent) Pub/Sub Message
        # 'cloudevent.data' is BYTES containing a JSON string. Decode/parse it.
        event_data_dict = json.loads(cloudevent.data.decode('utf-8'))

        # Now, access the inner 'data' key which has the Base64 budget message
        pubsub_data = base64.b64decode(event_data_dict["message"]["data"]).decode('utf-8')
        
        # 'pubsub_data' is now the final JSON string with the budget info
        budget_message = json.loads(pubsub_data)

        # 2. Extract Key Billing Information
        cost = budget_message.get('costAmount', 0)
        budget = budget_message.get('budgetAmount', 0)
        currency = budget_message.get('currencyCode', 'USD')
        name = budget_message.get('budgetDisplayName', 'Unnamed Budget')

        # 3. Check for ACTUAL vs FORECASTED threshold triggers
        actual_percent_raw = budget_message.get("alertThresholdExceeded")
        forecast_percent_raw = budget_message.get("forecastThresholdExceeded")

        alert_sections = []

        # --- Build Section for ACTUAL Spend ---
        if actual_percent_raw:
            actual_percent = actual_percent_raw * 100
            actual_section = {
                "activityTitle": f"**🚨 Budget ALERT (Actual Spend): {name}**",
                "activitySubtitle": f"You have spent {actual_percent:,.0f}% of your budget.",
                "facts": [
                    {"name": "Budget Name:", "value": name},
                    {"name": "Current Cost:", "value": f"{cost:,.2f} {currency}"},
                    {"name": "Budget Amount:", "value": f"{budget:,.2f} {currency}"},
                    {"name": "Triggered Threshold:", "value": f"{actual_percent:,.0f}% (Actual Spend)"}
                ],
                "markdown": True
            }
            alert_sections.append(actual_section)

        # --- Build Section for FORECASTED Spend ---
        if forecast_percent_raw:
            forecast_percent = forecast_percent_raw * 100
            forecast_section = {
                "activityTitle": f"**⚠️ Budget WARNING (Forecasted Spend): {name}**",
                "activitySubtitle": f"You are *forecasted* to spend {forecast_percent:,.0f}% of your budget.",
                "facts": [
                    {"name": "Budget Name:", "value": name},
                    {"name": "Current Cost:", "value": f"{cost:,.2f} {currency}"},
                    {"name": "Budget Amount:", "value": f"{budget:,.2f} {currency}"},
                    {"name": "Triggered Threshold:", "value": f"{forecast_percent:,.0f}% (Forecasted Spend)"}
                ],
                "markdown": True
            }
            alert_sections.append(forecast_section)

        # 4. If any alerts were triggered, build and send the final MS Teams card
        if alert_sections:
            teams_payload = {
                "@type": "MessageCard",
                "@context": "http://schema.org/extensions",
                "themeColor": "FF0000",
                "summary": f"GCP Budget Alert for {name}",
                "sections": alert_sections
            }

            # 5. Send the POST request to Microsoft Teams
            print(f"Sending formatted alert to Teams for budget: {name}")
            response = requests.post(TEAMS_WEBHOOK_URL, json=teams_payload)
            response.raise_for_status() 
            print("Successfully sent alert to Teams.")

    except Exception as e:
        print(f"Error processing budget alert: {e}")
        raise e
