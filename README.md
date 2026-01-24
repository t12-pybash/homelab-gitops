# Homelab GitOps (Flux CD)

Flux CD v2 repository for managing all Kubernetes applications, infrastructure, and monitoring stack in the homelab Talos cluster.

## Quick Start

```bash
# This repo is auto-deployed by Terraform flux_bootstrap_git
# Once Flux is installed, it watches this repo and applies changes every 1-5 minutes

# Manual sync (if needed)
flux reconcile kustomization flux-system --with-source

# Watch reconciliation
flux get kustomizations --watch
flux get helmreleases -A --watch
```

## Structure

```
clusters/prod/
├── flux-system/              # Flux bootstrap entry points
│   ├── gotk-components.yaml  # Flux controller manifests
│   ├── gotk-sync.yaml        # GitRepository + root Kustomization
│   ├── kustomization.yaml    # Root config (references other layers)
│   ├── infrastructure.yaml    # Kustomization: Cilium, Democratic CSI, cert-manager
│   ├── apps.yaml             # Kustomization: Nextcloud, GitLab Runner
│   └── monitoring.yaml       # Kustomization: Prometheus, Grafana, Loki

infrastructure/prod/
├── cilium/                   # CNI + L2 announcements + Gateway API
│   ├── helmrelease.yaml
│   ├── l2-pool.yaml          # LoadBalancer IP pool
│   ├── gatewayclass.yaml     # Gateway API class
│   └── kustomization.yaml
├── democratic-csi/           # Storage provisioner (TrueNAS)
│   ├── helmrelease.yaml
│   ├── secret.yaml           # SOPS-encrypted TrueNAS credentials
│   ├── storageclass.yaml     # truenas-iscsi storage class
│   └── kustomization.yaml
├── cert-manager/             # TLS certificate management
│   ├── helmrelease.yaml
│   ├── clusterissuer.yaml    # Let's Encrypt
│   └── kustomization.yaml
└── kustomization.yaml        # Combines all infra components

apps/prod/
├── nextcloud/                # Nextcloud deployment
│   ├── helmrelease.yaml      # Helm chart deployment
│   ├── pvc.yaml              # Persistent volume (500GB)
│   ├── httproute.yaml        # Gateway API routing
│   └── kustomization.yaml
├── gitlab-runner/            # GitLab Runner
│   ├── helmrelease.yaml
│   ├── secret.yaml           # SOPS-encrypted runner token
│   └── kustomization.yaml
├── linkding/                 # Bookmarking app
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── pvc.yaml
│   ├── httproute.yaml
│   └── kustomization.yaml
└── kustomization.yaml        # Combines all apps

monitoring/prod/
├── controllers/
│   └── kube-prometheus-stack/
│       ├── helmrelease.yaml  # Prometheus, Grafana, AlertManager
│       ├── namespace.yaml
│       └── kustomization.yaml
├── loki/
│   ├── helmrelease.yaml      # Log aggregation
│   ├── pvc.yaml
│   └── kustomization.yaml
├── promtail/
│   ├── helmrelease.yaml      # Log shipper
│   └── kustomization.yaml
└── configs/
    ├── prometheus-rules/     # Custom PrometheusRules
    ├── grafana-dashboards/   # Dashboard ConfigMaps
    └── kustomization.yaml

.sops.yaml                    # SOPS encryption config (public key only)
renovate.json                 # Renovate bot auto-update config
.gitignore                    # Exclude sensitive files
```

## Key Concepts

### Kustomization Hierarchy
```
Root Kustomization (clusters/prod/flux-system/kustomization.yaml)
├── infrastructure.yaml
│   ├── cilium
│   ├── democratic-csi
│   └── cert-manager
├── apps.yaml
│   ├── nextcloud
│   ├── gitlab-runner
│   └── linkding
└── monitoring.yaml
    ├── kube-prometheus-stack
    ├── loki
    └── promtail
```

Each layer reconciles in order with health checks:
1. **Infrastructure**: Wait for Cilium + Democratic CSI ready
2. **Apps**: Wait for storage ready
3. **Monitoring**: Wait for all apps ready

### Gateway API (Modern Ingress)

Instead of Ingress resources:
```yaml
# clusters/prod/flux-system/infrastructure.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller

# apps/prod/nextcloud/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nextcloud
spec:
  parentRefs:
    - name: homelab-gateway
  hostnames:
    - nextcloud.local
  rules:
    - backendRefs:
        - name: nextcloud
          port: 80
```

### SOPS Encryption

Secrets are encrypted in git, decrypted by Flux at deploy time:

```bash
# View encrypted secret
cat infrastructure/prod/democratic-csi/secret.yaml

# Edit encrypted secret (SOPS auto-encrypts on save)
sops infrastructure/prod/democratic-csi/secret.yaml

# Example encrypted section
apiVersion: v1
kind: Secret
metadata:
  name: democratic-csi
type: Opaque
data:
  driver-config.yaml: ENC[AES256_GCM,data:xxxxx,iv:yyyy,tag:zzzz,type:str]
sops:
  kms: []
  gcp_kms: []
  azure_kv: []
  hc_vault: []
  age:
    - recipient: age1qtfywhjgy78pwld6dwfy60lkxcsfquf3zljqmftpk3kfg6cjryrsdy4nwc
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

### HelmRelease Pattern

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: nextcloud
  namespace: nextcloud
spec:
  interval: 30m
  chart:
    spec:
      chart: nextcloud
      version: ">=4.0.0 <5.0.0"  # Version constraint
      sourceRef:
        kind: HelmRepository
        name: nextcloud
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    replicas: 1
    persistence:
      enabled: true
      storageClass: truenas-iscsi
      size: 500Gi
    service:
      type: LoadBalancer
      loadBalancerIP: 10.0.0.200
```

## Configuration

### Network

```
Cluster Subnet: 10.0.0.0/24
Gateway: 10.0.0.1

Services (LoadBalancer IPs):
- Nextcloud: 10.0.0.200
- Grafana: 10.0.0.201
- Prometheus: 10.0.0.202
- Available: 10.0.0.203-215
```

### Storage

```
Provider: TrueNAS iSCSI
Host: 10.0.0.108:3260
Dataset: tank/k8s-iscsi/volumes
StorageClass: truenas-iscsi

PVCs:
- Nextcloud: 500Gi
- Prometheus: 50Gi
- Grafana: 10Gi
- Loki: 10Gi
```

### Monitoring

```
Prometheus:
- Retention: 30 days
- Scrape interval: 30s
- Storage: 50Gi PVC

Grafana:
- Admin user: admin
- Password: (set in secret)
- Storage: 10Gi PVC
- Dashboards: Auto-provisioned

Loki:
- Retention: 30 days
- Log levels: All
- Storage: 10Gi PVC
```

## Deployment

### Automatic (via Terraform)

When Terraform runs `flux_bootstrap_git`:
1. Flux controllers installed in `flux-system` namespace
2. GitRepository created pointing to this repo
3. Root Kustomization created watching `clusters/prod/`
4. Flux reconciles every 1 minute
5. All layers auto-deploy in order

### Manual (if needed)

```bash
# Bootstrap Flux manually
flux bootstrap git \
  --url=ssh://git@gitlab.com/pybashinf-group/homelab-gitops.git \
  --branch=main \
  --path=clusters/prod

# Force reconciliation
flux reconcile kustomization flux-system --with-source
flux reconcile source git flux-system
```

## Monitoring Flux

```bash
# Check Flux status
flux check

# Watch Kustomizations
flux get kustomizations --watch

# Watch HelmReleases
flux get helmreleases -A --watch

# Check GitRepository sync
flux get sources git

# View specific HelmRelease status
kubectl describe helmrelease nextcloud -n nextcloud

# Tail controller logs
kubectl logs -f -n flux-system -l app=kustomize-controller
kubectl logs -f -n flux-system -l app=helm-controller
```

## Troubleshooting

### HelmRelease not deploying

```bash
# Check status
kubectl describe helmrelease <name> -n <namespace>

# Check chart availability
kubectl describe source helmrepo prometheus-community -n flux-system

# View Helm controller logs
kubectl logs -f -n flux-system -l app=helm-controller

# Check values applied
helm get values <release> -n <namespace>
```

### Kustomization failing

```bash
# Check status
kubectl describe kustomization infrastructure -n flux-system

# Check what's being reconciled
kubectl get kustomization -A

# Validate YAML
kustomize build infrastructure/prod

# Manual apply (debugging)
kustomize build infrastructure/prod | kubectl apply -f -
```

### Storage not provisioning

```bash
# Check StorageClass
kubectl get storageclass

# Check CSI driver
kubectl get pods -n democratic-csi

# Check PVC status
kubectl describe pvc <pvc-name> -n <namespace>

# Check TrueNAS connectivity
kubectl exec -it democratic-csi-iscsi-controller-xxx -n democratic-csi -- \
  iscsiadm -m discovery -t sendtargets -p 10.0.0.108:3260
```

### Gateway API not working

```bash
# Check GatewayClass
kubectl get gatewayclass

# Check Gateway status
kubectl describe gateway homelab-gateway -n kube-system

# Check HTTPRoute
kubectl describe httproute <name> -n <namespace>

# Check Cilium Gateway controller
kubectl logs -f -n kube-system -l k8s-app=cilium | grep -i gateway
```

## Updating

### Container image updates (Renovate)

Renovate bot automatically:
1. Scans HelmReleases for new versions
2. Creates merge requests with updates
3. Auto-merges if tests pass (configurable)

```bash
# Manual trigger
flux create image repository podinfo \
  --image=ghcr.io/stefanprodan/podinfo \
  --interval=1m \
  --export > infrastructure/prod/renovate-podinfo.yaml
```

### Helm chart updates

Update chart version constraints in HelmReleases:
```yaml
chart:
  spec:
    version: ">=4.0.0 <5.0.0"  # Change upper version
```

Flux automatically fetches and deploys new versions.

## Security

### Secret Encryption

All sensitive data encrypted with SOPS + age:
- Democratic CSI credentials
- GitLab Runner token
- Grafana admin password

Encryption key stored locally at `~/.config/sops/age/keys.txt`

### Network Policies

Managed by Cilium, enforced by default:
- Deny all ingress (allow needed only)
- Deny all egress (allow needed only)
- Exceptions per namespace/pod

### RBAC

All Flux resources have minimal RBAC:
- Flux service account: Limited to `flux-system` namespace
- HelmRelease service accounts: Limited to app namespaces
- No cluster-admin used

## Scaling

### Add new app

1. Create `apps/prod/<app>/` directory
2. Create `helmrelease.yaml` (or deployment.yaml)
3. Create `kustomization.yaml` referencing the app
4. Update `apps/prod/kustomization.yaml` to include new dir
5. Push to git, Flux auto-deploys

### Add monitoring for new app

1. Create ServiceMonitor in monitoring layer
2. Add Grafana dashboard ConfigMap
3. Add PrometheusRule if needed
4. Flux auto-discovers ServiceMonitor

## Documentation

- Checkpoint: `./.checkpoint.md`
- Terraform: `/home/py/homelab-infrastructure/README.md`
- Plan: `/home/py/.claude/plans/snug-nibbling-shell.md`

## Resources

- [Flux Documentation](https://fluxcd.io/docs/)
- [Cilium Gateway API](https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/)
- [Kustomize](https://kustomize.io/)
- [SOPS Documentation](https://github.com/getsops/sops)
