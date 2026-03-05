# AWX + Vault: How It Works (Simple Guide)

## The Big Picture

When you run a job in AWX that needs secrets from Vault, here's what happens:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              YOUR JOB RUNS                                   │
│                                                                              │
│  1. You click "Launch" on Job Template                                       │
│                         │                                                    │
│                         ▼                                                    │
│  2. AWX sees: "This template has a credential attached"                      │
│     Credential: "Test Vault Lookup Credential"                               │
│     Credential Type: "Vault Test Credential"                                 │
│                         │                                                    │
│                         ▼                                                    │
│  3. AWX reads the credential config and sees:                                │
│     "TEST_VAR field is NOT storing a value directly"                         │
│     "TEST_VAR field has EXTERNAL LOOKUP metadata"                            │
│     Metadata says:                                                           │
│       - Use Vault credential: "Vault Kubernetes Auth"                        │
│       - Backend: secret                                                      │
│       - Path: khalil/awx/test                                                │
│       - Key: TEST_VAR                                                        │
│                         │                                                    │
│                         ▼                                                    │
│  4. AWX AUTOMATICALLY performs these steps:                                  │
│                                                                              │
│     a) Read ServiceAccount token from pod filesystem                         │
│        /var/run/secrets/kubernetes.io/serviceaccount/token                   │
│                         │                                                    │
│     b) Send token to Vault for authentication                                │
│        POST http://10.70.0.50:8200/v1/auth/kubernetes/login                  │
│        Body: {"role": "awx-secrets-reader", "jwt": "<token>"}                │
│                         │                                                    │
│     c) Vault verifies the token with Kubernetes API                          │
│        "Is this token valid? Is it from service account 'awx' in 'awx' ns?"  │
│                         │                                                    │
│     d) Vault returns a temporary Vault token                                 │
│        (valid for 1 hour as configured in role)                              │
│                         │                                                    │
│     e) AWX reads the secret from Vault                                       │
│        GET http://10.70.0.50:8200/v1/secret/data/khalil/awx/test             │
│        Header: X-Vault-Token: hvs.xxxx                                       │
│                         │                                                    │
│     f) Vault returns: {"data":{"data":{"TEST_VAR":"Hello"}}}                 │
│                         │                                                    │
│     g) AWX extracts the value: "Hello"                                       │
│                         │                                                    │
│                         ▼                                                    │
│  5. AWX prepares to run playbook with the injector config:                   │
│                                                                              │
│     Injector Configuration says:                                             │
│       extra_vars:                                                            │
│         test_var: '{{ test_var }}'                                           │
│                         │                                                    │
│     So AWX runs:                                                             │
│       ansible-playbook playbook.yml --extra-vars "test_var=Hello"            │
│                         │                                                    │
│                         ▼                                                    │
│  6. Playbook executes and can use {{ test_var }}                             │
│                                                                              │
│     - name: Show the secret                                                  │
│       debug:                                                                 │
│         msg: "Value is: {{ test_var }}"                                      │
│                                                                              │
│     Output: "Value is: Hello"                                                │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## How Does AWX Know to Use External Secret?

When you create a credential and click the 🔑 icon instead of typing a value:

**Without External Lookup (static value):**
```
┌─────────────────────────────────────────┐
│ Credential: My Credential               │
│                                         │
│ TEST_VAR: [my-secret-value________]     │  ← You type the actual value
│                                         │
│ Stored in AWX database (encrypted)      │
└─────────────────────────────────────────┘
```

**With External Lookup (Vault):**
```
┌─────────────────────────────────────────┐
│ Credential: My Credential               │
│                                         │
│ TEST_VAR: [🔑 Vault Kubernetes Auth   ] │  ← You click 🔑 and configure lookup
│                                         │
│ Stored in AWX database:                 │
│ {                                       │
│   "backend": "secret",                  │
│   "path": "khalil/awx/test",            │
│   "key": "TEST_VAR",                    │
│   "credential": "Vault Kubernetes Auth" │
│ }                                       │
│                                         │
│ NO ACTUAL SECRET IS STORED!             │
│ Only metadata about WHERE to find it    │
└─────────────────────────────────────────┘
```

## The Three Pieces You Need

### 1. Vault Lookup Credential (HashiCorp Vault Secret Lookup)

This tells AWX HOW to connect to Vault:
- Server URL: `http://10.70.0.50:8200`
- Auth method: Kubernetes
- Role: `awx-secrets-reader`
- API Version: `v2`

This credential NEVER stores secrets - it's just connection info.

### 2. Custom Credential Type (Optional but recommended)

This defines:
- **What fields exist** (INPUT CONFIGURATION)
- **How to inject them** (INJECTOR CONFIGURATION)

```yaml
# INPUT: What you see in the UI
fields:
  - id: test_var        # Internal ID
    type: string        # Field type
    label: TEST_VAR     # UI label

# INJECTOR: How it gets into playbook
extra_vars:
  test_var: '{{ test_var }}'   # Becomes --extra-vars "test_var=VALUE"
```

### 3. Actual Credential Instance

Where you:
1. Pick the credential type
2. Click 🔑 on each field
3. Configure the Vault path for each field

## Step-by-Step: What to Configure

### Step 1: Create Vault Lookup Credential

**Resources → Credentials → Add**

| Field | Value |
|-------|-------|
| Name | `Vault Kubernetes Auth` |
| Credential Type | `HashiCorp Vault Secret Lookup` |
| Server URL | `http://10.70.0.50:8200` |
| Kubernetes role | `awx-secrets-reader` |
| Path to Auth | `kubernetes` |
| API Version | `v2` |

Leave all other fields empty!

### Step 2: Create Custom Credential Type

**Administration → Credential Types → Add**

| Field | Value |
|-------|-------|
| Name | `Vault Test Credential` |

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

### Step 3: Create Credential with Vault Lookup

**Resources → Credentials → Add**

| Field | Value |
|-------|-------|
| Name | `My Test Credential` |
| Credential Type | `Vault Test Credential` |

In the **TEST_VAR** field, click the 🔑 icon:

| Dialog Field | Value |
|--------------|-------|
| Credential | `Vault Kubernetes Auth` |
| Name of Secret Backend | `secret` |
| Path to Secret | `khalil/awx/test` |
| Key Name | `TEST_VAR` |

Click OK, then Save.

### Step 4: Create Job Template

**Resources → Templates → Add → Job Template**

| Field | Value |
|-------|-------|
| Name | `Test Vault` |
| Inventory | Any |
| Project | Your project |
| Playbook | test-vault.yml |
| **Credentials** | Add `My Test Credential` |

### Step 5: Launch and Verify

Click Launch. The job output should show:
```
TASK [Show the secret] ********************************************************
ok: [localhost] => {
    "msg": "Value is: Hello"
}
```

## Common Problems

### 403 Permission Denied

**Cause 1:** API Version is `v1` instead of `v2`
- Fix: Edit Vault Kubernetes Auth credential, change API Version to `v2`

**Cause 2:** Name of Secret Backend is empty
- Fix: In External Secret dialog, set `Name of Secret Backend` to `secret`

### Credential Test Fails

**Cause:** Kubernetes role not set correctly
- Fix: In Vault Kubernetes Auth credential, set `Kubernetes role` to `awx-secrets-reader`

### Variable is Undefined in Playbook

**Cause:** Credential not attached to job template
- Fix: Add the credential to the job template under "Credentials"

**Cause:** Injector configuration missing
- Fix: Check the custom credential type has proper injector config

## Summary

1. **Vault Kubernetes Auth** - Connection config (no secrets stored)
2. **Custom Credential Type** - Defines fields + how they inject into playbooks
3. **Credential Instance** - Links fields to specific Vault paths via 🔑
4. **Job Template** - Attaches credentials, AWX auto-fetches at runtime
5. **Playbook** - Uses `{{ variable_name }}` to access injected values

The magic happens **automatically at runtime** - AWX handles all the Vault authentication and secret fetching behind the scenes!
