# AWX + HashiCorp Vault Integration - Complete Setup Guide

## Overview

This guide sets up AWX to retrieve secrets from HashiCorp Vault at **runtime** using Kubernetes authentication. This approach is more secure than storing static credentials because:

- Secrets are never stored in AWX database
- Vault audit log tracks all access
- Credentials are fetched only when jobs run
- ServiceAccount-based auth - no passwords to manage

## Current Status ✅

The following has been configured and verified working:

| Component | Status | Details |
|-----------|--------|---------|
| Kubernetes Auth | ✅ Enabled | `auth/kubernetes/` |
| AWX Policy | ✅ Created | `awx-secrets` |
| AWX Role | ✅ Created | `awx-secrets-reader` |
| Test Secret | ✅ Created | `secret/khalil/awx/test` → `TEST_VAR=Hello` |
| AWX Pod Auth | ✅ Verified | Can authenticate and read secrets |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AWX Pod (awx namespace)                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  AWX Task Pod (runs playbooks)                                       │    │
│  │  ServiceAccount: awx                                                 │    │
│  │  - Mounts SA Token automatically at:                                 │    │
│  │    /var/run/secrets/kubernetes.io/serviceaccount/token               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                 K8s ServiceAccount   │
                 JWT Token            │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              HashiCorp Vault Server (10.70.0.50:8200)                       │
│              Running on Hetzner VM (Private Network)                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Kubernetes Auth Method                                               │   │
│  │  POST /v1/auth/kubernetes/login                                       │   │
│  │  Role: awx-secrets-reader                                             │   │
│  │    - bound_service_account_names: awx                                 │   │
│  │    - bound_service_account_namespaces: awx                            │   │
│  │    - policies: awx-secrets                                            │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                      │                                       │
│                   Vault Token        │                                       │
│                   (temporary)        ▼                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  KV Secrets Engine v2 (secret/)                                       │   │
│  │  GET /v1/secret/data/khalil/awx/*                                     │   │
│  │                                                                       │   │
│  │  secret/khalil/awx/                                                   │   │
│  │    ├── test                      (TEST_VAR=Hello)                     │   │
│  │    ├── ssh/production            (username, ssh_key_data)             │   │
│  │    └── cloud/hetzner             (token)                              │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Technologies Used

| Technology | Purpose |
|------------|---------|
| **HashiCorp Vault** | Centralized secrets management |
| **Kubernetes Auth** | Authenticate using K8s ServiceAccount tokens |
| **KV Secrets Engine v2** | Store versioned key-value secrets |
| **AWX Credential Lookup** | Native integration to fetch secrets at runtime |
| **ServiceAccount Token** | Auto-mounted JWT for authentication |

## Prerequisites

- Kubernetes cluster running with AWX deployed
- HashiCorp Vault server running at `10.70.0.50:8200`
- SSH access through bastion host (`138.201.246.74`)
- `vault` CLI installed locally
- `kubectl` configured for your cluster

---

## Part 1: Vault Server Configuration (Already Configured)

> **Note:** Steps 1-4 are already configured. These are documented for reference.

### Step 1.1: Establish SSH Tunnel to Vault

Vault runs on a private IP. Access it via SSH port forwarding:

```bash
# Check if tunnel already exists
pgrep -f "L 8200:10.70.0.50:8200" && echo "Tunnel already running" || \
ssh -f -N -L 8200:10.70.0.50:8200 \
  -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=60 \
  -i ~/.ssh/id_ed25519 \
  root@138.201.246.74
```

### Step 1.2: Configure Vault Environment

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
#export VAULT_TOKEN

### Step 1.3: Verify Vault Connection

```bash
vault status
```

**Expected output:**
```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    5
Threshold       3
Version         1.15.x
...
```

---

## Part 2: Create AWX Secrets Policy

### Step 2.1: Create the Policy

The policy defines what paths AWX can read:

```bash
vault policy write awx-secrets - <<'EOF'
# =============================================================================
# Policy: awx-secrets
# Purpose: Allow AWX to read secrets for playbook execution
# =============================================================================

# Read AWX-specific secrets (all paths under khalil/awx/)
path "secret/data/khalil/awx/*" {
  capabilities = ["read", "list"]
}

# List AWX secrets path (required for UI listing)
path "secret/metadata/khalil/awx/*" {
  capabilities = ["read", "list"]
}

# Optional: Read infrastructure SSH keys
path "secret/data/khalil/kubernetes-bootsrap/ssh" {
  capabilities = ["read"]
}

# Optional: Read cloud provider credentials
path "secret/data/khalil/cloud/*" {
  capabilities = ["read"]
}
EOF
```

### Step 2.2: Verify Policy Created

```bash
vault policy read awx-secrets
```

---

## Part 3: Configure Kubernetes Authentication

### Step 3.1: Enable Kubernetes Auth (if not enabled)

```bash
vault auth list | grep -q kubernetes || vault auth enable kubernetes
```

### Step 3.2: Get Kubernetes Cluster Info

Vault needs to know how to validate K8s ServiceAccount tokens:

```bash
# Get the K8s CA certificate
kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > /tmp/k8s-ca.crt

# Get the K8s API server URL
K8S_HOST=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.server}')

echo "K8s API Server: $K8S_HOST"
```

### Step 3.3: Configure Vault Kubernetes Auth

```bash
vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  disable_local_ca_jwt=true

# Clean up
rm /tmp/k8s-ca.crt
```

### Step 3.4: Create Role for AWX ServiceAccount

```bash
vault write auth/kubernetes/role/awx-secrets-reader \
  bound_service_account_names=awx \
  bound_service_account_namespaces=awx \
  policies=awx-secrets \
  ttl=1h
```

### Step 3.5: Verify Role Created

```bash
vault read auth/kubernetes/role/awx-secrets-reader
```

**Expected output:**
```
Key                                         Value
---                                         -----
bound_service_account_names                 [awx]
bound_service_account_namespaces            [awx]
policies                                    [awx-secrets]
ttl                                         1h
...
```

---

## Part 4: Create Test Secret

### Step 4.1: Create TEST_VAR Secret

```bash
vault kv put secret/khalil/awx/test \
  TEST_VAR="Hello"
```

### Step 4.2: Verify Secret Created

```bash
vault kv get secret/khalil/awx/test
```

**Expected output:**
```
====== Data ======
Key         Value
---         -----
TEST_VAR    Hello
```

### Step 4.3: List All AWX Secrets

```bash
vault kv list secret/khalil/awx/
```

---

## Part 5: Test Vault Authentication from AWX Pod

### Step 5.1: Get into AWX Task Pod

```bash
kubectl exec -it -n awx deployment/awx-task -- /bin/bash
```

### Step 5.2: Test Vault Connectivity

From inside the AWX pod:

```bash
# Test network connectivity to Vault (using private IP)
curl -s http://10.70.0.50:8200/v1/sys/health
```

**Expected output:**
```json
{"initialized":true,"sealed":false,"standby":false,...}
```

### Step 5.3: Test Kubernetes Auth Login

```bash
# Read ServiceAccount token
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Login to Vault using K8s auth
curl -s -X POST \
  http://10.70.0.50:8200/v1/auth/kubernetes/login \
  -d "{\"role\": \"awx-secrets-reader\", \"jwt\": \"$SA_TOKEN\"}" | jq .
```

**Expected output (success):**
```json
{
  "auth": {
    "client_token": "hvs.CAESIxxxxxxxx...",
    "policies": ["awx-secrets", "default"],
    "token_policies": ["awx-secrets", "default"],
    "metadata": {
      "role": "awx-secrets-reader",
      "service_account_name": "awx",
      "service_account_namespace": "awx"
    },
    ...
  }
}
```

### Step 5.4: Test Secret Read

Use the token from previous step to read the secret:

```bash
# Get a token
VAULT_TOKEN=$(curl -s -X POST \
  http://10.70.0.50:8200/v1/auth/kubernetes/login \
  -d "{\"role\": \"awx-secrets-reader\", \"jwt\": \"$SA_TOKEN\"}" | jq -r '.auth.client_token')

# Read the test secret
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://10.70.0.50:8200/v1/secret/data/khalil/awx/test | jq .
```

**Expected output:**
```json
{
  "data": {
    "data": {
      "TEST_VAR": "Hello"
    },
    "metadata": {
      "version": 1
    }
  }
}
```

---

## Part 6: Configure AWX UI

### Step 6.1: Create HashiCorp Vault Credential

1. Navigate to **Resources → Credentials → Add**
2. Fill in the form:

| Field | Value | Notes |
|-------|-------|-------|
| **Name** | `Vault Kubernetes Auth` | Any descriptive name |
| **Credential Type** | `HashiCorp Vault Secret Lookup` | Select from dropdown |
| **Server URL** | `http://10.70.0.50:8200` | Vault private IP |
| **Token** | *(leave empty)* | Not needed for K8s auth |
| **CA Certificate** | *(leave empty)* | Not using TLS |
| **AppRole role_id** | *(leave empty)* | Not using AppRole |
| **AppRole secret_id** | *(leave empty)* | Not using AppRole |
| **Kubernetes role** | `awx-secrets-reader` | **IMPORTANT: The Vault role name** |
| **Path to Auth** | `kubernetes` | K8s auth mount path |
| **API Version** | `v2` | **⚠️ CRITICAL: Must be v2, NOT v1** |

> **⚠️ Common Error: 403 Permission Denied**
> 
> If you get a 403 error when testing, check the **API Version** field:
> - KV v1 engine uses path: `/v1/secret/path/to/secret`
> - KV v2 engine uses path: `/v1/secret/data/path/to/secret`
> 
> Our Vault uses **KV v2**, so API Version must be **v2**.
>
> **Wrong API version = 403 error!**

> **Critical Settings:**
> - **Kubernetes role** = `awx-secrets-reader` (the role we created in Vault)
> - **API Version** = `v2` (because we use KV secrets engine version 2)
> - Leave Token, AppRole fields **empty** - AWX uses ServiceAccount token automatically

3. Click **Save**

### Step 6.2: Create Custom Credential Type (Optional)

To use custom fields, create a credential type:

1. Navigate to **Administration → Credential Types → Add**
2. Fill in:

| Field | Value |
|-------|-------|
| **Name** | `Custom Vault Fields` |
| **Input Configuration** | (see below) |
| **Injector Configuration** | (see below) |

**Input Configuration:**
```yaml
fields:
  - id: test_var
    type: string
    label: TEST_VAR
required:
  - test_var
```

**Injector Configuration:**
```yaml
extra_vars:
  test_var: '{{ test_var }}'
```

### Step 6.3: Create Credential Using Vault Lookup

When creating any credential that needs a value from Vault, click the 🔑 (key) icon next to a field. This opens the **External Secret Management System** dialog.

**External Secret Management System Fields:**

| Field | Value | Notes |
|-------|-------|-------|
| **Credential** | `Vault Kubernetes Auth` | Select the lookup credential created in Step 6.1 |
| **Name of Secret Backend** | `secret` | **⚠️ IMPORTANT: Must be `secret` (the mount path)** |
| **Path to Secret** | `khalil/awx/test` | Path without `secret/data/` prefix |
| **Path to Auth** | *(leave empty)* | Uses default from credential |
| **Key Name** | `TEST_VAR` | The key within the secret |
| **Secret Version (v2 only)** | *(leave empty)* | Uses latest version |

> **⚠️ Common Error: 403 on Lookup**
>
> If you get 403 when using External Secret lookup:
> 1. **Name of Secret Backend** must be `secret` (not empty!)
> 2. **API Version** in main credential must be `v2`
> 3. **Path to Secret** should NOT include `secret/data/` prefix
>
> AWX constructs: `{server}/v1/{backend}/data/{path}` for KV v2
> - Correct: `http://10.70.0.50:8200/v1/secret/data/khalil/awx/test`

**Example: Creating a Machine Credential with Vault Lookup**

1. Navigate to **Resources → Credentials → Add**
2. Select **Credential Type**: `Machine`
3. For the **Username** field, click the 🔑 icon
4. Fill in the External Secret Management System dialog:
   - **Credential**: Select `Vault Kubernetes Auth`
   - **Path to Secret**: `khalil/awx/ssh/production`
   - **Key Name**: `username`
   - **Secret Version**: `v2`
5. Click **OK**
6. Repeat for other fields (SSH Private Key, Password, etc.)

---

## Part 7: Create Test Job Template

### Step 7.1: Create Test Playbook

Create a simple playbook to test the Vault integration.

**File: `test-vault.yml`**
```yaml
---
- name: Test Vault Integration
  hosts: localhost
  gather_facts: false
  connection: local
  
  tasks:
    - name: Display TEST_VAR from Vault
      ansible.builtin.debug:
        msg: "TEST_VAR value is: {{ test_var }}"
      
    - name: Verify TEST_VAR value
      ansible.builtin.assert:
        that:
          - test_var is defined
          - test_var == "Hello"
        fail_msg: "TEST_VAR is not 'Hello'"
        success_msg: "✅ Vault integration working! TEST_VAR = {{ test_var }}"
```

### Step 7.2: Create Project in AWX

1. Navigate to **Resources → Projects → Add**

| Field | Value |
|-------|-------|
| **Name** | `Vault Test Project` |
| **Organization** | Default |
| **Source Control Type** | Git |
| **Source Control URL** | Your repo with test-vault.yml |

> Or use **Manual** project type if playbook is stored locally on AWX.

### Step 7.3: Create Job Template

1. Navigate to **Resources → Templates → Add → Job Template**

| Field | Value |
|-------|-------|
| **Name** | `Test Vault Integration` |
| **Job Type** | Run |
| **Inventory** | Demo Inventory (or any) |
| **Project** | Vault Test Project |
| **Playbook** | test-vault.yml |
| **Credentials** | `Test Vault Credential` |

2. Click **Save**

### Step 7.4: Run the Job

1. Click the 🚀 (Launch) button on the job template
2. Monitor the job output

**Expected Success Output:**
```
TASK [Display TEST_VAR from Vault] ********************************************
ok: [localhost] => {
    "msg": "TEST_VAR value is: Hello"
}

TASK [Verify TEST_VAR value] **************************************************
ok: [localhost] => {
    "changed": false,
    "msg": "✅ Vault integration working! TEST_VAR = Hello"
}

PLAY RECAP ********************************************************************
localhost                  : ok=2    changed=0    unreachable=0    failed=0    skipped=0
```

---

## Part 8: Complete Test Commands Summary

Run these commands in order to set up and test:

```bash
# 1. SSH tunnel to Vault
ssh -f -N -L 8200:10.70.0.50:8200 \
  -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=60 \
  -i ~/.ssh/id_ed25519 \
  root@138.201.246.74

# 2. Set environment
export VAULT_ADDR='http://127.0.0.1:8200'
# export VAULT_TOKEN

# 3. Verify connection
vault status

# 4. Create policy
vault policy write awx-secrets - <<'EOF'
path "secret/data/khalil/awx/*" { capabilities = ["read", "list"] }
path "secret/metadata/khalil/awx/*" { capabilities = ["read", "list"] }
EOF

# 5. Get K8s config
kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > /tmp/k8s-ca.crt
K8S_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')

# 6. Configure K8s auth
vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  disable_local_ca_jwt=true

# 7. Create role
vault write auth/kubernetes/role/awx-secrets-reader \
  bound_service_account_names=awx \
  bound_service_account_namespaces=awx \
  policies=awx-secrets \
  ttl=1h

# 8. Create test secret
vault kv put secret/khalil/awx/test TEST_VAR="Hello"

# 9. Verify secret
vault kv get secret/khalil/awx/test

# 10. Test from AWX pod
kubectl exec -it -n awx deployment/awx-task -- /bin/bash -c '
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
VAULT_TOKEN=$(curl -s -X POST http://10.70.0.50:8200/v1/auth/kubernetes/login \
  -d "{\"role\": \"awx-secrets-reader\", \"jwt\": \"$SA_TOKEN\"}" | jq -r ".auth.client_token")
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://10.70.0.50:8200/v1/secret/data/khalil/awx/test | jq .data.data
'
```

---

## Troubleshooting

### Error: 403 Permission Denied (Most Common!)

**Cause:** API Version is set to `v1` instead of `v2`

**Fix:** Edit the Vault credential in AWX and change **API Version** to `v2`

**Technical Explanation:**
- KV v1 engine: AWX calls `/v1/secret/khalil/awx/test`
- KV v2 engine: AWX calls `/v1/secret/data/khalil/awx/test`
- Our policy only allows `secret/data/*` paths (v2 format)

**Verify in terminal:**
```bash
# This fails (v1 path):
curl -s -H "X-Vault-Token: $TOKEN" http://10.70.0.50:8200/v1/secret/khalil/awx/test
# Returns: {"errors":["permission denied"]}

# This works (v2 path):
curl -s -H "X-Vault-Token: $TOKEN" http://10.70.0.50:8200/v1/secret/data/khalil/awx/test
# Returns: {"data":{"data":{"TEST_VAR":"Hello"}}}
```

### Error: "permission denied"

```bash
# Check policy allows the path
vault policy read awx-secrets

# Verify role is bound correctly
vault read auth/kubernetes/role/awx-secrets-reader
```

### Error: "service account not found"

```bash
# Check AWX ServiceAccount exists
kubectl get serviceaccount -n awx awx

# Check pod is using correct ServiceAccount
kubectl get pod -n awx -o jsonpath='{.items[*].spec.serviceAccountName}'
```

### Error: "invalid role"

```bash
# Verify role exists
vault list auth/kubernetes/role/

# Re-create role if needed
vault delete auth/kubernetes/role/awx-secrets-reader
vault write auth/kubernetes/role/awx-secrets-reader \
  bound_service_account_names=awx \
  bound_service_account_namespaces=awx \
  policies=awx-secrets \
  ttl=1h
```

### Error: "Vault connection refused"

```bash
# From K8s pod, Vault is at private IP
# Make sure you're using 10.70.0.50:8200 not 127.0.0.1

kubectl exec -it -n awx deployment/awx-task -- curl -s http://10.70.0.50:8200/v1/sys/health
```

---

## Parameters Reference

### Vault Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `VAULT_ADDR` | `http://127.0.0.1:8200` | Local access via SSH tunnel |
| Vault Private IP | `10.70.0.50:8200` | Used by K8s pods |
| KV Engine Path | `secret/` | KV v2 secrets engine mount |
| Auth Path | `kubernetes` | K8s auth method mount |

### Kubernetes Auth Role

| Parameter | Value | Description |
|-----------|-------|-------------|
| Role Name | `awx-secrets-reader` | Name referenced in AWX |
| ServiceAccount Names | `awx` | Which SA can use this role |
| ServiceAccount Namespaces | `awx` | Which namespace |
| Policies | `awx-secrets` | What paths are allowed |
| TTL | `1h` | Token validity period |

### Secret Paths

| Path | Purpose |
|------|---------|
| `secret/khalil/awx/test` | Test variable (TEST_VAR) |
| `secret/khalil/awx/ssh/*` | SSH credentials |
| `secret/khalil/awx/cloud/*` | Cloud provider tokens |

---

## Security Best Practices

1. **Don't use root token in production** - Create a dedicated admin policy
2. **Enable audit logging** - `vault audit enable file file_path=/var/log/vault/audit.log`
3. **Use short TTLs** - 1h or less for automated systems
4. **Principle of least privilege** - Only grant paths actually needed
5. **Rotate secrets regularly** - Use Vault's versioning for rollback capability

---

## Files Created

| File | Purpose |
|------|---------|
| `awx/vault/VAULT-AWX-SETUP.md` | This documentation |
| `awx/vault/test-vault.yml` | Test playbook |

## Next Steps

1. Run the setup commands
2. Configure AWX UI credentials
3. Create and test the job template
4. Add more secrets as needed:
   ```bash
   vault kv put secret/khalil/awx/ssh/production \
     username="deploy" \
     ssh_key_data="$(cat ~/.ssh/deploy_key)"
   ```
