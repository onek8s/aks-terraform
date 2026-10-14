# OneK8s - working notes for Claude sessions

OneK8s is an AKS platform design (https://onek8s.github.io, repo `onek8s/onek8s.github.io`) and its
implementation in the `onek8s` GitHub organisation. This file is the shared memory of earlier
sessions: what is deployed, how to operate it, and decisions already made. Keep it current when
something here changes.

## Repositories

| Repo | Role |
|---|---|
| `onek8s.github.io` | The design (docs/01-21, requirements.md, open-questions.md). Code follows it; change it when a decision changes it. |
| `aks-terraform` (this one) | The clusters (root module on the registry AVM AKS module 0.8.5) and what an environment's clusters share (`shared/`: cell VNets + NSGs, platform and zone Key Vaults, private DNS, Traffic Manager, ACR). All deployment and status workflows live here. |
| `aks-fluxcd-platform` | What Flux deploys into every cluster: isolation zones (Gateway, ESO, Cilium), NAP NodePools, external-dns, tenants. `clusters/<cluster>/` per cluster. |
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
| `deploy.yml` (Deploy) | `stack`: `dev-shared` (apply first) / `dev-ext-stateless-az1` / `dev-ext-stateless-az2` / `dev-ext-stateful`; `action`: plan / apply / destroy; `allow_empty_state: true` for a first build after a destroy. dev-shared is never destroyed from here. |
| `cluster-status.yml` | Read-only status of one cluster: nodes, pods, Flux, DNS, vCPU quota, every policy constraint's violations per object, and who wrote each Secret of the zone namespaces (managed fields). `node_iptables` option for eBPF debugging. Read it before promoting a policy to deny. |
| `isolation-tests.yml` | The negative requirement and isolation tests of design section 17 on one cell, each tagged with its R-number (summary table): cluster settings, `--admin` refused, platform policies present, probe placed by the mutations alone, cross-zone / cross-namespace / node / IMDS / every vault blocked, FQDN egress, forbidden manifests as server-side dry runs (PASS = refused, AUDIT = rule still in audit), external HTTPS, supply chain (ACR admin/anonymous off, kubelet only AcrPull, Ratify healthy and federated, every ACR image and running app image signed, the policy reports the unsigned probe, Flux webhook refuses a bad signature), Resource Graph public endpoints and local auth against `tests/isolation/allowed-public-endpoints.yaml`, Key Vault ABAC with a token for the namespace's own `key-vault` identity (own secret 200, others 403) and every role of the application identities (`check-key-vault-roles.py`), R6 namespace access (`check-namespace-access.py`: RoleBindings match the tfvars' `groups`, each role's rights by impersonating a group member and signed in as a tester app from `tests/isolation/namespace-access-testers.yaml`), R11 cell settings (AZ, NAP, VPA), R13 sync (Kubernetes version of the tfvars, Flux at the head of Git, `check-cells-in-sync.py`), R15 certificates vault -> Secret -> listener -> served, R16 every zone complete, R2 one exposure per cluster and subscription. **Only when the user asks for it** (2026-10-14: runs take 10-30 min and slowed progress) - no Deploy stage, no schedule; do not dispatch it on your own after a change. |
| `cis-benchmark.yml` (CIS benchmark) | CIS AKS Benchmark of one cluster: kube-bench (`aks-1.8`, Job per node in kube-system, section 3), Kubescape `cis-aks-t1.8.0` from the runner (section 4), the cluster's Azure settings (sections 2 and 5). `tests/cis/report.py` gives one row per recommendation and a score; a failure not in `tests/cis/accepted.yaml` (with its reason) fails the run. **By hand only** (2026-10-14, the user's choice to speed up testing: no schedule, no Deploy stage). |
| `sign-images.yml` (Sign images) | Notation-signs every image in the ACR with `image-signing` in the platform vault (azure-kv plugin, deploy identity); skips what already verifies. Runs after every Deploy apply of dev-shared, and by hand. |
| `renew-certificate.yml` | Let's Encrypt wildcards into the platform vault (5 certs, matrix, max-parallel 1). |
| `flux-webhooks.yml` | (Re)registers GitHub webhooks to the clusters' Flux receivers - run after a cluster is rebuilt. |
| `vcpu-quota.yml` | Raises the subscription's compute quotas via the Quota REST API, signed in as the org secret `AZURE_OWNER` (owner SPN JSON). `gpu` input: `StandardNCadsH100v5Family` (40 per GPU node, default 0 = leave). |
| `store-secret.yml` (Store secret) | Puts a secret into `kv-onek8s-dev-platform` without its value in Git, inputs or logs: `public-key` prints the vault RSA key `secret-transport`'s public key; encrypt the value with it (RSA-OAEP-256, `openssl pkeyutl`, ≤ 446 bytes) and run `store` with the name and base64 ciphertext. Use it for any credential the user hands over in chat. |
| `pr.yml` | CI: fmt, validate, `terraform test`. |
| `entra-test-groups.yml` (Entra test groups) | Manual, as `AZURE_OWNER`: for a `namespace` and `roles` input, groups `grp-onek8s-dev-<ns>-<role>` (default view edit admin; `platform` + `viewers` for the platform viewers) and tester apps `onek8s-dev-<ns>-<role>-tester` (members, federated with the `dev` environment's subject `repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`). Idempotent; prints the IDs for the tfvars and `tests/isolation/namespace-access-testers.yaml`. |
| `lab-admin.yml` (Lab admin) | Manual, **last resort**: runs ONE `az` (as `AZURE_OWNER`, on the dev subscription) or `gh` (with `GH_OWNER`) command; `args` split like a shell, no pipes (use `--query`/`--jq`). For special changes nothing else covers (Entra ID, Graph, org/repo settings). The run log is readable by anyone who can read the repo: never print a secret. |

**Owner credentials (lab only, last option, allowed whenever needed):** `AZURE_OWNER` - org secret, `az ad sp
create-for-rbac` JSON of an SPN that is Owner on the lab subscriptions and **Global Administrator** of the lab
tenant (so Graph works: groups, apps, role assignments); `GH_OWNER` - org secret, a GitHub admin token of the
onek8s organization (also the fallback of `flux-webhooks.yml`). Use them through `lab-admin.yml`,
`entra-test-groups.yml` or `vcpu-quota.yml`, not in routine pipelines.

Local checks before a push: `terraform fmt -check -recursive`, `terraform test` in the root (178+
tests) and in `shared/` (24+), `kustomize build` for changed fleet directories; for a policy change in
azure-landing-zone, `stacks/aks-policy/kubernetes/test.sh` (gator, download the release binary) and
`terraform test` there. The fleet and example
repos' CI does not run on GitHub, so validate them locally.

Workflow: branch, PR, squash-merge (the user wants changes deployed and merged without asking each
time), then dispatch the workflow on `main` and check the result. Verify with Cluster status (fast);
the Isolation tests and the CIS benchmark run **only when the user asks for them separately**. Order for network changes:
merge + apply `dev-shared` before merging a fleet change that depends on it.

## Current state of dev (2026-10-14)

- **Internal and external are separate subscriptions and clusters** (security's decision 2026-10-14, design D52);
  countries stay isolation zones (node pool + network + vault) inside them. dev is **external only**:
  `sub-aks-dev` plays `sub-aks-dev-ext`, `shared/envs/dev.tfvars` has `exposure = "ext"` and only ext-fi/ext-se,
  the clusters are `aks-dev-ext-*` (renamed from `aks-dev-stateless-az<N>` / `aks-dev-stateful`; stacks and fleet
  directories `dev-ext-*`). No internal subscription in the lab; an internal one would be `shared/` + the same
  cluster tfvars with `exposure = "int"` and the int zones. `exposure` validations refuse mixing (root + shared).
- `aks-dev-ext-stateless-az1`: the only running cluster (rebuilt 2026-10-14 under its new name).
- `aks-dev-ext-stateless-az2`: **destroyed on purpose** (the config is proven; no need to keep it
  running). Its tfvars, fleet directory and Traffic Manager endpoint stay; Traffic Manager just sees
  the endpoint as down. To bring it back: Deploy `dev-ext-stateless-az2` apply with `allow_empty_state`,
  then Flux webhooks and Cluster status on it (Isolation tests only if the user asks). Do not rebuild it unless asked.
- **VPA add-on off in the dev cells** (2026-10-14, lab cost exception, the user's choice): `vertical_pod_autoscaler_enabled
  = false` in the stateless tfvars (default stays true, design section 4) - its ~2.4 GiB of requests (2 recommenders,
  2 updaters, 2 admission controllers) kept a cell off one 8 GiB system node. aks-hello's `VerticalPodAutoscaler`
  (`InPlaceOrRecreate`, RequestsOnly, CPU 3m-20m, memory 64Mi-128Mi) stays in aks-fluxcd-example `apps/` but
  `stateless/` deletes it with a patch (no CRD without the add-on). Isolation tests: R11 VPA follows the tfvars,
  the VPA dry runs are AUDIT without the CRD. To bring it back: tfvars true, drop the patch, `node_count = 2`.
- **Image Integrity on** (preview, `image_integrity_enabled` in the stateless tfvars; feature
  `EnableImageIntegrityPreview` registered by Deploy). shared/ `image_signing`: self-signed cert
  `image-signing` in `kv-onek8s-dev-platform` (non-exportable key) and identity
  `id-sec-dev-shared-ratify` (AcrPull, Secrets User on that one secret), federated per cluster with
  `gatekeeper-system/ratify-admin`. Fleet `infrastructure/image-verification` configures Ratify.
  The AVM module has no input for `securityProfile.imageIntegrity`: the root module sets it with an
  `azapi_update_resource` beside the module (`image_integrity.tf`, API `aks_api_version`). Verified on az1
  2026-10-13: Ratify runs as `gatekeeper-system/ratify-admin` with the WI token, the signed aks-hello
  is not reported, the unsigned probe is. Two Notation constraints exist: ours and the landing zone's
  `Deploy-MCSB2-Monitoring` one (default exclusions); both report the platform's upstream images
  (ESO, Flux), which are not signed by the platform - expected for now.
- **Traefik serves the dev cells' Gateways again** (2026-10-14, `gateway_implementation = "traefik"`): App Routing's
  istiod requests 1 CPU / 4 GiB before the first Gateway and cannot be tuned (https://github.com/Azure/AKS/issues/5939),
  which took a second system node. Traefik's manifests live here, `gateways/traefik` (HelmRepository + HelmRelease
  chart 41.7.x, GatewayClass `traefik-<gateway>`, 443 in the pod via the safe sysctl, 2 x 25m/64Mi, pods and
  Service labelled `gateway.networking.k8s.io/gateway-name: <gateway>` like App Routing's, Cilium policy
  `gateway-traefik` for the API server), applied by one Flux configuration `traefik-<gateway>` per Gateway
  (`traefik.tf`; zones + platform). The fleet's Gateways name `${gateway_class_name}` from the settings
  `gateway_class_name_<gateway>` and add the kustomize component `gateway-implementations/${gateway_implementation}`
  (setting `gateway_implementation`): App Routing's ConfigMap `gateway` + `parametersRef` only there, because Traefik
  refuses a `parametersRef` (`Accepted: False`). Verified on az1 2026-10-14: three Gateways Programmed on
  `traefik-<gateway>`, DNS followed the new LB IPs, no Pending pods, system node at 71 % memory requests. App Routing
  (`approuting-istio`) stays a supported choice: switch the tfvars back (and `node_count = 2`); the Gateways carry
  Flux `force`, so a class change re-creates them (a few minutes without gateways).
- **CIS AKS Benchmark** (2026-10-13): first run on az1 55 % (23 of 42 automated recommendations); every
  node check passes. Improved: audit logs (`log-dev-platform` workspace in shared/, diagnostic setting
  `kube-audit-admin` + `guard` per cluster, 1 GB/day cap), Cilium policies and token-less default
  service accounts in the platform's namespaces (fleet). Accepted with reasons in `tests/cis/accepted.yaml`:
  the dev lab exceptions (public API server, Defender off), AKS's and Flux's own RBAC, ESO's Secret access,
  gateway namespaces on baseline PSS. Follow-ups in the design (section 17, "CIS benchmark").
- **GPU nodes on request** (2026-10-13, decision D42 built): per zone a NAP AKSNodeClass + NodePool
  `<zone>gpu` in the fleet - NVIDIA H100 v5 only (`NCads_v5`; the only GPU VMs with VNet encryption),
  on-demand, amd64, taint `platform/accelerator=nvidia-gpu`, AKS managed GPU stack (AKSNodeClass tag
  `EnableManagedGPUExperience`, feature `ManagedGPUExperiencePreview` registered by Deploy). A pod asks
  with `nvidia.com/gpu` + label `platform/accelerator: nvidia-gpu` (policy mutation `gpu-toleration`,
  `placement-labels` refuses either without the other). No GPU node created yet: the H100 family quota
  starts at 0 (`vcpu-quota.yml` `gpu`). A GPU node is ~7 USD/hour: **the user does not want GPU nodes
  run in the lab** - the cells' `gpu_cpu_limit: "0"` (fleet cluster-settings.yaml) keeps NAP from creating
  any, and the quota stays 0; GPU checks are dry runs only.
- **Observability up on az1** (2026-10-13): Grafana k8s-monitoring 4.5.2 via Flux (fleet
  `infrastructure/observability`, namespace `infra-observability`) as **Grafana Cloud Fleet Management**
  sets it up (user's choice, design D48): `alloy-daemon` DaemonSet (privileged, hostNetwork/PID, requests
  100m/256Mi, `system-node-critical`) takes its pipelines from Fleet Management (stack region
  prod-eu-north-0) - collection is changed in Grafana Cloud, not in Git; node-exporter, kube-state-metrics
  (namespace owner labels), Beyla k8s cache. All Running, Alloy registered, no errors. Credentials: vault
  secret `flux-system--grafana-cloud` (JSON remote-config-url/-username/-password), stored with the Store
  secret workflow. **OpenCost not running yet**: needs a Grafana token with metrics:read added to that
  secret (prometheus-query-url, prometheus-username, prometheus-read-token).
- **Cost and ownership** (2026-10-13): AKS cost analysis add-on NOT used (needs Standard tier and the
  Disk CSI driver, which the stateless cells keep off; D46). Every namespace carries labels
  `platform/team`, `platform/cost-center` and annotation `platform/contact` (`managed_namespaces.<ns>.owner`
  here; `platform` for the fleet's own); Azure Policy `namespace-ownership` **deny** (0 violations).
  shared/ `monthly_budget` (budget.tf): subscription budget 600/month, Owners told at 80 %/100 % actual and
  100 % forecast. CIS on az1 56 % (23 of 41); the Grafana collectors' findings (4.1.2, 4.1.6, 4.2.8,
  4.5.1) are accepted by D48.
- **Namespace access groups** (2026-10-14, D49): `managed_namespaces.<ns>.groups = { view, edit, admin }` (Entra ID
  group object IDs, each optional). Per namespace with groups a cluster-scope Flux configuration `<ns>-access`
  (flux-system) with a Kustomization per role applying the fleet's `infrastructure/namespace-access/<role>`
  (RoleBinding `platform-<role>` -> ClusterRole `<role>`, subject Group `<object ID>`) - one configuration per
  namespace because **Azure refuses two Kustomizations of one Flux configuration on the same path** - plus Azure
  role `Azure Kubernetes Service Namespace User` on the namespace for each group.
  Kubernetes RBAC, so it works beside Azure RBAC. The older `access` list (Azure RBAC roles) still exists.
  On the namespace's Key Vault share the same groups get the matching rights: `admin` Key Vault Secrets
  Officer, `edit` the custom role `OneK8s Key Vault Secrets Editor (rg-aks-dev)` (D51, 2026-10-14: `setSecret`,
  `update`, `readMetadata` - writes and updates, never reads a value, no delete; defined and assignable at the
  resource group; root module's own-vault variant `Key Vault Secrets Editor (<cluster>)`), both under the
  `<ns>--` ABAC write condition, `view` nothing - granted by shared/
  (`key_vault_namespaces.<ns>.groups`, same IDs; the isolation test checks they agree) or by the root module
  for a cluster's own vault.
- **Soft multi-tenancy** (2026-10-14, design section 6/7, D50): the ABAC conditions gate `readMetadata` too, so
  **no namespace identity or group can list a vault** (Key Vault evaluates a list against the whole collection,
  which has no name): everyone reads/writes only their own `<ns>--*` by name, and nobody creates a secret outside
  the naming. **Platform viewers** (shared/ `platform_viewer_group_object_ids`, lab group
  `grp-onek8s-dev-platform-viewers` `75353964-...`, tester `platform.viewers` in the testers file): one custom
  role `OneK8s Platform Viewer (rg-aks-dev)` **defined and assignable at the resource group** (not the
  subscription - hardened landing zones) with cluster read + user kubeconfig, Azure RBAC data action
  `managedClusters/namespaces/read` (the portal's Workloads namespace picker) and vault read + secrets
  `readMetadata` (names, never values). Lab groups for ext-fi-example: view `6d9ae939-...`, edit `88ba3f87-...`,
  admin `71438fbc-...`, created by `entra-test-groups.yml`; testers in `tests/isolation/namespace-access-testers.yaml`.
- `dev-ext-stateful`: defined (`envs/dev-ext-stateful.tfvars`), never deployed (only with an approved exception).
- **Firewall Policies without a Firewall** (2026-10-14, azure-landing-zone `stacks/platform-extensions/main.firewall.policies.tf`,
  applied by its Platform workflow on merge): in sub-hub `rg-hub-fwpolicy-swedencentral`, parent `afwp-hub-parent-swedencentral`
  (Premium, threat intelligence + IDPS Deny, DNS proxy; `rcg-platform`: exposure guard rails Deny, Entra ID, AKS FQDN tag,
  Policy, Monitor, Defender, GitOps/ARM) and child `afwp-hub-ext-swedencentral` (`rcg-aks-dev`: vaults, ACR, Grafana, zone
  allow-lists) with IP groups of the real cell prefixes (`firewall_exposures` in its terraform.tfvars - keep in step with
  `shared/envs/dev.tfvars` and the fleet's `policy/egress-allow-lists.yaml`). No Firewall is associated (free); review in the portal.
  A parent's rule collection groups are evaluated before every child's, so no explicit deny-all in the parent.
- **Plan review 2026-10-14** (design PR: Firewall per exposure D53, no IPv6 D54, V13/V22): the design's
  network picture now has a hub and Firewall per exposure; no code changed anywhere. Open follow-ups when the user
  asks: azure-landing-zone `firewall` mode with the external hub (V22) and the firewall rules rewrite. IPv6: dropped.
- **Backlog**: 17 items in priority order in design section 17 ("Backlog, in priority order", 2026-10-14), four
  tiers: A now (1 promote the remaining policies to deny, 2 external hub Firewall in `firewall` mode, 3 private
  endpoints for vaults and ACR, 4 private API server), B before acceptance (5 version pipeline, 6 agents on the build
  tenant, 7 internal exposure, 8 second cell + cross-cell tests, 9 CIS follow-ups, 10 observability completion,
  11 backups, 12 manifest CI checks), C phase 3 (13 open verifications and acceptance tests, 14 pentest / review),
  D on trigger (15 stateful cluster, 16 WAF, 17 image promotion tests). Pick from the top unless the user says otherwise;
  update the list there when an item is done.
- **Platform Kubernetes policies in Azure Policy** (azure-landing-zone `stacks/aks-policy/kubernetes.tf`,
  templates + gator tests in `kubernetes/`): mutations **on** - 5 + 2 per zone, so 9 in the ext subscription (zone placement from the namespace,
  `platform/arch` -> arch selector, `platform/capacity: spot` -> toleration + preference,
  `platform/accelerator: nvidia-gpu` -> GPU toleration). **Deny**
  (2026-10-13, `kubernetes_deny` in `environments/dev/policy.tfvars`, each promoted after zero violations on
  az1): storage, FQDN egress, Gateway only, NodePools, placement labels, `secrets-via-eso` (in a zone's
  namespaces only `<zone>-secrets:external-secrets-<zone>` writes Secrets; the Flux extension's
  `fluxconfig-agent-sa` / `fluxconfig-controller-sa` and Helm storage exempt), `eso-objects`,
  `service-accounts`, `rollout-guardrails` (>= 2 replicas spread over nodes, maxUnavailable 0, PDB
  maxUnavailable >= 1), `vertical-pod-autoscalers`, built-ins no-Ingress and read-only root filesystem.
  **Audit** (reasons in policy.tfvars): zone placement (aks-hello's exception), pod security restricted,
  deployment safeguards, allowed images, automount, internal LBs, Image Integrity. Stateless/stateful
  rules are scoped with `not_scopes` (cluster names in `policy.tfvars`). A pod labelled
  `platform/zone-placement: "off"` skips the zone mutation (aks-hello's lab exception). To promote
  another rule: Cluster status must list 0 violations for it, then add it to `kubernetes_deny`.
- Region swedencentral. Quotas: regional vCPUs 52, Dpsv6 24, Dalv6 16, low-priority (spot) 3 - a
  raise to 8 was throttled by Azure ("retry after 3600 s", each retry restarts the wait); re-run
  `vcpu-quota.yml` once at most per hour.
- A cell with no applications is **one** 4-vCPU system node (Standard_D4als_v6, 2026-10-14) - only with Traefik and
  without the VPA add-on: then ~3.8 GiB of requests of the 5.8 GiB allocatable (with either, more than 5.8). Each zone with
  application pods adds NAP nodes.
- **One zone spot node stays with one system node** (seen 2026-10-14): AKS's `cilium-operator` runs 2 replicas with
  required host anti-affinity and tolerates every taint, so the second replica made NAP create a small zone node
  (`aks-extsespot-*`, Standard_D2ps_v6 spot, arm64) and stays there (hubble-relay joined it); NAP cannot consolidate it.
  AKS-managed - accepted (a spot D2ps_v6 costs a fraction of the second D4als_v6 it replaced).
- aks-hello runs **2 replicas** (rollout guardrails), still on the system node.
- **Lab cost exception:** aks-hello (aks-fluxcd-example `stateless/kustomization.yaml` patch) runs on
  the system node too, so dev runs no zone node for applications (only the cilium-operator one above). The
  Isolation tests' probe pod still uses the ext-fi zone, so a test run briefly creates a zone node
  (NAP removes it ~5 min after). Remove the patch to put the app back on zone nodes.

## Decisions already made (do not re-litigate)

- **Traffic Manager, not Front Door.** External zones get a public LB per zone per cell; one Traffic
  Manager profile per global hostname (e.g. `hello.ext-fi.dev.onek8s.lol`). Design uses Subnet routing
  with nested Priority profiles; the dev lab uses Weighted.
- **Gateway API implementation is a flag, `gateway_implementation`** (2026-10-14): `traefik` (dev, for the
  resources: Azure/AKS#5939) or `approuting-istio`. Earlier (2026-10-13) the user preferred the Azure standard
  offering, App Routing's Gateway API; with it AKS runs a sidecar-less istiod (`aks-istio-system`)
  and creates per Gateway an Envoy Deployment + LB Service + HPA (min 2, cannot go lower) + PDB, shaped by
  the ConfigMap in the Gateway's `spec.infrastructure.parametersRef` (allow list: nodeSelector,
  tolerations, resources, Service annotations/ETP...). No Istio service mesh add-on (mutually exclusive).
  Accepted losses: no rate limits / request size limits / EnvoyFilter in the gateway. Needs a preview
  cluster API that knows `appRoutingIstio`: AVM 0.8.5 (upstream fix of our report) pins
  `2026-03-02-preview` when the ALB setting is stated, which knows it.
- **Public API server in dev** (authorized ranges, Entra ID only, local accounts off) - a lab
  exception the user asked for. Private API server stays the design for acc/prd.
- **Isolation zones** int-fi, int-se (internal clusters only), ext-fi, ext-se (external clusters only): per cell a /24 each (nodes /25, ILB /27),
  own NSG, own Key Vault (`kv-onek8s-dev-<zone>`), own NAP AKSNodeClass + NodePools, own
  Gateway (class `traefik-<zone>` or `approuting-istio`) and ESO (`controllerClass: <zone>`), Cilium CCNP baseline.
- **Zone nodes only for applications.** Each zone's gateway pods and ESO run on the system pool (with the
  platform gateway and platform ESO), so a zone without application pods has zero nodes and its
  NodePools scale to zero. Consequence: the system subnet NSG allows 443 from Internet *and* (a
  separate rule) from VirtualNetwork.
- **GPUs are the application's choice too** (D42): label `platform/accelerator: nvidia-gpu` + request
  `nvidia.com/gpu`; zone GPU pools H100 v5 only (VNet encryption), on-demand.
- **No AKS cost analysis add-on**: cost per namespace/team comes from OpenCost in Grafana's k8s-monitoring
  chart, deployed by Flux (the user's choice); namespaces name their owner (R25).
- **Spot and architecture are the application's choice.** Per zone a spot NodePool (weight 50,
  taint `platform/capacity=spot`) and an on-demand one (weight 10): a pod that tolerates spot gets
  spot when available, else on-demand; one that does not stays on on-demand. amd64 and arm64 both
  offered; a pod pins `kubernetes.io/arch` or takes either. aks-hello is amd64 only.
- **eBPF host routing (BpfVeth) only at cluster creation**: AKS refuses to enable it on a running
  cluster ("User-installed iptables rules found"). AVM 0.8.5 has the input
  (`network_profile.advanced_networking.performance.acceleration_mode`, our upstream report); the module
  was vendored with patches until 2026-10-14 and is back on the registry.
- **CMK**: per cluster `key-<cluster>-kms` and `key-<cluster>-disk` in `kv-onek8s-dev-platform`
  (purge protection), DES `des-<cluster>`, encryption at host. Azure Linux, SSH off, system pool
  tainted `CriticalAddonsOnly`, Kubernetes 1.36, auto-upgrade none, Free tier.
- **Secrets only through ESO**; vault shares by ABAC prefix `<namespace>--`; gateway certs
  `<zone>-gateway--wildcard` and `platform-gateway--wildcard`.
- **One policy engine (R14)**: no ValidatingAdmissionPolicies in the fleet; every admission rule is an
  Azure Policy definition. Placement (R17) is stated by applications only as labels `platform/arch`
  and `platform/capacity`; the mutations do the rest.
- **A hub VNet and Azure Firewall Premium per exposure, no peering or route between them** (D53, 2026-10-14,
  plan only): `vnet-hub-int` (ExpressRoute/VPN gateway, Private DNS Resolver, Bastion, the corporate path, the lab's
  client VNet), `vnet-hub-ext` (Firewall + Private DNS links only, no gateway); the management VNet is the one network
  peered to both (not transitive); one parent Firewall Policy (platform FQDNs, IDPS, deny tail) with a child per
  exposure; a Grafana private endpoint per hub. int -> ext business flows go to the public entry point like any
  Internet client; ext -> int has no path (a design change, not a rule). Cost: one more Firewall Premium per tenant
  (~1.75 USD/h list), platform owner confirms (H05). **Nothing built**: the lab runs azure-landing-zone's `sandbox`
  network mode (no Firewall, cells not peered to any hub) and has no internal subscription. When `firewall` mode is
  built (external hub first, V22), rewrite `stacks/platform-extensions/main.firewall.tf` there: today one rule
  collection group per environment with both exposures in one `frontend` IP group, plus the removed NGINXaaS edge rules.
- **IPv4 only, no IPv6 planned** (D54, user 2026-10-14): NAP refuses dual-stack clusters (AKS issue 4867, open
  since 2025-03), Azure Firewall dual stack is a preview without application rules or IP groups, Private Link IPv6 a
  preview outside swedencentral. Re-opened only as a new decision if a regulator or customer requires it.
- **Stateful cluster OS channel is unverified** (V13 re-opened 2026-10-14): the network isolated cluster docs list
  only `NodeImage` and `None`; D10's `SecurityPatch` is tried first, `NodeImage` in the same window if refused.

## Lessons learned (gotchas)

- **Cilium DNS rules must cover the pod's search suffixes**, including the node's Azure suffix
  `<id>.<x>.internal.cloudapp.net`; a refused expansion makes musl (Alpine) stop resolving, so
  allowed FQDNs fail. The zone baseline allows `cluster.local` and `internal.cloudapp.net` patterns.
- **A `Microsoft.Kubernetes.Data` policy rule may test only `type`, `location` and `tags`** of the
  cluster (`InvalidPolicyAliasFormat` otherwise, only at apply - the plan does not catch it); scope by
  assignment `not_scopes`. Custom mutations cannot be parameterized: render one definition per value.
- **An NSG rule takes one service tag**; `Internet` + `VirtualNetwork` in one rule is a 400.
- **App Routing's istiod requests 500m + 2 GiB per replica, min 2, not customizable**: one 8 GiB system
  node filled to 99 % memory and left gateways, ESO, apps and Ratify Pending - hence two system nodes with it
  (Azure/AKS#5939; the dev cells run Traefik instead).
  Its gateway pods have no seccomp profile (PSS restricted would refuse them: gateway namespaces are
  baseline). The Image Integrity policy's ID also tags `K8sAzureV1PrintMutationsAnnotations`
  constraints, which report every mutated pod - filter them out when counting signature violations.
- **Quota errors** show up as `ErrCode_InsufficientVCPUQuota` on the cluster PUT; check the
  "vCPU quota" step of Cluster status.
- `az vm list-usage` values are strings (JMESPath `currentValue != '0'`, not `> 0`).
- **Preview properties are invisible to `az aks show`** (its API version leaves them out, e.g.
  `securityProfile.imageIntegrity`): read them with `az rest` and `?api-version=2026-05-02-preview`.
- The Image Integrity add-on's Ratify CRDs are older than Ratify's docs (no
  `KeyManagementProvider.spec.refreshInterval`), and Ratify may not write a new object's status;
  its log says whether it loaded it. The registry keeps signatures also under `sha256-<digest>` tags.
- Notation cannot `notation login` on a runner (no credential store); `az acr login` (Docker) works.
- The `az quota` CLI extension's `--limit-object` syntax is broken; use `az rest` against
  `Microsoft.Quota/quotas/<name>?api-version=2023-02-01`.
- Renew Certificate matrix jobs need `max-parallel: 1` and per-cert concurrency groups; DNS-01 can
  fail once - re-run.
- GitHub OIDC to Azure has transient 503/504s; re-dispatch.
- `kubectl debug` has no `-o`; parse the pod name from its output.
- **A policy that denies must be checked against what the platform itself writes**, not only the audit:
  Gatekeeper's audit has no request user (`secrets-via-eso` reports nothing there), and AKS components
  write into team namespaces (the Flux extension's `<config>-auth/-genkey/-protected-parameters`).
  Cluster status lists Secret writers from managed fields (`kubectl get -o json` hides them unless
  `--show-managed-fields`). An assignment display name over 128 characters fails only at apply.
- **kube-bench pinned with `nodeName` must request no resources**: it bypasses the scheduler, and the
  kubelet of a full system node rejects the pod at once (BackoffLimitExceeded, no logs).
- **Kubescape's CIS AKS control names number section 3 differently from kube-bench's `aks-1.8`**, and
  without a host scanner it has no node data; report.py takes section 3 from kube-bench only.
  Microsoft.Security is not registered in the build subscription (Defender plan unreadable = off).
- `az aks install-cli` can fail on GitHub's API rate limit (kubelogin lookup) - re-run.
- **A failing `check` block fails `terraform test` runs** (not only a warning) - so no check for
  managed namespaces without an owner; Azure Policy enforces it. `merge()` of maps with conditional
  `{}` yields an object: wrap in `tomap()` when tests compare with `tomap({...})`.
- **New parameters on an assigned Azure Policy definition need a `defaultValue`**, or the update fails.
- **Karpenter's `sku-series` does not name the GPU** (`NDisr_v5` is H100 and H200): also require
  `karpenter.azure.com/sku-gpu-name`.
- **Flux `valuesFrom.targetPath` parses values like `helm --set`**: a numeric user ID became `1.872197e+06`
  and Fleet Management refused the login. Merge a whole YAML document instead (ESO template, values
  quoted with `toJson`); ESO's template data is `map[string]string`, so sprig `hasKey` fails - use `index`.
  `valuesFrom` reads Secrets of the HelmRelease's namespace only (flux-system).
- **k8s-monitoring on AKS** refuses to render without the pod annotation
  `kubernetes.azure.com/set-kube-service-host-fqdn: "true"` on every Alloy collector and kube-state-metrics
  (detected from live node labels via `lookup`, so offline `helm template` misses it); with it, pods
  resolve `*.hcp.<region>.azmk8s.io`, which their Cilium DNS rules must allow.
- **The system node is nearly full**: on 2026-10-14 the two D4als_v6 held ~11 GiB of requests, istiod 4 GiB and
  the VPA add-on 2.4 GiB of it; without both, one node (~5.8 GiB allocatable) holds the rest with ~2 GiB to spare.
  New system-pool workloads need small requests or node-critical priority.
- **GitHub OIDC subjects of this org carry immutable IDs** (`repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`),
  not `repo:onek8s/aks-terraform:...`: a federated credential on the short form gets 401 at Entra ID.
- **Azure refuses two Kustomizations of one Flux configuration on the same path** (`InvalidInputParameter`).
- **An ABAC condition may name only actions its role has** (`InvalidRoleAssignmentCondition: Action pattern ... is not
  referenced in role`, only at apply): a custom role needs its own condition (conventions `key_vault_edit_conditions`).
- `kubectl auth can-i` on an Azure RBAC cluster answers `no - Azure does not have opinion...`: parse the first word.
- **Credentials handed over in chat** go to the vault with `store-secret.yml` (encrypted to the vault key
  `secret-transport`), never into Git or a workflow input.
- Waiting: use `/tmp/claude-0/bin/waitrun.sh <repo> <run_id>...` if it exists (polls the runs API),
  or a loop over the runs API; long foreground `sleep` is blocked in the sandbox.
