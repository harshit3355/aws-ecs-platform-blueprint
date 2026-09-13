aws_region         = "ap-south-1"
project            = "meridian"
environment        = "staging"
vpc_cidr           = "10.20.0.0/16"
log_retention_days = 14

# Subscriptions must be confirmed from the inbox before they deliver anything.
alert_email_addresses = []

# slack_webhook_url is intentionally absent. It is a credential:
#   export TF_VAR_slack_webhook_url=...
