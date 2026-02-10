# ELK Stack on Kubernetes (ECK)

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Kubernetes Cluster                              │
│                                                                          │
│  ┌───────────────────────────┐   ┌─────────────────────────────────────┐ │
│  │    App Nodes (general)    │   │         ELK Nodes (elk)             │ │
│  │  label: node-type=general │   │  label: node-type=elk               │ │
│  │                           │   │  taint: dedicated=elk:NoSchedule    │ │
│  │  ┌─────┐ ┌──────────┐    │   │                                     │ │
│  │  │ AWX │ │Monitoring │    │   │  ┌──────────────────────────────┐   │ │
│  │  └─────┘ └──────────┘    │   │  │    ECK Operator (Helm)       │   │ │
│  │  ┌──────────┐ ┌──────┐   │   │  └──────────────────────────────┘   │ │
│  │  │Keycloak  │ │ CNPG │   │   │  ┌────────┐ ┌────────┐ ┌────────┐  │ │
│  │  └──────────┘ └──────┘   │   │  │ ES-0   │ │ ES-1   │ │ ES-2   │  │ │
│  │                           │   │  │ 50Gi   │ │ 50Gi   │ │ 50Gi   │  │ │
│  │                           │   │  │ PVC→PV │ │ PVC→PV │ │ PVC→PV │  │ │
│  │                           │   │  └────────┘ └────────┘ └────────┘  │ │
│  │                           │   │  ┌──────────┐                      │ │
│  │                           │   │  │ Kibana   │                      │ │
│  │                           │   │  └──────────┘                      │ │
│  ├───────────────────────────┤   ├─────────────────────────────────────┤ │
│  │  ┌──────────┐             │   │  ┌──────────┐  ┌──────────┐       │ │
│  │  │Filebeat  │ DaemonSet   │   │  │Filebeat  │  │Metricbeat│       │ │
│  │  │Metricbeat│ (all nodes) │   │  │Metricbeat│  │          │       │ │
│  │  └──────────┘             │   │  └──────────┘  └──────────┘       │ │
│  └───────────────────────────┘   └─────────────────────────────────────┘ │
│                                                                          │
│  Hetzner Block Storage (CSI)     ┌──────────────────────────────────┐    │
│  ┌─────────────────────────┐     │  StorageClass: hcloud-volumes   │    │
│  │ PV auto-provisioned by  │◄────│  binding: WaitForFirstConsumer  │    │
│  │ hcloud-csi driver when  │     │  expansion: true                │    │
│  │ PVC is bound to a pod   │     │  reclaim: Delete                │    │
│  └─────────────────────────┘     └──────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Version | Namespace | Runs On | Purpose |
|-----------|---------|-----------|---------|---------|
| **ECK Operator** | 2.14.0 | elastic-system | ELK nodes | Manages all Elastic CRDs |
| **Elasticsearch** | 8.15.3 | elastic-system | ELK nodes | Log storage & search engine |
| **Kibana** | 8.15.3 | elastic-system | ELK nodes | Visualization & dashboards |
| **Filebeat** | 8.15.3 | elastic-system | **ALL nodes** | Log collection (DaemonSet) |
| **Metricbeat** | 8.15.3 | elastic-system | **ALL nodes** | System & K8s metrics (DaemonSet) |

## Folder Structure

```
eck-operator/              # ArgoCD app — installs the ECK CRD operator
├── app.yaml               # ArgoCD Application (sync-wave: -1)
└── values.yaml            # Helm values (nodeSelector, tolerations)

elk-stack/                 # ArgoCD app — deploys the actual ELK workloads
├── app.yaml               # ArgoCD Application (sync-wave: 0)
├── README.md              # This documentation
└── manifests/
    ├── namespace.yaml     # elastic-system namespace
    ├── elasticsearch.yaml # 3-node ES cluster (50Gi each)
    ├── kibana.yaml        # Kibana instance
    ├── filebeat.yaml      # Log collection DaemonSet + RBAC
    ├── metricbeat.yaml    # Metrics collection DaemonSet + RBAC
    └── ingress.yaml       # Kibana ingress (kibana.tests.software)
```

## Node Placement & Taints

All ELK components (except Filebeat/Metricbeat) are pinned to ELK-dedicated nodes:

```yaml
nodeSelector:
  node-type: elk
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "elk"
    effect: "NoSchedule"
```

**Filebeat & Metricbeat** are DaemonSets that must collect from every node:

```yaml
tolerations:
  - operator: Exists      # Tolerates ALL taints → runs on every node
```

## Sync Order (ArgoCD Sync Waves)

```
Wave -3: cloudnative-pg operator
Wave -2: monitoring, barman-cloud-plugin
Wave -1: eck-operator          ← ECK CRDs installed here
Wave  0: elk-stack, awx        ← ES/Kibana/Filebeat/Metricbeat created here
Wave  1: postgres-bootstrap
```

The ECK operator must be ready **before** Elasticsearch/Kibana CRDs are applied.

---

## Storage — Deep Dive

### How Volumes Are Created (Automatic Provisioning)

Elasticsearch uses a **StatefulSet** managed by the ECK operator. Storage is **fully automatic** — you never create PVs manually. Here is the exact flow:

```
1. You define a volumeClaimTemplate in elasticsearch.yaml:
   ┌────────────────────────────────────────┐
   │ volumeClaimTemplates:                  │
   │   - metadata:                          │
   │       name: elasticsearch-data         │
   │     spec:                              │
   │       storageClassName: hcloud-volumes  │
   │       resources:                       │
   │         requests:                      │
   │           storage: 50Gi               │
   └────────────────────────────────────────┘
                    │
                    ▼
2. ECK Operator creates a StatefulSet with 3 replicas (ES nodes)
                    │
                    ▼
3. StatefulSet creates PVCs (one per replica):
   • elasticsearch-data-elk-es-default-0  (50Gi)
   • elasticsearch-data-elk-es-default-1  (50Gi)
   • elasticsearch-data-elk-es-default-2  (50Gi)
                    │
                    ▼
4. Pod is scheduled to an ELK node (nodeSelector: node-type=elk)
                    │
                    ▼
5. WaitForFirstConsumer: PV is NOT created until a pod is bound
   → CSI driver sees which zone/node the pod lands on
   → Creates a Hetzner Block Volume IN THAT SAME ZONE
   → Attaches it to the node, formats it, mounts it
                    │
                    ▼
6. PVC → PV binding is complete. ES node starts writing data.
```

**You do nothing.** The CSI driver handles volume creation, formatting, attaching, and mounting automatically.

### StorageClass Configuration

The `hcloud-volumes` StorageClass is deployed by the CSI driver addon:

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: hcloud-volumes
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.hetzner.cloud
volumeBindingMode: WaitForFirstConsumer   # ← Key: zone-aware provisioning
allowVolumeExpansion: true                # ← Key: online resize supported
reclaimPolicy: Delete                     # ← Key: PV deleted when PVC is removed
```

| Setting | Value | Why |
|---------|-------|-----|
| `volumeBindingMode` | `WaitForFirstConsumer` | PV is created in the same zone as the pod. Prevents cross-zone mounting failures. |
| `allowVolumeExpansion` | `true` | You can increase PVC size without downtime. Hetzner grows the block device online. |
| `reclaimPolicy` | `Delete` | When a PVC is deleted, the underlying Hetzner Volume is **destroyed**. This is the default and **correct for most cases** — see retention section below. |

### Volume Lifecycle — What Happens When

| Event | PVC | PV | Hetzner Volume | Data |
|-------|-----|-----|----------------|------|
| ES pod created | Created by StatefulSet | Auto-provisioned by CSI | Created in Hetzner Cloud | Empty |
| ES pod restarted | Unchanged | Unchanged | Unchanged | **Preserved** ✅ |
| ES pod rescheduled to same node | Unchanged | Re-mounted | Re-attached | **Preserved** ✅ |
| ES pod deleted (scale down) | **Still exists** | **Still bound** | **Still exists** | **Preserved** ✅ |
| ES pod re-created (scale up) | Re-used | Re-mounted | Re-attached | **Preserved** ✅ |
| PVC manually deleted | Deleted | Deleted (reclaimPolicy=Delete) | **DESTROYED** ❌ | **LOST** ❌ |
| Namespace deleted | All PVCs deleted | All PVs deleted | **ALL DESTROYED** ❌ | **ALL LOST** ❌ |
| `kubectl delete elasticsearch elk` | StatefulSet deleted, PVCs **kept** | Still bound | Still exists | **Preserved** ✅ |

> ⚠️ **Critical:** StatefulSet PVCs are NOT automatically deleted when you delete the Elasticsearch CR or scale down. This is a Kubernetes safety feature. Data is preserved until you explicitly delete the PVCs.

### Reclaim Policy — Delete vs Retain

| Policy | Behavior | Use Case |
|--------|----------|----------|
| **Delete** (current) | PV + Hetzner Volume destroyed when PVC is deleted | Dev/staging, or production with snapshot backups |
| **Retain** | PV becomes `Released`, Hetzner Volume preserved even after PVC deletion | Extra safety — but you must manually clean up orphaned volumes |

#### How to Switch to Retain (if needed)

**Option A — Patch existing PVs** (per-volume, does NOT affect future PVs):

```bash
# List ES volumes
kubectl get pv | grep elasticsearch-data

# Patch each PV to Retain
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

**Option B — Create a separate StorageClass** (for all future ELK volumes):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hcloud-volumes-retain
provisioner: csi.hetzner.cloud
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain                     # ← PV kept after PVC deletion
```

Then change `elasticsearch.yaml` to use `storageClassName: hcloud-volumes-retain`.

> 💡 **Professional recommendation:** Keep `Delete` policy and use **Elasticsearch Snapshots** for backups. Retain creates orphaned volumes that cost money and require manual cleanup.

### Volume Expansion — Growing Storage Online

Since `allowVolumeExpansion: true` is set, you can grow volumes **without any downtime**:

1. Edit `elasticsearch.yaml` → change `storage: 50Gi` to `storage: 100Gi`
2. Commit & push → ArgoCD syncs the change
3. ECK operator performs a **rolling update** — one ES node at a time
4. For each node:
   - Pod is stopped
   - CSI driver calls Hetzner API to resize the block volume
   - Filesystem is expanded (online, ext4/xfs)
   - Pod restarts with the larger volume
5. Zero data loss — ES rebalances shards automatically

> ⚠️ **You can only increase storage size, never decrease it.**

### Sizing Guidelines

| Cluster Size | ES Nodes | Storage per Node | Total | Use Case |
|:-------------|:---------|:-----------------|:------|:---------|
| Small/Dev    | 3        | 20Gi             | 60Gi  | Development, low log volume |
| **Default**  | **3**    | **50Gi**         | **150Gi** | **Production, moderate logs** |
| Large        | 3–5      | 100Gi            | 300–500Gi | High log volume, long retention |

**Estimating storage needs:**
- Average log line ≈ 500 bytes (after ES indexing overhead ≈ 1–1.5KB stored)
- 1 million log lines/day ≈ 1–1.5 GB/day in ES
- With 50Gi per node (150Gi total), ~30 days retention at moderate volume
- Metricbeat adds ~200MB/day for system + K8s metrics

---

## Backup & Retention Strategy

### The Professional Approach

**Never rely on PV/disk retention for backups.** The correct strategy is:

```
┌─────────────────────┐     ┌──────────────────────┐     ┌──────────────┐
│   Elasticsearch     │────▶│  Snapshot to S3       │────▶│  Hetzner     │
│   (hot data on PV)  │     │  (daily, automated)   │     │  Object      │
│                     │     │                        │     │  Storage     │
│   ILM Policy:       │     │  SLM Policy:           │     │  (cold/warm) │
│   - Hot: 7 days     │     │  - Daily at 02:30      │     │              │
│   - Delete: 30 days │     │  - Retain 30 days      │     │  Cost: ~€5/  │
│                     │     │  - Min 5 snapshots     │     │  TB/month    │
└─────────────────────┘     └──────────────────────┘     └──────────────┘
```

### Layer 1: Index Lifecycle Management (ILM) — Automatic Cleanup

Filebeat and Metricbeat are configured with ILM. This controls **how long data stays in Elasticsearch**:

| Phase | Age | Action |
|-------|-----|--------|
| **Hot** | 0–7 days | Primary shard, full indexing, all queries served |
| **Warm** | 7–14 days | Read-only, force-merge to 1 segment (less disk) |
| **Delete** | 30 days | Index permanently deleted from ES |

To customize, go to **Kibana → Stack Management → Index Lifecycle Policies**.

### Layer 2: Elasticsearch Snapshots — Disaster Recovery

Register a snapshot repository (S3-compatible — Hetzner Object Storage):

```json
PUT _snapshot/s3_backup
{
  "type": "s3",
  "settings": {
    "bucket": "elk-backups",
    "endpoint": "fsn1.your-objectstorage.com",
    "protocol": "https"
  }
}
```

Create an automated Snapshot Lifecycle Management (SLM) policy:

```json
PUT _slm/policy/daily-snapshots
{
  "schedule": "0 30 2 * * ?",
  "name": "<daily-snap-{now/d}>",
  "repository": "s3_backup",
  "config": {
    "indices": ["filebeat-*", "metricbeat-*", "logs-*"],
    "ignore_unavailable": true
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 5,
    "max_count": 50
  }
}
```

### Layer 3: Hetzner Volume Snapshots (Optional)

Hetzner supports server/volume snapshots at the cloud level. This is a brute-force backup but costs more:

```bash
# Create a snapshot of a Hetzner volume via API
hcloud volume create-snapshot <volume-id> --description "elk-backup-$(date +%F)"
```

> Not recommended as primary strategy — use ES snapshots instead.

---

## Post-Deployment Steps

### 1. Get Elasticsearch Password

ECK auto-generates the `elastic` user password as a Kubernetes secret:

```bash
kubectl get secret elk-es-elastic-user -n elastic-system \
  -o jsonpath='{.data.elastic}' | base64 -d ; echo
```

### 2. Access Kibana

After DNS is configured for `kibana.tests.software`:

```
URL:      https://kibana.tests.software
User:     elastic
Password: (from step 1)
```

### 3. Verify Data is Flowing

In Kibana:
- **Filebeat:** Discover → Create data view for `filebeat-*`
- **Metricbeat:** Discover → Create data view for `metricbeat-*`
- **Dashboards:** Metricbeat auto-loads Kibana dashboards (system, kubernetes)

### 4. Monitor Cluster Health

```bash
# Port-forward to ES
kubectl port-forward svc/elk-es-http -n elastic-system 9200:9200

# Check cluster health
curl -k -u "elastic:$(kubectl get secret elk-es-elastic-user \
  -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)" \
  https://localhost:9200/_cluster/health?pretty

# Check indices
curl -k -u "elastic:..." https://localhost:9200/_cat/indices?v

# Check storage usage
curl -k -u "elastic:..." https://localhost:9200/_cat/allocation?v
```

### 5. Verify Volumes

```bash
# Check PVCs created by ES StatefulSet
kubectl get pvc -n elastic-system

# Expected output:
# elasticsearch-data-elk-es-default-0   Bound   pvc-xxx   50Gi   hcloud-volumes
# elasticsearch-data-elk-es-default-1   Bound   pvc-yyy   50Gi   hcloud-volumes
# elasticsearch-data-elk-es-default-2   Bound   pvc-zzz   50Gi   hcloud-volumes

# Check PVs and their reclaim policy
kubectl get pv | grep elasticsearch

# Check Hetzner volumes (from local machine)
hcloud volume list
```

---

## Resource Summary

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| ECK Operator | 100m | 500m | 256Mi | 512Mi | — |
| Elasticsearch (×3) | 500m | 2000m | 2Gi | 4Gi | 50Gi each |
| Kibana | 250m | 1000m | 512Mi | 1Gi | — |
| Filebeat (per node) | 50m | 200m | 128Mi | 256Mi | — |
| Metricbeat (per node) | 50m | 200m | 128Mi | 256Mi | — |

**Total ELK node resource usage** (3 ES + 1 Kibana + 1 Operator + 1 Filebeat + 1 Metricbeat):
- CPU: ~2.1 cores request / ~7.9 cores limit
- Memory: ~7.5Gi request / ~14.3Gi limit
- Storage: 150Gi (3 × 50Gi Hetzner Block Volumes)

> 💡 **This is why `cx42` (4 vCPU / 16GB RAM) is the recommended minimum ELK node server type.**

---

## Troubleshooting

| Issue | Command | Solution |
|-------|---------|----------|
| ES pod stuck Pending | `kubectl describe pod elk-es-default-0 -n elastic-system` | Check nodeSelector, tolerations, or PVC binding |
| PVC stuck Pending | `kubectl describe pvc <name> -n elastic-system` | Check CSI driver is running, hcloud token valid |
| Cluster status RED | `curl .../_cluster/health?pretty` | Check unassigned shards: `_cat/shards?v&h=index,shard,prirep,state,unassigned.reason` |
| Filebeat not shipping | `kubectl logs ds/filebeat-beat-filebeat -n elastic-system` | Check ES connectivity, RBAC |
| Metricbeat no data | `kubectl logs ds/metricbeat-beat-metricbeat -n elastic-system` | Check kube-state-metrics service reachable |
| Volume full | `_cat/allocation?v` | Increase storage in elasticsearch.yaml or add ILM delete policy |
