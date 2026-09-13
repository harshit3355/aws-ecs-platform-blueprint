aws_region  = "ap-south-1"
project     = "meridian"
environment = "prod"
# Non-overlapping with staging (10.20.0.0/16) so the two VPCs can be peered.
vpc_cidr           = "10.30.0.0/16"
log_retention_days = 90
db_instance_class  = "db.t4g.small"

# Populate before the first production apply -- an alarm with no subscriber is
# a dashboard nobody is looking at.
alert_email_addresses = []

# certificate_arn = "arn:aws:acm:ap-south-1:<account>:certificate/<id>"
# Supplying this turns port 80 into a 301 to 443.

# slack_webhook_url is a credential: export TF_VAR_slack_webhook_url
