# homelab-gitops

Flux CD v2 GitOps repository for a 6-node bare-metal Kubernetes homelab running a private AI platform. All cluster state is declared here — infrastructure, monitoring, and application workloads reconcile automatically on every commit.

## Stack

```
CLUSTER
├─ 3 control planes (HA etcd quorum, keepalived VIP)
└─ 3 workers (1 physical + 2 QEMU VMs)

NETWORKING
└─ Cilium 1.16 (eBPF CNI, VXLAN, L2 LoadBalancer — replaces Flannel + MetalLB)

GITOPS
└─ Flux CD v2 — SOPS + age encrypted secrets, 3-layer kustomization

STORAGE
└─ Democratic CSI → TrueNAS iSCSI (dynamic PVC provisioning)

AI PLATFORM
├─ LiteLLM      — OpenAI-compatible API gateway
├─ Open-WebUI   — Chat interface
├─ Qdrant       — Vector database (RAG)
└─ Ollama       — GPU inference (external host, GTX 1070)

MONITORING
├─ kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
├─ Loki + Promtail
└─ ntfy (push notifications)

SECURITY
├─ Falco (runtime threat detection, DaemonSet)
├─ cert-manager (internal CA, TLS for all ingresses)
├─ Network policies per namespace (default-deny)
└─ SSH hardening (Ansible)

DNS
├─ Technitium (internal zone)
└─ Pi-hole (LAN ad-blocking + conditional forwarding)

BACKUP
└─ Velero → Backblaze B2 (daily schedule)
```

## Repository Structure

```
homelab-gitops/
├── clusters/prod/flux-system/     # Flux bootstrap — entry point
│   ├── gotk-components.yaml       # Flux controllers
│   ├── gotk-sync.yaml             # GitRepository + root Kustomization
│   ├── infrastructure.yaml        # Kustomization ref → infrastructure/prod
│   ├── monitoring.yaml            # Kustomization ref → monitoring/prod
│   └── apps.yaml                  # Kustomization ref → apps/prod
│
├── infrastructure/prod/           # CNI, ingress, DNS, storage, security
│   ├── cilium/                    # HelmRelease + L2 pool + announcement policy
│   ├── cert-manager/              # HelmRelease + ClusterIssuer
│   ├── nginx-ingress/             # HelmRelease
│   ├── technitium/                # Deployment + PVC + network policies
│   ├── pihole/                    # Deployment + ConfigMap + SOPS secret
│   ├── velero/                    # HelmRelease + daily backup schedule
│   └── falco/                     # HelmRelease
│
├── monitoring/prod/               # Prometheus stack, Loki, ntfy
│   ├── kube-prometheus-stack-helmrelease.yaml
│   ├── loki-helmrelease.yaml
│   └── ntfy/
│
├── apps/prod/                     # AI platform, Vaultwarden
│   ├── ai-platform/               # LiteLLM, Open-WebUI, Qdrant, Dashy
│   └── vaultwarden/
│
├── helm/                          # Local Helm charts (LiteLLM, Open-WebUI, Qdrant)
│   ├── litellm/
│   ├── open-webui/
│   └── qdrant/
│
└── ansible/                       # Node bootstrap and maintenance playbooks
    ├── inventory.yaml
    └── playbooks/
        ├── cni-cleanup.yaml       # Serial Flannel → Cilium migration
        ├── ssh-hardening.yaml
        └── etcd-metrics-expose.yaml
```

## Flux Dependency Order

```
infrastructure  ──▶  monitoring  ──▶  apps
     └── Cilium, cert-manager,        └── AI platform, Vaultwarden
         nginx-ingress, DNS,
         storage, security
```

`apps` depends on `infrastructure` (ingress, TLS, storage must exist first). `monitoring` also depends on `infrastructure`. Race conditions on first bootstrap are eliminated.

## Secret Management

Secrets are encrypted in git with [SOPS](https://github.com/getsops/sops) + [age](https://age-encryption.org/). Flux decrypts at reconcile time using an age private key stored as a cluster secret.

```bash
# Encrypt a secret before committing
sops --encrypt --age <age-public-key> secret.yaml > secret.sops.yaml
```

`.sops.yaml` targets only `data`/`stringData` fields — metadata stays in plaintext and diffs remain readable.

## Cilium L2 LoadBalancer

Replaces MetalLB entirely. Services get stable LAN-routable IPs via ARP announcements on physical interfaces.

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-pool
spec:
  cidrs:
    - cidr: 192.168.1.200/28
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: homelab-l2
spec:
  interfaces:
    - ^enp.*
  loadBalancerIPs: true
```

## CNI Migration (Flannel → Cilium)

The `ansible/playbooks/cni-cleanup.yaml` playbook migrates nodes one at a time (`serial: 1`). For each node it drains, removes Flannel CNI config + `flannel.1` interface + `cni0` bridge, then uncordons so Cilium takes over. Parallel migration causes routing loops — serial is required.

## Related Posts

- [HA Kubernetes on Ubuntu — cluster bootstrap](https://t-12.io/solutions/01-ubuntu-ha-kubernetes-gpu-ai/)
- [Cilium, Flux CD, and Democratic CSI](https://t-12.io/solutions/multi-cluster-setup-guide/)
- [Private AI Platform](https://t-12.io/solutions/private-ai-platform/)

## Related Repos

- [sre-cli](https://github.com/t12-pybash/sre-cli) — SRE CLI and MCP server for operating this cluster
