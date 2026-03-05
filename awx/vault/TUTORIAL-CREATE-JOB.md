# Tutorial: Creating an AWX Job That Uses Vault Secrets

This tutorial walks through creating a complete job template that fetches `TEST_VAR=Hello` from Vault and uses it in a playbook.

## Prerequisites

- Vault secret exists: `secret/khalil/awx/test` with key `TEST_VAR=Hello` ✅
- Vault Kubernetes Auth credential created in AWX ✅
- AWX accessible at https://awx.dev.tests.software/

---

## Step 1: Create Custom Credential Type

### 1.1 Navigate to Credential Types
- Go to AWX UI: https://awx.dev.tests.software/
- Click **Administration** in left sidebar
- Click **Credential Types**
- Click **Add** button (top right)

### 1.2 Fill in the Form

**Name:** `Vault Test Credential`

**Description:** `Credential type for Vault TEST_VAR lookup`

**Input Configuration:** (paste this YAML)
```yaml
fields:
  - id: test_var
    type: string
    label: TEST_VAR
    help_text: "Test variable from Vault (secret/khalil/awx/test)"
required:
  - test_var
```

**Injector Configuration:** (paste this YAML)
```yaml
extra_vars:
  test_var: '{{ test_var }}'
```

### 1.3 Click Save

You should see "Vault Test Credential" in the list.

---

## Step 2: Create Credential with Vault Lookup

### 2.1 Navigate to Credentials
- Click **Resources** in left sidebar
- Click **Credentials**
- Click **Add** button

### 2.2 Fill in Basic Info

| Field | Value |
|-------|-------|
| **Name** | `Test Vault Lookup Credential` |
| **Organization** | Default |
| **Credential Type** | `Vault Test Credential` (the one you just created) |

### 2.3 Configure Vault Lookup

After selecting the credential type, you'll see a **TEST_VAR** field.

**Click the 🔑 (key) icon** next to TEST_VAR field.

A dialog opens: **"External Secret Management System"**

Fill in:

| Field | Value |
|-------|-------|
| **Credential** | `Vault Kubernetes Auth` |
| **Name of Secret Backend** | `secret` |
| **Path to Secret** | `khalil/awx/test` |
| **Path to Auth** | *(leave empty)* |
| **Key Name** | `TEST_VAR` |
| **Secret Version** | *(leave empty)* |

### 2.4 Click OK and Save

The credential is now configured to fetch from Vault at runtime.

---

## Step 3: Create a Project (if needed)

If you don't have a project, create one for the test playbook.

### 3.1 Navigate to Projects
- Click **Resources** → **Projects** → **Add**

### 3.2 Fill in the Form

| Field | Value |
|-------|-------|
| **Name** | `GitOps Cluster Services` |
| **Organization** | Default |
| **Source Control Type** | Git |
| **Source Control URL** | `https://github.com/smairio/gitops-cluster-services.git` |
| **Source Control Branch/Tag** | `main` |

### 3.3 Click Save

Wait for project sync to complete (green checkmark).

---

## Step 4: Create Job Template

### 4.1 Navigate to Templates
- Click **Resources** → **Templates** → **Add** → **Add job template**

### 4.2 Fill in the Form

| Field | Value |
|-------|-------|
| **Name** | `Test Vault Integration` |
| **Job Type** | Run |
| **Inventory** | Demo Inventory (or any inventory) |
| **Project** | `GitOps Cluster Services` |
| **Playbook** | `awx/vault/test-vault.yml` |
| **Credentials** | *(see step below)* |

### 4.3 Add Credentials

Click the **magnifying glass 🔍** icon next to Credentials field.

In the dialog:
1. Select **Credential Type**: `Vault Test Credential`
2. Check the box next to `Test Vault Lookup Credential`
3. Click **Select**

You should see the credential appear in the Credentials field.

### 4.4 Click Save

---

## Step 5: Run the Job

### 5.1 Launch the Job
- In the Templates list, find `Test Vault Integration`
- Click the **🚀 (rocket)** icon to launch

### 5.2 Watch the Output

The job will run. You should see output like:

```
PLAYBOOK: test-vault.yml ******************************************************
PLAY [Test Vault Integration] ************************************************

TASK [Check if test_var is defined] ******************************************
ok: [localhost] => {
    "msg": "test_var is defined"
}

TASK [Display TEST_VAR from Vault] *******************************************
ok: [localhost] => {
    "msg": "TEST_VAR value is: Hello"
}

TASK [Verify TEST_VAR has expected value] ************************************
ok: [localhost] => {
    "changed": false,
    "msg": "✅ Vault integration working! TEST_VAR = Hello"
}

TASK [Summary] ***************************************************************
ok: [localhost] => {
    "msg": "====================================\nVault Integration Test: PASSED\n====================================\nSecret Path: secret/khalil/awx/test\nKey: TEST_VAR\nValue: Hello\n===================================="
}

PLAY RECAP *******************************************************************
localhost                  : ok=4    changed=0    unreachable=0    failed=0    skipped=0
```

---

## What Happened Behind the Scenes

When you clicked Launch:

1. **AWX loaded the job template** and saw credential `Test Vault Lookup Credential` attached

2. **AWX read the credential** and found TEST_VAR field has External Secret metadata:
   - Backend: `secret`
   - Path: `khalil/awx/test`
   - Key: `TEST_VAR`

3. **AWX authenticated to Vault** using the awx-task pod's ServiceAccount token:
   ```
   POST http://10.70.0.50:8200/v1/auth/kubernetes/login
   Body: {"role": "awx-secrets-reader", "jwt": "<ServiceAccount JWT>"}
   ```

4. **Vault validated** the JWT with Kubernetes API and confirmed:
   - ServiceAccount: `awx`
   - Namespace: `awx`
   - Role allows: `awx-secrets` policy

5. **AWX fetched the secret**:
   ```
   GET http://10.70.0.50:8200/v1/secret/data/khalil/awx/test
   Header: X-Vault-Token: hvs.xxxxx
   ```

6. **Vault returned**:
   ```json
   {"data": {"data": {"TEST_VAR": "Hello"}}}
   ```

7. **AWX extracted** the value `Hello` for key `TEST_VAR`

8. **AWX ran ansible-playbook** with the injected variable:
   ```bash
   ansible-playbook awx/vault/test-vault.yml --extra-vars "test_var=Hello"
   ```

9. **Playbook accessed** `{{ test_var }}` and displayed "Hello"

---

## The Test Playbook

For reference, here's the playbook at `awx/vault/test-vault.yml`:

```yaml
---
- name: Test Vault Integration
  hosts: localhost
  gather_facts: false
  connection: local
  
  tasks:
    - name: Check if test_var is defined
      ansible.builtin.debug:
        msg: "test_var is {{ 'defined' if test_var is defined else 'NOT defined' }}"
    
    - name: Display TEST_VAR from Vault
      ansible.builtin.debug:
        msg: "TEST_VAR value is: {{ test_var | default('NOT SET') }}"
      
    - name: Verify TEST_VAR has expected value
      ansible.builtin.assert:
        that:
          - test_var is defined
          - test_var == "Hello"
        fail_msg: "TEST_VAR verification failed!"
        success_msg: "✅ Vault integration working! TEST_VAR = {{ test_var }}"
    
    - name: Summary
      ansible.builtin.debug:
        msg: |
          ====================================
          Vault Integration Test: PASSED
          ====================================
          Secret Path: secret/khalil/awx/test
          Key: TEST_VAR
          Value: {{ test_var }}
          ====================================
```

---

## Troubleshooting

### Job fails with "test_var is undefined"

**The credential wasn't attached or injector config is wrong.**

Fix:
1. Edit job template
2. Verify credential is in the Credentials field
3. Check the credential type has injector config:
   ```yaml
   extra_vars:
     test_var: '{{ test_var }}'
   ```

### Job fails with 403 error

**Vault credential configuration issue.**

Fix:
1. Edit `Vault Kubernetes Auth` credential
2. Check:
   - API Version: `v2` (not v1!)
   - Kubernetes role: `awx-secrets-reader`

### External Secret dialog shows error

**Name of Secret Backend is empty.**

Fix:
1. When configuring the 🔑 lookup
2. Set `Name of Secret Backend` to `secret`

---

## Summary Checklist

- [ ] Created Custom Credential Type with input + injector config
- [ ] Created Credential with 🔑 Vault lookup for TEST_VAR
- [ ] Created Project pointing to repo with test playbook
- [ ] Created Job Template with:
  - Inventory selected
  - Project selected
  - Playbook selected: `awx/vault/test-vault.yml`
  - Credential attached: `Test Vault Lookup Credential`
- [ ] Launched job and verified `TEST_VAR=Hello` in output
