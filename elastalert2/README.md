# ElastAlert2 (Email Alerts for Terraform Failures)

This application runs ElastAlert2 in Kubernetes and sends email alerts for Terraform failures stored in Elasticsearch.

## What it does

- Queries `terraform-logs-*` for `event.dataset: terraform.run` and `event.outcome: failure`
- Sends alerts via Mailgun SMTP

## Required Secrets

Update the Secret in:
- `elastalert2/manifests/00-secrets.yaml`

Keys:
- `ES_PASSWORD` (Elasticsearch password)
- `SMTP_USERNAME` (Mailgun SMTP user)
- `SMTP_PASSWORD` (Mailgun SMTP password)
- `SMTP_FROM` (from address)
- `ALERT_EMAIL_TO` (recipient)

## Notes

- Namespace: `elastic-system`
- If your index is not `terraform-logs-*`, change it in `elastalert2/manifests/01-config.yaml`.
- ES host/port and Mailgun SMTP host/port are in `elastalert2/manifests/01-config.yaml`.
