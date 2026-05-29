# Runbook: Vault Ingest Pipeline

## Overview

Event-driven pipeline that indexes the Obsidian vault into Qdrant in real-time.
File changes on the desktop are detected, published to Redpanda (Kafka-compatible broker),
consumed by a K8s Deployment, embedded via Ollama, and upserted into Qdrant.

A fallback CronJob runs at 3am daily to catch any missed events.

---

## Architecture

```
Desktop (py-xps-8930)           K8s Cluster
──────────────────────          ──────────────────────────────────────────────
Obsidian Vault                  messaging namespace
  /home/py/Documents/    →        Redpanda (redpanda-0)
  obsidian-vault/                   topic: vault-changes
       ↓ watchdog                   PVC: 5Gi (truenas-iscsi)
vault-watcher.service                     ↓ consume
  (systemd)              →        vault-ingest namespace
       ↓ localhost:9092              vault-ingest-consumer (Deployment)
redpanda-portforward               ConfigMap: sre-config
  .service (systemd)                     ↓ embed         ↓ upsert
  kubectl port-forward            Ollama (desktop)    Qdrant (ai-platform)
  svc/redpanda :9092              10.0.0.113:11434    port 6333
```

---

## Services and Components

### Desktop (py-xps-8930)

| Service | Description | Config |
|---|---|---|
| `vault-watcher.service` | Watches vault for file changes, publishes events to Redpanda | `/etc/systemd/system/vault-watcher.service` |
| `redpanda-portforward.service` | Tunnels `localhost:9092` → Redpanda in cluster | `/etc/systemd/system/redpanda-portforward.service` |

**Config file:** `/home/py/.config/sre/config.toml`
```toml
ollama_model = "mistral"
embed_ollama_url = "http://10.0.0.113:11434"
qdrant_url = "http://qdrant.ai-platform.svc.cluster.local:6333"
vault_path = "/home/py/Documents/obsidian-vault"
redpanda_url = "localhost:9092"
```

**`/etc/hosts` entry required:**
```
127.0.0.1  redpanda-0.redpanda.messaging.svc.cluster.local.
```
This is needed because Redpanda advertises its internal K8s hostname to clients.
The port-forward handles the actual connection but the hostname must resolve locally.

**Python environment:** `/home/py/myenv`
**Installed via:** `pip install git+https://github.com/t12-pybash/sre-cli.git`

---

### Kubernetes Cluster

| Resource | Namespace | Description |
|---|---|---|
| StatefulSet `redpanda` | `messaging` | Single-node Redpanda broker (Kafka-compatible) |
| PVC `redpanda-data-redpanda-0` | `messaging` | 5Gi log retention on truenas-iscsi |
| HelmRelease `redpanda` | `messaging` | Flux-managed, chart version 26.1.4 |
| Deployment `vault-ingest-consumer` | `vault-ingest` | Long-running Kafka consumer |
| CronJob `vault-ingest` | `vault-ingest` | Fallback full-sync at 3am daily |
| ConfigMap `sre-config` | `vault-ingest` | sre-cli config injected into pods |
| NetworkPolicy `allow-from-vault-ingest` | `ai-platform` | Permits consumer → Qdrant on port 6333 |

**Container image:** `ghcr.io/t12-pybash/sre-cli:latest` (public)
**Source:** `https://github.com/t12-pybash/sre-cli`

---

## How to Test

### 1. Check all services are running

On the desktop:
```bash
systemctl status vault-watcher
systemctl status redpanda-portforward
```

In the cluster:
```bash
kubectl get pods -n messaging
kubectl get pods -n vault-ingest
```

Expected:
- `redpanda-0` → `2/2 Running`
- `vault-ingest-consumer-*` → `1/1 Running`

### 2. End-to-end test

Write content to a vault file on the desktop:
```bash
echo "# Test\n\nThis is a test note." > /home/py/Documents/obsidian-vault/test-pipeline.md
```

Watch the consumer process it (from laptop):
```bash
kubectl logs -n vault-ingest -l app=vault-ingest-consumer --since=30s -f
```

Expected output:
```
INFO modified: test-pipeline.md (1 chunks)
```

### 3. Verify the message reached Redpanda

```bash
kubectl exec -n messaging redpanda-0 -- rpk topic consume vault-changes --num 1
```

Expected: JSON message with `path`, `action`, `content` fields.

### 4. Verify the vector landed in Qdrant

```bash
curl -s http://qdrant.home.t12.io/collections/vault/points/scroll \
  -H 'Content-Type: application/json' \
  -d '{"filter":{"must":[{"key":"file","match":{"value":"test-pipeline.md"}}]},"limit":5}' \
  | python3 -m json.tool | grep -E 'file|chunk|text'
```

### 5. Test deletion

```bash
rm /home/py/Documents/obsidian-vault/test-pipeline.md
kubectl logs -n vault-ingest -l app=vault-ingest-consumer --since=10s
```

Expected: `INFO deleted: test-pipeline.md`

---

## Troubleshooting

### vault-watcher not publishing events

```bash
journalctl -u vault-watcher -n 20 --no-pager
```

Common causes:
- `Failed to resolve redpanda-0.redpanda.messaging.svc.cluster.local` → check `/etc/hosts` entry exists
- `Failed to resolve localhost:9092` → check `redpanda-portforward.service` is running
- Module not found → reinstall: `/home/py/myenv/bin/pip install --force-reinstall git+https://github.com/t12-pybash/sre-cli.git`

### redpanda-portforward keeps restarting

```bash
journalctl -u redpanda-portforward -n 10 --no-pager
```

Common causes:
- kubectl not found → check path in service file: `sudo cat /etc/systemd/system/redpanda-portforward.service`
- kubeconfig expired → re-authenticate: `kubectl get nodes`
- Redpanda pod not running → check `kubectl get pods -n messaging`

### Consumer not processing messages

```bash
kubectl logs -n vault-ingest -l app=vault-ingest-consumer --since=5m
kubectl describe pod -n vault-ingest -l app=vault-ingest-consumer
```

Common causes:
- `ConnectTimeout` to Qdrant → NetworkPolicy `allow-from-vault-ingest` missing in `ai-platform` namespace
- `ConnectTimeout` to Redpanda → Redpanda pod not running, check `kubectl get pods -n messaging`
- `Name does not resolve` → ConfigMap has wrong `qdrant_url` or `redpanda_url`

### Redpanda pod stuck in ImagePullBackOff

The `docker.redpanda.com` registry has unauthenticated rate limits. All images are overridden to Docker Hub in the HelmRelease — if this recurs, check the HelmRelease values in `infrastructure/prod/redpanda/helmrelease.yaml`.

---

## Restart Procedures

### Restart vault watcher (desktop)
```bash
sudo systemctl restart vault-watcher
```

### Restart port-forward (desktop)
```bash
sudo systemctl restart redpanda-portforward
```

### Restart consumer (cluster)
```bash
kubectl rollout restart deployment/vault-ingest-consumer -n vault-ingest
```

### Force a full re-index (trigger CronJob manually)
```bash
kubectl create job vault-ingest-manual-$(date +%s) --from=cronjob/vault-ingest -n vault-ingest
kubectl logs -n vault-ingest -l job-name=<job-name> -c ingest -f
```

---

## Repo Locations

| Artifact | Location |
|---|---|
| K8s manifests | `homelab-gitops/apps/prod/vault-ingest/` |
| Redpanda HelmRelease | `homelab-gitops/infrastructure/prod/redpanda/` |
| systemd service files | `homelab-gitops/infrastructure/prod/redpanda/desktop/` |
| sre-cli source | `https://github.com/t12-pybash/sre-cli` |
| Container image | `ghcr.io/t12-pybash/sre-cli:latest` |
| draw.io diagram | `homelab-gitops/diagrams/vault-ingest-pipeline.drawio` |
