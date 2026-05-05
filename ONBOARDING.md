# Homelab GitOps - Onboarding & Reference Guide

**Last Updated**: May 5, 2026  
**Cluster Status**: ✅ Healthy (6 nodes, all services running)

This is your **single source of truth** for the homelab setup. Clone this repo and reference it from any workstation.

---

## Quick Start (Any Workstation)

```bash
# Clone the repo
git clone ssh://git@gitlab.com/pybashinf-group/homelab-gitops.git
cd homelab-gitops

# Get kubeconfig (if you have cluster access)
# From the server where kubectl is configured:
export KUBECONFIG=/path/to/kubeconfig

# Verify cluster
kubectl get nodes
```

---

## Project Structure

```
homelab-gitops/
├── ONBOARDING.md          ← You are here
├── DEPRECATED.md          ← homelab-ai-platform was merged here (Apr-May 2026)
├── apps/
│   └── prod/
│       ├── ai-platform/   ← LiteLLM, Open-WebUI, Qdrant
│       └── [other apps]
├── monitoring/
│   └── prod/              ← Prometheus, Loki, Grafana, Alertmanager
├── helm/
│   ├── litellm/           ← LLM proxy/router
│   ├── qdrant/            ← Vector database
│   └── [other charts]
└── clusters/
    └── prod/
        └── flux-system/   ← Flux bootstrap & kustomizations
```

---

## Services & Access

### AI Platform Services

**LiteLLM** (LLM Proxy Router)
- **What it does**: Routes requests to Ollama, manages API keys, provides unified LLM interface
- **Pod**: `litellm-*` in `ai-platform` namespace
- **Port**: 4000 (internal), 30800 (NodePort external)
- **Health Check**: `curl -H "Authorization: Bearer <MASTER_KEY>" http://litellm.ai-platform:4000/models`
- **Models Configured**: mistral, llama2 (routes to Ollama at 10.0.0.113:11434)
- **Auth**: Requires `LITELLM_MASTER_KEY` (stored in `litellm-secrets` K8s secret)

**Open-WebUI** (Web Interface)
- **What it does**: Browser-based interface for interacting with LLMs
- **Pod**: `open-webui-*` in `ai-platform` namespace
- **Port**: 3000 (internal), 30080 (NodePort external)
- **Access**: `http://open-webui.homelab.local:30080/` (or use IP:30080)
- **Connects to**: LiteLLM backend

**Qdrant** (Vector Database)
- **What it does**: Stores embeddings for RAG (Retrieval Augmented Generation)
- **Pod**: `qdrant-*` in `ai-platform` namespace
- **Ports**: 6333 (HTTP), 6334 (gRPC)
- **Storage**: 10Gi PVC via TrueNAS iSCSI
- **Health Check**: TCP probe on port 6333 (no auth required)
- **Access**: `http://qdrant.ai-platform:6333` (internal)

### Monitoring Stack

**Grafana** (Dashboards & Visualization)
- **Port**: 30300 (NodePort)
- **Access**: `http://grafana.homelab.local:30300/`
- **Datasources**: Prometheus (primary), Loki (logs)

**Prometheus** (Metrics Scraper)
- **Port**: 9090 (internal)
- **Storage**: 15Gi PVC via TrueNAS iSCSI
- **Retention**: Configured in HelmRelease

**Loki** (Log Aggregator)
- **Port**: 3100 (internal ClusterIP)
- **Storage**: 20Gi PVC via TrueNAS iSCSI
- **Promtail**: DaemonSet on all nodes scraping container logs

**Alertmanager**
- **Port**: 9093 (internal)
- **Config**: Managed via kube-prometheus-stack

---

## Infrastructure Details

### Cluster

| Component | Details |
|-----------|---------|
| **Nodes** | 6 total: 3 control plane (cp1-3), 3 workers (wk1, wk2, wk3) |
| **K8s Version** | v1.31.3 |
| **CNI** | Cilium with L2 announcements |
| **Control Plane VIP** | 10.0.0.100 (managed by Cilium) |
| **LoadBalancer Pool** | 10.0.0.200-215 |

### Storage

| Name | Type | Size | Backend |
|------|------|------|---------|
| qdrant-pvc | PVC | 10Gi | TrueNAS iSCSI |
| prometheus DB | PVC | 15Gi | TrueNAS iSCSI |
| loki-stack | PVC | 20Gi | TrueNAS iSCSI |
| grafana | PVC | 2Gi | TrueNAS iSCSI |

**Storage Backend**
- **NAS**: TrueNAS at 10.0.0.108 (port 3260 for iSCSI)
- **CSI Driver**: democratic-csi
- **Dataset**: tank/k8s-iscsi/volumes
- **StorageClass**: `truenas-iscsi`

### Network

- **Bridge**: br0 (10.0.0.0/24)
- **Node IPs**: 10.0.0.101-106, 10.0.0.110-111
- **Cluster CIDR**: 10.244.0.0/16 (pods)
- **Service CIDR**: 10.96.0.0/12 (services)

---

## Common Commands

### Check Cluster Health

```bash
# All nodes
kubectl get nodes -o wide

# All pods (summary)
kubectl get pods -A

# AI platform services
kubectl get pods -n ai-platform
kubectl get svc -n ai-platform

# Monitoring
kubectl get pods -n monitoring

# HelmReleases status
kubectl get helmrelease -A

# Flux status
flux check
flux get all -A
```

### Access Services

```bash
# LiteLLM models
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl -H "Authorization: Bearer <KEY>" http://litellm.ai-platform:4000/models

# Qdrant health
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl http://qdrant.ai-platform:6333/health

# Port forward to local machine
kubectl port-forward -n ai-platform svc/grafana 30300:80
kubectl port-forward -n ai-platform svc/litellm 4000:4000
```

### View Logs

```bash
# LiteLLM
kubectl logs -n ai-platform -l app=litellm -f

# Qdrant
kubectl logs -n ai-platform -l app=qdrant -f

# Open-WebUI
kubectl logs -n ai-platform -l app=open-webui -f

# Flux controller
kubectl logs -n flux-system -l app=helm-controller -f
```

### Troubleshooting

```bash
# Describe failing pod
kubectl describe pod -n ai-platform <pod-name>

# Get events
kubectl get events -n ai-platform --sort-by='.lastTimestamp'

# Check HelmRelease status in detail
kubectl describe helmrelease -n ai-platform litellm

# Reconcile Flux
flux reconcile source git homelab-gitops -n ai-platform
flux reconcile helmrelease litellm -n ai-platform
```

---

## Recent Fixes (May 5, 2026)

### What Was Fixed

Repository consolidation completed. **homelab-ai-platform** was merged into **homelab-gitops**. All services recovered from probe/config issues:

### Qdrant Fix
- **Issue**: Health probe returning 404, pod in CrashLoopBackOff
- **Root Cause**: Probe config mismatch + storage class default wrong
- **Fix**: Updated `helm/qdrant/values.yaml` with TCP socket probes and truenas-iscsi storage class
- **Commit**: `6968219`

### LiteLLM Fix
- **Issue**: Pod crashing with "Model list not initialized"
- **Root Causes**: 
  1. ConfigMap template used wrong key (config.models vs config.model_list)
  2. Startup command invalid for image
- **Fixes**:
  - Commit `eaeebdc`: Fixed configmap template to use model_list
  - Commit `2b53382`: Fixed startup command
  - Commit `394644b`: Use image entrypoint instead of explicit command
- **Result**: Pod now healthy, config loading properly

### All Commits

```
394644b - Fix: LiteLLM deployment - remove explicit command, use image entrypoint
2b53382 - Fix: LiteLLM startup command - use 'litellm proxy' instead of python -m
eaeebdc - Fix: LiteLLM configmap template - use model_list instead of models
6968219 - Fix: Qdrant defaults - use truenas-iscsi and add TCP socket probes
```

---

## Important Credentials & IPs

| Item | Value | Notes |
|------|-------|-------|
| **TrueNAS IP** | 10.0.0.108 | iSCSI backend for storage |
| **TrueNAS Root Password** | Cork2715* | For storage config |
| **Cluster Endpoint** | 10.0.0.100:6443 | Control plane VIP |
| **LiteLLM Master Key** | (in K8s secret) | `litellm-secrets` in ai-platform ns |
| **Ollama Server** | 10.0.0.113:11434 | External LLM provider |

**To get LiteLLM Master Key:**
```bash
kubectl get secret -n ai-platform litellm-secrets -o jsonpath='{.data.master-key}' | base64 -d
```

---

## Working Across Workstations

### Setup on a New Device

1. **Clone the repos**
   ```bash
   git clone ssh://git@gitlab.com/pybashinf-group/homelab-gitops.git
   git clone ssh://git@gitlab.com/pybashinf-group/homelab-infrastructure.git
   git clone ssh://git@gitlab.com/pybashinf-group/homelab-gitops.git (if needed)
   ```

2. **Configure kubectl** (if you have cluster access)
   ```bash
   # Copy kubeconfig from server or generate new one
   export KUBECONFIG=/path/to/kubeconfig
   kubectl get nodes  # Verify access
   ```

3. **Set up git remotes** (already done if you cloned via SSH)
   ```bash
   cd homelab-gitops
   git remote -v  # Should show origin as gitlab.com
   ```

4. **Reference this file** whenever you need setup info
   - It's always in the repo root
   - Run `git pull` to get latest updates
   - All access info, IPs, credentials are here

### Common Workflow

```bash
# From any workstation
cd homelab-gitops

# Check current state
kubectl get pods -A

# Make changes
vim helm/litellm/values.yaml

# Test locally
helm template litellm ./helm/litellm

# Commit & push
git add helm/litellm/values.yaml
git commit -m "Update litellm config"
git push origin main

# Flux auto-syncs within minutes
kubectl get helmrelease -n ai-platform litellm
```

---

## Next Steps

- [ ] Set up Grafana dashboards for AI platform metrics
- [ ] Configure alerts for pod crashes, storage capacity
- [ ] Document API endpoints and model access patterns
- [ ] Add backup strategy for Qdrant vectors
- [ ] Monitor Ollama availability (currently external, 10.0.0.113)

---

## Help & Debugging

### Service not responding?

1. **Check pod status**
   ```bash
   kubectl get pod -n ai-platform -l app=<service>
   kubectl describe pod -n ai-platform <pod-name>
   ```

2. **Check logs**
   ```bash
   kubectl logs -n ai-platform <pod-name> --tail=50
   ```

3. **Test connectivity**
   ```bash
   kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
     curl http://<service>.ai-platform:<port>
   ```

4. **Check HelmRelease**
   ```bash
   kubectl get helmrelease -n ai-platform
   kubectl describe helmrelease -n ai-platform <release-name>
   ```

5. **Force reconcile Flux**
   ```bash
   flux reconcile helmrelease <release-name> -n ai-platform
   ```

### Storage issues?

```bash
# Check PVCs
kubectl get pvc -A

# Check storage class
kubectl get storageclass

# Check CSI driver
kubectl get pods -n kube-system | grep csi
kubectl logs -n kube-system -l app=csi-driver-democratic-csi -f
```

### Network issues?

```bash
# Check Cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl exec -it -n kube-system <cilium-pod> -- cilium status

# Check service endpoints
kubectl get endpoints -n ai-platform
```

---

## Related Documentation

- **Cluster Bootstrap**: See `homelab-infrastructure/README.md`
- **Terraform**: `homelab-infrastructure/terraform/`
- **Ansible Playbooks**: `homelab-infrastructure/ansible/`
- **Architecture**: `homelab-infrastructure/IMPLEMENTATION_GUIDE.md`

---

**Last verified**: May 5, 2026  
**Status**: All services operational ✅  
**Maintainers**: Homelab team
