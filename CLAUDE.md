# OneK8s - working notes for Claude sessions

OneK8s is an AKS platform design (https://onek8s.github.io, repo `onek8s/onek8s.github.io`) and its
implementation in the `onek8s` GitHub organisation. This file is the shared memory of earlier
sessions: what is deployed, how to operate it, and decisions already made. Keep it current when
something here changes.

## Repositories

| Repo | Role |
|---|---|
| `onek8s.github.io` | The design (docs/01-21, requirements.md, open-questions.md). Code follows it; change it when a decision changes it. |
| `aks-terraform` (this one) | The clusters (root module, vendored AVM AKS module in `modules/avm-managedcluster`) and what an environment's clusters share (`shared/`: cell VNets + NSGs, platform and zone Key Vaults, private DNS, Traffic Manager, ACR). All deployment and status workflows live here. |
| `aks-fluxcd-platform` | What Flux deploys into every cluster: isolation zones (Traefik, ESO, Cilium), NAP NodePools, external-dns, tenants. `clusters/<cluster>/` per cluster. |
| `aks-fluxcd-example` | An application team's repo (namespace `ext-fi-example`, app aks-hello). |
| `azure-landing-zone` | Build tenant, ALZ, hub, AKS policy assignments. No AKS clusters any more (the old `stacks/aks-stateless-cell` was removed). |
| `aks-hello` | The sample app image (amd64 only). |
| `aks-ai-agents` | Day-2 AI agents (phase 2). |

## How to operate (no local cloud credentials)

The session has no Azure or kubeconfig credentials. Everything runs through GitHub Actions in
`aks-terraform`, dispatched with the GitHub MCP tool (`actions_run_trigger`, `run_workflow`) and read
back through the GitHub API (`curl https://api.github.com/repos/onek8s/...` works unauthenticated for
reads; job logs via `get_job_logs`).

| Workflow | Use |
|---|---|
| `deploy.yml` (Deploy) | `stack`: `dev-shared` (apply first) / `dev-stateless-az1` / `dev-stateless-az2` / `dev-stateful`; `action`: plan / apply / destroy; `allow_empty_state: true` for a first build after a destroy. dev-shared is never destroyed from here. |
| `cluster-status.yml` | Read-only status of one cluster: nodes, pods, Flux, DNS, vCPU quota. `node_iptables` option for eBPF debugging. |
| `isolation-tests.yml` | Requirement tests on one cell: cluster settings, zone baseline denies, FQDN egress, external HTTPS (cell name and Traffic Manager name). Must pass after any network/zone change. |
| `renew-certificate.yml` | Let's Encrypt wildcards into the platform vault (5 certs, matrix, max-parallel 1). |
| `flux-webhooks.yml` | (Re)registers GitHub webhooks to the clusters' Flux receivers - run after a cluster is rebuilt. |
| `vcpu-quota.yml` | Raises the subscription's compute quotas via the Quota REST API, signed in as the org secret `AZURE_OWNER` (owner SPN JSON). |
| `pr.yml` | CI: fmt, validate, `terraform test`. |

Local checks before a push: `terraform fmt -check -recursive`, `terraform test` in the root (178+
tests) and in `shared/` (24+), `kustomize build` for changed fleet directories. The fleet and example
repos' CI does not run on GitHub, so validate them locally.

Workflow: branch, PR, squash-merge (the user wants changes deployed and merged without asking each
time), then dispatch the workflow on `main` and check the result. Order for network changes:
merge + apply `dev-shared` before merging a fleet change that depends on it.

## Current state of dev (2026-10-13)

- `aks-dev-stateless-az1`: running. Rebuilt 2026-10-12 so eBPF host routing is on from creation.
- `aks-dev-stateless-az2`: **destroyed on purpose** (the config is proven; no need to keep it
  running). Its tfvars, fleet directory and Traffic Manager endpoint stay; Traffic Manager just sees
  the endpoint as down. To bring it back: Deploy `dev-stateless-az2` apply with `allow_empty_state`,
  then Flux webhooks, Cluster status and Isolation tests on it. Do not rebuild it unless asked.
- `dev-stateful`: defined (`envs/dev-stateful.tfvars`), never deployed (only with an approved exception).
- Region swedencentral. Quotas: regional vCPUs 52, Dpsv6 24, Dalv6 16, low-priority (spot) 3 - a
  raise to 8 was throttled by Azure ("retry after 3600 s", each retry restarts the wait); re-run
  `vcpu-quota.yml` once at most per hour.
- A cell with no applications is one 4-vCPU system node (Standard_D4als_v6). Each zone with
  application pods adds NAP nodes.

## Decisions already made (do not re-litigate)

- **Traffic Manager, not Front Door.** External zones get a public LB per zone per cell; one Traffic
  Manager profile per global hostname (e.g. `hello.ext-fi.dev.onek8s.lol`). Design uses Subnet routing
  with nested Priority profiles; the dev lab uses Weighted.
- **Public API server in dev** (authorized ranges, Entra ID only, local accounts off) - a lab
  exception the user asked for. Private API server stays the design for acc/prd.
- **Isolation zones** int-fi, int-se, ext-fi, ext-se: per cell a /24 each (nodes /25, ILB /27),
  own NSG, own Key Vault (`kv-onek8s-dev-<zone>`), own NAP AKSNodeClass + NodePools, own Traefik
  gateway and ESO (`controllerClass: <zone>`), Cilium CCNP baseline.
- **Zone nodes only for applications.** Each zone's Traefik and ESO run on the system pool (with the
  platform gateway and platform ESO), so a zone without application pods has zero nodes and its
  NodePools scale to zero. Consequence: the system subnet NSG allows 443 from Internet *and* (a
  separate rule) from VirtualNetwork.
- **Spot and architecture are the application's choice.** Per zone a spot NodePool (weight 50,
  taint `platform/capacity=spot`) and an on-demand one (weight 10): a pod that tolerates spot gets
  spot when available, else on-demand; one that does not stays on on-demand. amd64 and arm64 both
  offered; a pod pins `kubernetes.io/arch` or takes either. aks-hello is amd64 only.
- **eBPF host routing (BpfVeth) only at cluster creation**: AKS refuses to enable it on a running
  cluster ("User-installed iptables rules found"). That is why the AVM module is vendored with one
  patch (`network_profile.advanced_networking.performance.acceleration_mode`), see
  `modules/avm-managedcluster/VENDORED.md`. An upstream feature request was drafted on PR #65.
- **CMK**: per cluster `key-<cluster>-kms` and `key-<cluster>-disk` in `kv-onek8s-dev-platform`
  (purge protection), DES `des-<cluster>`, encryption at host. Azure Linux, SSH off, system pool
  tainted `CriticalAddonsOnly`, Kubernetes 1.36, auto-upgrade none, Free tier.
- **Secrets only through ESO**; vault shares by ABAC prefix `<namespace>--`; gateway certs
  `<zone>-gateway--wildcard` and `platform-gateway--wildcard`.
- Skipped for now by the user: custom Azure Policy definitions, automated requirement tests beyond
  the isolation-tests workflow.

## Lessons learned (gotchas)

- **Cilium DNS rules must cover the pod's search suffixes**, including the node's Azure suffix
  `<id>.<x>.internal.cloudapp.net`; a refused expansion makes musl (Alpine) stop resolving, so
  allowed FQDNs fail. The zone baseline allows `cluster.local` and `internal.cloudapp.net` patterns.
- **An NSG rule takes one service tag**; `Internet` + `VirtualNetwork` in one rule is a 400.
- **Quota errors** show up as `ErrCode_InsufficientVCPUQuota` on the cluster PUT; check the
  "vCPU quota" step of Cluster status.
- `az vm list-usage` values are strings (JMESPath `currentValue != '0'`, not `> 0`).
- The `az quota` CLI extension's `--limit-object` syntax is broken; use `az rest` against
  `Microsoft.Quota/quotas/<name>?api-version=2023-02-01`.
- Renew Certificate matrix jobs need `max-parallel: 1` and per-cert concurrency groups; DNS-01 can
  fail once - re-run.
- GitHub OIDC to Azure has transient 503/504s; re-dispatch.
- `kubectl debug` has no `-o`; parse the pod name from its output.
- Waiting: use `/tmp/claude-0/bin/waitrun.sh <repo> <run_id>...` if it exists (polls the runs API),
  or a loop over the runs API; long foreground `sleep` is blocked in the sandbox.
