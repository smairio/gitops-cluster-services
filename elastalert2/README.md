# ElastAlert2 - Terraform Failure Alerting System

Real-time email alerts for Terraform infrastructure failures, powered by ElastAlert2 and integrated with the ELK stack.

## Features

- **Real-time Monitoring**: Queries Elasticsearch every minute for failed Terraform runs
- **Beautiful HTML Emails**: Professional, styled email templates with full error context
- **Error Classification**: Categorizes errors (authentication, timeout, quota, etc.)
- **Critical Alerts**: Separate high-priority alerts for authentication and state conflicts
- **Vault Integration**: Elasticsearch password pulled from HashiCorp Vault via ExternalSecrets
- **Resource Tracking**: Shows exactly which resources failed and why

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Filebeat      │────▶│  Elasticsearch  │◀────│  ElastAlert2    │
│ (terraform-logs)│     │  (terraform-*)  │     │  (this app)     │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │   SMTP Server   │
                                                │ (Mailhog/Mailgun)│
                                                └────────┬────────┘
                                                         │
                                                         ▼
                                                    📧 Email
```

## Alert Types

### 1. Standard Failure Alerts
Triggered for any terraform run with `event.outcome: failure`

**Subject**: `🚨 Terraform Failed | production | timeout`

**Includes**:
- Environment, operation, workspace
- Error type and message
- Failed resources list
- Planned changes (add/change/destroy)
- Trace ID for correlation
- Direct link to Kibana

### 2. Critical Alerts
Triggered for high-severity error types that require immediate attention:
- `authentication` - Credential issues
- `state_conflict` - State lock problems
- `quota_exceeded` - Resource limits

**Subject**: `🔴 CRITICAL: Terraform authentication Error | production`

## Deployment

### Prerequisites
- ECK Operator running with Elasticsearch cluster `elk`
- External Secrets Operator with Vault ClusterSecretStore
- Vault secret at `secret/khalil/argocd/elk` with `password` key

### Enable the Application

```bash
# Rename to enable in ArgoCD
mv app.yaml.disabled app.yaml
git add -A && git commit -m "feat: enable elastalert2" && git push
```

### Vault Secret Setup

Ensure the Elasticsearch password is in Vault:
```bash
vault kv put secret/khalil/argocd/elk password="YOUR_ES_PASSWORD"
```

## Configuration

### Files Structure

```
elastalert2/
├── app.yaml.disabled        # ArgoCD Application (rename to enable)
├── README.md                # This file
└── manifests/
    ├── 00-secrets.yaml      # ExternalSecret for ES password, SMTP config
    ├── 01-config.yaml       # ElastAlert2 config and rule templates
    ├── 02-deployment.yaml   # Kubernetes Deployment
    └── 03-mailhog.yaml      # Development SMTP server
```

### Customization

#### Change Alert Recipients
Edit `manifests/00-secrets.yaml`:
```yaml
stringData:
  ALERT_EMAIL_TO: "your-email@example.com"
```

#### Change Index Pattern
Edit `manifests/01-config.yaml`:
```yaml
data:
  INDEX_PATTERN: "your-index-pattern-*"
```

#### Production SMTP (Mailgun)
Edit `manifests/00-secrets.yaml`:
```yaml
stringData:
  SMTP_HOST: "smtp.mailgun.org"
  SMTP_PORT: "587"
  SMTP_TLS: "true"
  SMTP_USERNAME: "postmaster@your-domain.com"
  SMTP_PASSWORD: "your-mailgun-api-key"
```

## Alert Email Preview

### Standard Failure Alert
```
┌────────────────────────────────────────────────┐
│ ⚠️ Terraform Run Failed                        │
│ Infrastructure deployment requires attention   │
├────────────────────────────────────────────────┤
│ RUN DETAILS                                    │
│ Environment: production                        │
│ Operation: apply                               │
│ Error Type: timeout                            │
│ Exit Code: 1                                   │
│ Duration: 45 seconds                           │
├────────────────────────────────────────────────┤
│ ERROR MESSAGE                                  │
│ ┌──────────────────────────────────────────┐  │
│ │ Error: timeout waiting for resource...   │  │
│ └──────────────────────────────────────────┘  │
├────────────────────────────────────────────────┤
│ FAILED RESOURCES                               │
│ • module.vpc.aws_subnet.private[0]            │
│ • module.ec2.aws_instance.web                 │
└────────────────────────────────────────────────┘
```

## Troubleshooting

### Check ElastAlert2 Logs
```bash
kubectl logs -n elastic-system deployment/elastalert2 -f
```

### Verify Config Rendering
```bash
kubectl exec -n elastic-system deployment/elastalert2 -c elastalert2 -- cat /config/config.yaml
kubectl exec -n elastic-system deployment/elastalert2 -c elastalert2 -- cat /config/rules/terraform-failures.yaml
```

### Test Elasticsearch Connection
```bash
kubectl exec -n elastic-system deployment/elastalert2 -c elastalert2 -- \
  elastalert-test-rule /config/rules/terraform-failures.yaml --config /config/config.yaml
```

### Check ExternalSecret Status
```bash
kubectl get externalsecret elastalert2-es-password -n elastic-system
kubectl get secret elastalert2-es-password -n elastic-system -o yaml
```

## Development

### Local Testing with Mailhog
Mailhog is deployed by default for development. Access the UI:
```bash
kubectl port-forward -n elastic-system svc/mailhog 8025:8025
# Open http://localhost:8025
```

### Trigger a Test Alert
Create a test failure log:
```bash
./terraform_run_script.sh apply live/dev  # (with intentional failure)
```

## Metrics

ElastAlert2 writes status to the `elastalert_status` index. Query it for:
- Alert history
- Rule execution stats
- Silenced alerts

```bash
curl -k -u elastic:$ES_PASS "https://elasticsearch.dev.tests.software/elastalert_status/_search?pretty"
```

## Related Documentation

- [ElastAlert2 Documentation](https://elastalert2.readthedocs.io/)
- [Terraform Logging Exporter](../../terraform-logging-exporter/README.md)
- [ELK Stack Setup](../elk-stack/README.md)
