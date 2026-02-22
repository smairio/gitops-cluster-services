# Elasticsearch Snapshot & Restore Guide

> **Quick Reference** for viewing, selecting, and restoring Elasticsearch snapshots from S3.

## Prerequisites

```bash
# Get Elasticsearch password
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)
echo "ES Password: $ES_PASSWORD"

# Verify cluster is healthy
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" "https://localhost:9200/_cluster/health?pretty"
```

---

## 1. View Available Snapshots

### List All Snapshots

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_snapshot/s3-backups/_all?pretty"
```

### List Snapshots (Summary Only)

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_cat/snapshots/s3-backups?v&s=start_epoch:desc"
```

**Output columns:**
| Column | Description |
|--------|-------------|
| `id` | Snapshot name (use this for restore) |
| `status` | SUCCESS, IN_PROGRESS, FAILED |
| `start_epoch` | When snapshot started |
| `end_epoch` | When snapshot finished |
| `duration` | How long it took |
| `indices` | Number of indices in snapshot |

### Get Details of a Specific Snapshot

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)
SNAPSHOT_NAME="elk-snap-2026.02.17-4_wr37xmsdg3_vxbxtplxq"  # <-- Change this

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_snapshot/s3-backups/${SNAPSHOT_NAME}?pretty"
```

---

## 2. Restore a Snapshot

### Option A: Restore with Rename (Recommended - No Data Loss)

This restores data alongside existing data with a `restored-` prefix.

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)
SNAPSHOT_NAME="elk-snap-2026.02.17-4_wr37xmsdg3_vxbxtplxq"  # <-- Change this

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X POST "https://localhost:9200/_snapshot/s3-backups/${SNAPSHOT_NAME}/_restore?pretty" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "filebeat-*,metricbeat-*",
    "include_global_state": false,
    "rename_pattern": "(.+)",
    "rename_replacement": "17-02-2025-restored-$1"
  }'
```

**After restore, create a Data View in Kibana:**
- Index pattern: `restored-*`
- Timestamp field: `@timestamp`

### Option B: Full Replace (Deletes Current Data)

⚠️ **Warning:** This deletes current data streams before restoring.

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)
SNAPSHOT_NAME="elk-snap-2026.02.17-4_wr37xmsdg3_vxbxtplxq"  # <-- Change this

# Step 1: Stop ILM
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" -X POST "https://localhost:9200/_ilm/stop"

# Step 2: Delete existing data streams
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X DELETE "https://localhost:9200/_data_stream/filebeat-8.15.3,metricbeat-8.15.3"

# Step 3: Restore from snapshot
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X POST "https://localhost:9200/_snapshot/s3-backups/${SNAPSHOT_NAME}/_restore?pretty" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "filebeat-*,metricbeat-*",
    "include_global_state": false
  }'

# Step 4: Resume ILM
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" -X POST "https://localhost:9200/_ilm/start"
```

### Option C: Restore Kibana Settings Only

Restore dashboards, saved objects, and Kibana configuration:

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)
SNAPSHOT_NAME="elk-snap-2026.02.17-4_wr37xmsdg3_vxbxtplxq"  # <-- Change this

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X POST "https://localhost:9200/_snapshot/s3-backups/${SNAPSHOT_NAME}/_restore?pretty" \
  -H 'Content-Type: application/json' \
  -d '{
    "feature_states": ["kibana"],
    "include_global_state": false,
    "indices": "-*"
  }'
```

---

## 3. Monitor Restore Progress

### Check Restore Status

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_recovery?active_only=true&pretty"
```

### Verify Restored Indices

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_cat/indices?v&s=index"
```

### Check Data Streams

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  "https://localhost:9200/_data_stream?pretty"
```

---

## 4. View Restored Data in Kibana

### Create Data View for Restored Data

1. **Go to**: `☰ Menu` → `Stack Management` → `Data Views`
2. **Click**: `Create data view`
3. **Configure**:
   - **Name**: `Restored Logs`
   - **Index pattern**: `restored-*`
   - **Timestamp field**: `@timestamp`
4. **Save** the data view

### Query Restored Data

1. Go to **Discover** (`☰ Menu` → `Discover`)
2. Select **`Restored Logs`** from the dropdown
3. Set time range to the date of the snapshot

---

## 5. Cleanup Restored Data

When you no longer need the restored data:

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

# Delete restored data streams
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X DELETE "https://localhost:9200/_data_stream/restored-*"
```

---

## 6. Create Manual Snapshot

Trigger a snapshot immediately (outside of schedule):

```bash
ES_PASSWORD=$(kubectl get secret elk-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" \
  -X POST "https://localhost:9200/_slm/policy/daily-snapshot/_execute?pretty"
```

---

## Quick Reference Table

| Action | Command |
|--------|---------|
| List snapshots | `_cat/snapshots/s3-backups?v` |
| View snapshot details | `_snapshot/s3-backups/<name>?pretty` |
| Restore with rename | `_snapshot/s3-backups/<name>/_restore` with `rename_pattern` |
| Check restore progress | `_recovery?active_only=true` |
| Check ILM status | `_ilm/status` |
| Stop ILM | `POST _ilm/stop` |
| Start ILM | `POST _ilm/start` |
| Delete data stream | `DELETE _data_stream/<name>` |
| Trigger manual snapshot | `POST _slm/policy/daily-snapshot/_execute` |

---

## Troubleshooting

### Error: "index with same name already exists"

**Solution**: Use `rename_pattern` and `rename_replacement` in restore request, or delete existing data streams first.

### Error: "snapshot not found"

**Solution**: Check snapshot name with `_cat/snapshots/s3-backups?v`

### Restore stuck at "yellow" health

**Solution**: Wait for replica shards to be allocated. Check with:
```bash
kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
  curl -sk -u "elastic:$ES_PASSWORD" "https://localhost:9200/_cluster/health?pretty"
```
