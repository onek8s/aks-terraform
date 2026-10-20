# OneK8s - working notes for Claude sessions

OneK8s is an AKS platform design (https://onek8s.github.io, repo `onek8s/onek8s.github.io`) and its
implementation in the `onek8s` GitHub organisation. This file is the shared memory of earlier
sessions: what is deployed, how to operate it, and decisions already made. Keep it current when
something here changes; history lives in Git and in the design's tags (v1.15 is the last v1).

## Repositories

| Repo | Role |
|---|---|
| `onek8s.github.io` | The design (`docs/<part>.<page>-*.md`, e.g. `2.3-node-pools.md`, `1.2-requirements.md`, `7.2-decisions.md`, `7.3-open-questions.md`). Code follows it; change it when a decision changes it. Sections were renumbered on 2026-10-17 (#58, #61; mappings in that repo's CLAUDE.md) - older notes and commits cite the old numbers. |
| `aks-terraform` (this one) | The clusters (root module on the registry AVM AKS module 0.8.5) and what an environment's clusters share (`shared/`: cell VNets + NSGs + route tables, platform and zone Key Vaults, private DNS, Traffic Manager, ACR). All deployment and status workflows live here. |
| `aks-fluxcd-platform` | What Flux deploys into every cluster: isolation zones (Gateway, ESO, Cilium), the autoscaler's priority expander, external-dns, tenants. `clusters/<cluster>/` per cluster. |
| `aks-fluxcd-example` | An application team's repo (namespace `<zone>-example`, app aks-hello). |
| `azure-landing-zone` | Build tenant, ALZ, hub (labfw), AKS policy assignments, the per-application firewall rules. No AKS clusters. |
| `aks-hello` | The sample app image (amd64 only). |
| `aks-ai-agents` | Day-2 AI agents (egress agent, traffic flow docs). |

## How to operate (no local cloud credentials)

The session has no Azure or kubeconfig credentials. Everything runs through GitHub Actions in
`aks-terraform`, dispatched with the GitHub MCP tool (`actions_run_trigger`, `run_workflow`) and read
back through the GitHub API (`curl https://api.github.com/repos/onek8s/...` works unauthenticated for
reads; job logs via `get_job_logs`).

| Workflow | Use |
|---|---|
| `deploy.yml` (Deploy) | `stack`: `dev-shared` (apply first) / `dev-int-stateless-az3` / `dev-int-stateful`; `action`: plan / apply / destroy; `allow_empty_state: true` for a first build after a destroy. dev-shared is never destroyed from here. A stateless cell is planned with `envs/dev-int-stateless.tfvars` (what every cell shares) then the cell's own file. Registers the providers and preview features (Gateway API CRDs, encryption at host, Image Integrity). Run stacks one at a time: each joins the labfw VPN as the one peer `github-deploy`. |
| `cluster-status.yml` (Cluster status) | Read-only status of one cluster: nodes, pods, cluster autoscaler, Flux, DNS, vCPU quota, every policy constraint's violations per object and excluded namespaces, who wrote each Secret of the zone namespaces (managed fields), every route through its gateway and as a VPN client (edge protocols: h2, ALPN http/1.1, TLS 1.2, TLS 1.3). Options `route_path` (e.g. `/weather`), `node_iptables`, `cilium_drops` (Cilium's drop monitor, for a cell without Hubble). Read it before promoting a policy to deny. |
| `isolation-tests.yml` | The negative requirement and isolation tests of design section 7.1 on the cell (zone int-se, other zone int-fi), each tagged with its R-number. Test pods run `isolation/curl` imported into the ACR by digest (deliberately unsigned; Sign images and the signature checks skip `isolation/`) and meet every rule in deny; R7 reads shared/'s fixture `<ns>--isolation-test` (`isolation_test_namespaces`); the internal app names are pinned through the VPN action's `extra_private_names`: cluster settings, `--admin` refused, platform policies present, probe placed by the mutations alone, cross-zone / cross-namespace / node / IMDS / vaults blocked, egress, forbidden manifests as server-side dry runs (PASS = refused, AUDIT = rule still in audit), supply chain (ACR, Ratify, signatures, Flux webhook), Resource Graph public endpoints against `tests/isolation/allowed-public-endpoints.yaml`, Key Vault ABAC and roles (`check-key-vault-roles.py`), R6 namespace access (`check-namespace-access.py`, testers in `tests/isolation/namespace-access-testers.yaml`), R11 cell settings (AZ, zone pools autoscaled from 0, VPA), R13 sync (`check-cells-in-sync.py`), R15 certificates, R16 every zone complete, R2 one exposure. **Only when the user asks for it** (runs take 10-30 min) - never dispatched on your own. |
| `cis-benchmark.yml` (CIS benchmark) | CIS AKS Benchmark of one cluster: kube-bench (`aks-1.8`, Job per node, section 3), Kubescape `cis-aks-t1.8.0` (section 4), Azure settings (sections 2 and 5). `tests/cis/report.py` scores it; a failure not in `tests/cis/accepted.yaml` (with its reason) fails the run. **By hand only, when the user asks.** |
| `sign-images.yml` (Sign images) | Notation-signs every image in the ACR with `image-signing` in the platform vault; skips what already verifies. After every Deploy apply of dev-shared, and by hand. |
| `renew-certificate.yml` | Let's Encrypt wildcards into the platform vault (matrix, max-parallel 1); a zone's gateway needs `<zone>-gateway--wildcard`. |
| `vcpu-quota.yml` | Raises the subscription's compute quotas via the Quota REST API as `AZURE_OWNER`. `gpu` input: `StandardNCadsH100v5Family` (40 per GPU node, default 0 = leave). |
| `store-secret.yml` (Store secret) | Puts a secret into `kv-onek8s-gwc-platform` (over the VPN) without its value in Git, inputs or logs: `public-key` prints the vault RSA key `secret-transport`'s public key; encrypt with it (RSA-OAEP-256, `openssl pkeyutl`, ≤ 446 bytes) and run `store` with the name and base64 ciphertext. Use it for any credential the user hands over in chat. |
| `flux-webhooks.yml` (Flux webhooks) | After every Deploy and by hand: GitHub push webhooks of aks-fluxcd-platform and aks-fluxcd-example to every running cluster with `flux_github_webhook` on (token from shared/ over the VPN); deletes the rest - all of them in the lab (off). |
| `pr.yml` | CI: fmt, validate, `terraform test`. |
| `lab-power.yml` (Lab power) | Manual pause of the lab (`clusters`, default `aks-dev-int-stateless-az3`; `firewall`). stop: every Flux configuration and Kustomization suspended, the `platform/zone` namespaces' Deployments/StatefulSets scaled to 0 (replicas kept in an annotation), `az aks stop`, then labfw's VM deallocated (custom role `OneK8s labfw Power`). start: labfw first (+1 min), `az aks start`, a second sign-in, replicas restored, Flux resumed, every HelmRelease force-reconciled. Git unchanged; idempotent, re-runnable. Never undo its steps by hand. |
| `entra-test-groups.yml` (Entra test groups) | Manual, as `AZURE_OWNER`: for a `namespace` and `roles`, groups `grp-onek8s-dev-<ns>-<role>` (`platform` + `viewers` for the platform viewers) and tester apps `onek8s-dev-<ns>-<role>-tester` federated with `repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`. Idempotent; prints the IDs for the tfvars and the testers file. |
| `vpn-clients.yml` (VPN clients) | The runners' labfw VPN configs as `dev` environment secrets (GH_OWNER): `copy-runners` (vault -> `LABFW_VPN_GITHUB_RUNNERS`), `new-peer` (key pair -> `LABFW_VPN_<PEER>`, prints the public key for azure-landing-zone `labfw.vpn.peers`). Re-run if labfw's public IP or key changes. |
| `egress-agent.yml` (Egress agent) | By hand only: aks-ai-agents' egress agent reads labfw's denied flows, maps each pod address to its namespace and opens one PR per namespace to azure-landing-zone `firewall-applications/`. **Do not merge its PRs: the user validates them.** |
| `traffic-flow-docs.yml` (Traffic flow docs) | Manual (design 5.3, D63): `aks-agent docs traffic` generates the traffic flow pages of a `spoke` (default `dev-int`) from Git alone into azure-landing-zone `docs/traffic-flows/` (artifact + findings); with `dry_run` off and a page changed, the documentation agent (Foundry, so the lab must run) opens ONE PR there. `--check` fails on stale pages. |
| `fleet-management.yml` | Grafana Fleet Management: `match-clusters` points the k8s pipeline's matcher at `aks-dev-int-stateless-.*` once the vault secret `flux-system--grafana-cloud` has `fleet-management-write-token` (not done yet: the collectors' token gets 401 on UpdatePipeline). |
| `design-tags.yml` (Design tags) | Hourly and by hand, with GH_OWNER: tags the default branch's head of every onek8s repository `v<version>` of the design (onek8s.github.io `_config.yml`) once that version appears; never moves a tag. **Every design version is tagged `v<version>` in every repo by Design tags: merge the round's code PRs before the design's**, then dispatch it. |
| `lab-admin.yml` (Lab admin) | Manual, **last resort**: ONE `az` (as `AZURE_OWNER`) or `gh` (with `GH_OWNER`) command; `args` split like a shell, no pipes (use `--query`/`--jq`). Its runner is not on the VPN (no Log Analytics, no vault reads). The log is public to repo readers: never print a secret. |

**Owner credentials (lab only, last option, allowed whenever needed):** `AZURE_OWNER` - org secret, `az ad sp
create-for-rbac` JSON of an SPN that is Owner on the lab subscriptions and **Global Administrator** of the lab
tenant (Graph works: groups, apps, role assignments); `GH_OWNER` - org secret, a GitHub admin token of the onek8s
organization. Use them through `lab-admin.yml`, `entra-test-groups.yml` or `vcpu-quota.yml`, not in routine pipelines.

Local checks before a push: `terraform fmt -check -recursive`, `terraform test` in the root (144 runs) and in
`shared/` (67), `kustomize build` for changed fleet directories; for a policy change in azure-landing-zone,
`stacks/aks-policy/kubernetes/test.sh` (gator, download the release binary) and `terraform test` there. The fleet and
example repos' CI does not run on GitHub, so validate them locally.

Workflow: branch, PR, squash-merge (the user wants changes deployed and merged without asking each time), then
dispatch the workflow on `main` and check the result. Verify with Cluster status (fast); the Isolation tests and the
CIS benchmark run **only when the user asks for them**. Order for network changes: merge + apply `dev-shared` before
merging a fleet change that depends on it. Waiting: `/tmp/claude-0/bin/waitrun.sh <repo> <run_id>...` if it exists,
or a loop over the runs API (long foreground `sleep` is blocked).

## Current state of dev (design v2.0, 2026-10-19)

- **One cell: `aks-dev-int-stateless-az3`** (stack `dev-int-stateless-az3`), germanywestcentral, availability zone 3,
  internal exposure (`sub-aks-dev` plays `sub-aks-dev-int`), **two zones since 2026-10-20**: Sweden's `int-se` and
  Finland's `int-fi` (the user: two zones in one cell to test the isolation between them, D73/V31) - each with its
  gateway, ESO, zone pools and an `<zone>-example` namespace running aks-hello from aks-fluxcd-example
  (`firewall-egress/` Stockholm, `firewall-egress-int-fi/` Helsinki; rule files for both in azure-landing-zone).
  `zone_node_pools.max_count = 1` per pool (quota). `dev-int-stateful` is defined (a pod-subnet cluster too), never
  deployed. The ALZ bootstrap stays in swedencentral.
- **Network: Azure CNI Pod Subnet with dynamic IP allocation + Cilium** (no overlay, no node subnet mode). Nodes and
  ILBs in /24 slots of `address_space` 10.100.0.0/16 (snet-system 10.100.0.0/24 - also the API server's private
  endpoint -, int-fi 10.100.1.0/24, int-se 10.100.2.0/24, ILB 10.100.2.128/27); pods in `pod_address_space`
  100.64.0.0/16, a /20 per slot (`snet-system-pods` 100.64.0.0/20, `snet-int-fi-pods` 100.64.16.0/20, `snet-int-se-pods`
  100.64.32.0/20), delegated to AKS. Root: `pod_subnet_name`, `isolation_zones.<zone>.{node,pod}_subnet_name`. Pods
  keep their addresses to labfw (fleet `pod-addresses-to-firewall`: AKS's `azure-ip-masq-agent-config` translates
  nothing; `infrastructure/zones/firewall-egress` lets the zone's apps out to `world` - labfw decides).
- **Zone nodes: classic pools** (`zone_node_pools`): `intse`, `intsespot`, `intsearm`, `intsearmspot`
  (Standard_D2alds_v6 / D2pds_v6, ephemeral OS disk, 250 pods), min 0, labels/taints `platform/zone` and
  `platform/capacity=spot`; the cluster autoscaler's `priority` expander takes spot first (fleet
  `infrastructure/autoscaler-priority`). No node auto provisioning: it does not support a pod subnet
  (karpenter-provider-azure issue 1351) - a watch-list item in the design. GPUs (D42) would be a classic `<zone>gpu`
  pool (H100 v5, on-demand, taint `platform/accelerator=nvidia-gpu`) - design only; **the user does not want GPU nodes
  in the lab** (quota stays 0).
- **System pool**: one `Standard_D4alds_v6` node, `os_disk_type = "Ephemeral"`, Azure Linux, SSH off,
  `CriticalAddonsOnly`. It fits only with the lab's cost savings, stated in one "Non-production cost savings" block of
  `envs/dev-int-stateless.tfvars`: Free tier, `gateway_implementation = "traefik"`, VPA add-on off (aks-hello's
  VerticalPodAutoscaler is patched out in the example repo). variables.tf defaults are production (Standard,
  `approuting-istio`, VPA on, 2 x Standard_D4ds_v5) - README "Production defaults and
  non-production cost savings". The stateful tfvars state `gateway_implementation = null` (R9a).
- **No ACNS** (D80, cell rebuilt 2026-10-19): `advanced_networking = null` is the default - no Hubble, FQDN policies or
  eBPF host routing. The fleet's Cilium policies are layer 3 and 4 only (no `toFQDNs`, no DNS rules - both need the
  ACNS DNS proxy); platform namespaces go out on 443 to `world`, labfw decides.
- **Hub: azure-landing-zone mode `labfw`** - VM `labfw-fw` (Standard_B2ats_v2, 10.0.1.4, public IP 4.184.103.12,
  `rg-hub-labfw-germanywestcentral` in sub-hub) enforces `afwp-hub-int-germanywestcentral` + parent. The cell is peered
  with `vnet-hub-germanywestcentral`. **Route tables (D73 (f), 2026-10-20): every node and pod subnet's table has the
  same shape** - 0.0.0.0/0 + the cell's `address_space` and `pod_address_space` -> 10.0.1.4, its own node and pod
  slots `VnetLocal`: `rt-<cell>` (system, 5 routes), `rt-<cell>-<zone>` (6: + the zone's own ILB /27 -> firewall).
  So zone-to-zone AND zone-to-system flows meet labfw: the Kubernetes flows are network rules of `rcg-aks-dev`
  (`system-pool-to-zones` TCP */ICMP, `zones-to-cluster-dns` 53, `zones-to-api-server` 443 (unused, see below),
  `zones-to-cilium-health` 4240, ping) - a new platform flow between the pools shows up as a labfw denial and needs
  a rule there. **Not the API server's private endpoint**: its /32 system route wins over the UDRs in every subnet,
  so every node reaches it and it answers directly; `private_endpoint_network_policies = Enabled` on snet-system
  (tried 2026-10-20, #216) made its answers to the system pool follow the table to labfw while the requests had
  not - the system node went NotReady within a minute (kubelet lost the API server, konnectivity and CoreDNS
  evicted, every gateway unreachable); reverted in #217. Keep it `Disabled`. Between
  zones nothing; an application reaches another zone's (or its own zone's) published name only as a client: an
  application rule (FQDN) in its rule file, proxied by labfw, so the gateway's answer returns through the hub.
  Never a network rule between zone slots (asymmetric). V31 denial not tested yet. VNet DNS = labfw's DNS proxy;
  `outbound_type = "userDefinedRouting"`. labfw SNATs what leaves 10.0.0.0/16, 10.100.0.0/16, 172.16.0.0/12,
  192.168.0.0/16, 100.64.0.0/10; zone IP groups list node + pod slots. Egress per application from azure-landing-zone
  `firewall-applications/<env>-<exposure>/<namespace>.yaml`; platform allow-lists in parent `rcg-platform` (AKS FQDN
  tag, `AzureCloud.germanywc` 443 - service tags use the short region name, `service_tag_region`) + child `rcg-aks-dev`.
  Denials go to Log Analytics `log-labfw-germanywestcentral`, table `LabfwFirewallLog_CL` (~10 min latency).
- **Private API server** (D58): classic private cluster over Private Link (endpoint in snet-system),
  `private_dns_zone_mode = "none"` + public FQDN resolving to the private IP. Not API Server VNet Integration (Azure
  refuses it on encrypted VNets with v4+ sizes, H14). `az aks command invoke` is the break-glass (namespace
  `aks-command`, a platform namespace for the policies).
- **labfw VPN** (WireGuard, UDP 51820 on 4.184.103.12; DNS 10.0.12.1): peers `olli-1` 10.0.12.10 (private key in
  `kv-onek8s-gwc-platform` as `labfw-vpn--olli-1-private-key`), `github-runners` 10.0.12.11 (secret
  `LABFW_VPN_GITHUB_RUNNERS`, concurrency group `labfw-vpn` - one such run at a time), `github-deploy` 10.0.12.12
  (`LABFW_VPN_GITHUB_DEPLOY`); `dev` environment secrets made by `vpn-clients.yml`. `.github/actions/labfw-vpn` adds
  the cell's routes and pins labfw's private names into /etc/hosts. SSH `azureuser@10.0.12.1` from `labfw.ssh.sources`;
  ping only from labfw's address (nodes answer, ILBs and private endpoints never do).
- **No public endpoints** (D60): vaults, Foundry, the state account `stonek8sdevtfstate` (Entra ID only,
  `use_azuread_auth`) and `log-dev-platform` take no public network access (endpoints in snet-shared-pe 172.20.2.0/26;
  Log Analytics through the hub AMPLS `ampls-hub-germanywestcentral`, 10.0.8.138). Exceptions: the registry
  `acronek8sdev` is **Basic on its public endpoint** (D62, Entra ID only; Premium + private endpoint only in `prd`),
  labfw's IP, AKS-managed node disks and extension Private Link scopes, the ALZ bootstrap state.
  **onek8s/azure-lab-fw must stay public** (labfw downloads its release anonymously). Break glass: ARM stays public.
- **KMS data encryption** (preview, `customer_managed_keys.kms_data_encryption`, kms.tf, azapi beside AVM) with
  `key_vault_network_access = "Private"`; AKS rewrites every Secret as `aksService` (exempt in `secrets-via-eso`).
  CMK: `key-<cluster>-kms`, `key-<cluster>-disk` in the platform vault, DES `des-<cluster>`, encryption at host.
- **Image Integrity** (preview, `image_integrity_enabled`, `image_integrity.tf` with `azapi_update_resource`):
  shared/ `image_signing` - cert `image-signing` in the platform vault, identity `id-gwc-dev-shared-ratify` federated per
  cluster with `gatekeeper-system/ratify-admin`; fleet `infrastructure/image-verification`. Upstream images (ESO, Flux)
  are reported unsigned - expected.
- **Naming policy** (D72): `modules/conventions` `naming`, a template per resource type, defaults = the lab's names
  (asserted by shared/tests/naming.tftest.hcl). The real policy stays out of Git: `dev` environment secret
  `NAMING_POLICY` (JSON), written by Deploy to `naming.auto.tfvars.json` and masked; `scripts/policy-name.sh` for
  workflows. A variable that names a resource still wins.
- **Edge: HTTP/2 + TLS 1.3 only** (D69-D71): Traefik's ConfigMap `traefik-dynamic` (`gateways/traefik`) sets ALPN
  `[h2]` and `minVersion: VersionTLS13`; aks-hello serves h2c on port 8081 (Service `appProtocol: kubernetes.io/h2c`).
  V28 (HTTP/2 upstream) and V30 (TLS 1.2 refused) hold; **V29 fails**: Go lets an `http/1.1` client in without ALPN
  (golang/go#46310) - a new D70 option is the user's decision, not taken. Policies `h2c-upstream` and `gateway-tls`
  (azure-landing-zone) deny (2026-10-19).
- **Flux GitHub webhook** (D78): root `flux_github_webhook` brings the platform gateway and flux-system's vault share;
  token in shared/. **Off in the lab** (no public entry point behind labfw; Flux polls every minute). GitHub delivers
  over HTTP/1.1: the receiver is the one exemption of `h2c-upstream` (`flux-system/webhook-receiver`).
- **Apps**: aks-hello 0.8.0 (2 replicas, rollout guardrails) in `int-se-example` from aks-fluxcd-example
  `firewall-egress/` and in `int-fi-example` from `firewall-egress-int-fi/`, each on its zone's nodes, fetching a
  forecast (api.open-meteo.com) and its public IP (api.ipify.org) - allowed only once azure-landing-zone's
  `firewall-applications/dev-int/<ns>.yaml` names them (open-meteo yes, ipify not: egress agent PR
  azure-landing-zone#66, left for the user). **Peers (0.8.0, 2026-10-20)**: each zone's aks-hello polls the other's
  by its Service name and its published name every minute (`PEERS`, `/peers`), so labfw's log shows the
  cross-zone flows: the Service name never answers (Cilium/labfw), the published name only with an application
  rule for `hello.<zone>.dev.onek8s.lol` in the caller's rule file - none written yet, so both show as denied. `lab/scale/kustomization.yaml` is the Git-only replica switch.
  Internal names by home cell: `hello.<zone>.dev.onek8s.lol` next to `hello-<cluster>...`; routes carry
  `platform/home-cell` and external-dns-int publishes only its own cluster's.
- **Egress agent**: model gpt-4.1-mini on Foundry `ais-onek8s-dev-agents` (swedencentral, Entra ID); Claude models are
  attested there but have 0 Foundry quota (`deploy = false`). Only denials ingested since its checkpoint, at most 3 h
  back; state in the Actions cache; known flows never reach the model. Keep its instructions step by step.
- **Traffic flow docs** (D63): generated pages of `dev-int` in azure-landing-zone `docs/traffic-flows/`; regenerate
  after a rule or application change. `stats.grafana.org` is a platform flow (Grafana usage stats) in
  `observability_fqdns`.
- **Observability**: Grafana k8s-monitoring 4.5.2 by Flux as Grafana Cloud Fleet Management sets it up (D48; pipelines
  managed in Grafana Cloud), secret `flux-system--grafana-cloud`; OpenCost waits for a metrics:read token (D46: no AKS
  cost analysis add-on). The k8s pipeline's matcher still names an old cluster (see `fleet-management.yml`).
- **Policies** (azure-landing-zone `stacks/aks-policy`): mutations on (zone placement from the namespace,
  `platform/arch`, `platform/capacity: spot` -> toleration of `platform/capacity` and AKS's
  `kubernetes.azure.com/scalesetpriority=spot` + preference, GPU toleration). Deny: storage, `app-egress` (application policies inside the cluster only, D80), Gateway only,
  placement labels, `secrets-via-eso`, `eso-objects`, `service-accounts`, `rollout-guardrails`,
  `vertical-pod-autoscalers`, `namespace-ownership`, no-Ingress, read-only root filesystem, zone placement, internal LBs,
  `gateway-tls`, vault public access, ACR admin, PSS restricted, deployment safeguards, allowed images (registry by
  digest), automount, `h2c-upstream` (2026-10-19, D82: every rule with 0 violations). Audit only: Image Integrity and
  the cluster-setting built-ins (no Deny effect, `audit_only`). The application rules leave out every platform
  namespace (`kubernetes_excluded_namespaces`, design 2.7). Promote a rule only after Cluster status shows 0
  violations for it. 2026-10-19: 0 violations in the cluster (Gatekeeper), CIS 0 failed, Isolation tests 0 failed;
  Azure Policy 31 compliant, 11 exempt. Deployment safeguards' warn-only `printMutationsAnnotations` reported every
  mutated application pod ("resource was mutated by platform mutation"): disabled in the assignment
  (azure-landing-zone#99), its results gone by 2026-10-20. Still listed non-compliant on 2026-10-20: 7 Key Vault
  data-plane rules of the deleted `Deploy-MCSB2-Monitoring` on `kv-onek8s-gwc-platform`, with fresh timestamps
  although `az policy assignment list --disable-scope-strict-match` finds no such assignment - Azure's own
  clean-up; check again with Lab admin (`az policy state list --filter "complianceState eq 'NonCompliant'"`).
- **Access**: namespace groups (D49) `managed_namespaces.<ns>.groups = { view, edit, admin }` -> a Flux configuration
  `<ns>-access` with a RoleBinding per role + `Azure Kubernetes Service Namespace User`; on the vault `admin` Secrets
  Officer, `edit` custom `OneK8s Key Vault Secrets Editor (rg-aks-dev)` (D51), both under the `<ns>--` ABAC condition.
  No namespace identity or group can list a vault (D50); platform viewers (`grp-onek8s-dev-platform-viewers`
  `75353964-...`) get custom `OneK8s Platform Viewer (rg-aks-dev)` at the resource group. Every namespace carries
  `platform/team`, `platform/cost-center`, annotation `platform/contact` (R25). shared/ `monthly_budget` 600/month.
- **Identity**: Deploy runs as `id-aks-dev-apply-germanywestcentral` (client ID b975d49a-...), the `dev` environment's
  AZURE_CLIENT_ID; set it again with Lab admin (gh) after any rebuild of sub-mgmt.
- **Quotas** (germanywestcentral, sub-aks-dev): regional 38, Dpsv6 16, Daldv6 8 (system node 4 + two D2alds_v6),
  low-priority 3 (one spot D2alds_v6; raises get throttled - retry at most hourly). sub-hub: Basv2 4 (labfw).
- **Backlog**: design section 7.1 "Backlog, in priority order". Pick from the top unless the user says otherwise;
  update the list there when an item is done. V32 (spot fallback, labfw's log naming the pod) and V31 are open -
  V31 can now be tested: both zones run in az3 (Isolation tests, only when the user asks).

## Decisions already made (do not re-litigate)

- **One cell network: Azure CNI Pod Subnet** (dynamic IP allocation, Cilium); overlay is gone (v2.0, D79), node
  subnet is not offered. **Classic zone pools with the cluster autoscaler until NAP supports the pod subnet.** **No AKS
  Automatic.** The lab is one cell.
- **Traffic Manager, not Front Door.** External zones get a public LB per zone per cell; one Traffic Manager profile
  per global hostname (Subnet routing with nested Priority profiles in the design; Weighted in a lab).
- **Gateway API implementation is a flag, `gateway_implementation`**: `traefik` (dev; `gateways/traefik`, a Flux
  configuration `traefik-<gateway>` per Gateway) or `approuting-istio` (the production default: App Routing's
  sidecar-less istiod, an Envoy Deployment + LB + HPA min 2 + PDB per Gateway, shaped by the ConfigMap in
  `parametersRef`; no rate limits / request size limits / EnvoyFilter; istiod requests 2 x 500m/2 GiB, not tunable,
  Azure/AKS#5939). Traefik refuses a `parametersRef`, so the fleet adds it only in its `approuting-istio` component.
- **Isolation zones** int-fi, int-se (internal clusters only), ext-fi, ext-se (external clusters only): per cell a /24
  node slot each (nodes /25, ILB /27) and a /20 pod slot, own NSG and route table, own Key Vault
  (`kv-onek8s-gwc-<zone>`), own node pools, own Gateway (class `traefik-<zone>` or `approuting-istio`) and ESO
  (`controllerClass: <zone>`), Cilium CCNP baseline. Internal and external never share a subscription or cluster (D52).
- **Zone nodes only for applications.** Each zone's gateway pods and ESO run on the system pool, so a zone without
  application pods has zero nodes. The system subnet NSG allows 443 from Internet *and* (a separate rule) from
  VirtualNetwork.
- **Spot, architecture and GPUs are the application's choice** (R17), stated only as pod labels `platform/arch`,
  `platform/capacity: spot`, `platform/accelerator: nvidia-gpu` (+ `nvidia.com/gpu`); the policy mutations do the rest.
  A spot pod falls back to on-demand. amd64 and arm64 both offered; aks-hello is amd64 only.
- **No ACNS** (D80): Hubble, FQDN filtering and eBPF host routing are options kept open (design 7.4). eBPF host routing
  (BpfVeth) only at cluster creation ("User-installed iptables rules found" otherwise), through AVM 0.8.5's
  `network_profile.advanced_networking.performance.acceleration_mode`.
- **Private API server everywhere** (D58), runners on the labfw VPN. **No public endpoints** (D60) but the non-prd
  Basic registry (D62).
- **Secrets only through ESO**; vault shares by ABAC prefix `<namespace>--`; gateway certs `<zone>-gateway--wildcard`
  and `platform-gateway--wildcard`. No Secrets Store CSI driver.
- **One policy engine (R14)**: no ValidatingAdmissionPolicies in the fleet; every admission rule is an Azure Policy
  definition.
- **No AKS cost analysis add-on** (D46): cost per team from OpenCost in Grafana's k8s-monitoring; namespaces name their
  owner (R25).
- **Cluster basics**: Azure Linux, SSH off, system pool tainted `CriticalAddonsOnly`, Kubernetes 1.36, auto-upgrade none,
  Free tier only as a lab saving.
- **A hub VNet and Azure Firewall Premium per exposure, no route between them** (D53, plan only; the lab runs labfw).
- **IPv4 only** (D54).
- **No Microsoft Defender** (D81): the company's third-party security tool instead. azure-landing-zone assigns only the
  ALZ policies for what the platform runs on, none of Defender's; Defender for Cloud's own `SecurityCenterBuiltIn`
  assignment was deleted on sub-mgmt and sub-hub with Lab admin (2026-10-19) - delete it again if it reappears.
- **Every policy goes to Deny once it reports 0 non-compliant resources** (D82, the user): ALZ assignments in
  azure-landing-zone, `kubernetes_deny` in its `environments/dev/policy.tfvars`. Key Vault purge protection is a policy
  in prd only (D83).
- **Stateful cluster OS channel is unverified** (V13): `SecurityPatch` tried first, `NodeImage` if refused.

## Lessons learned (gotchas)

- **Changing a cell VNet's address space leaves the hub's peering `RemoteNotInSync`**: new nodes fail CSE
  (`VMExtensionError_OutboundConnFail`). shared/ `hub_to_cell` has `triggers` on the address space; by hand
  `az network vnet peering sync` on the hub side. Subnets moved and created in one apply can race
  (`NetcfgSubnetRangesOverlap`) - re-run.
- **AKS delegates a pod subnet** when the first pool joins it; an update without the delegation fails
  `SubnetMissingRequiredDelegation`, so shared/ states it on every `*-pods` subnet. `maxPods` cannot change on a
  running pool (`PropertyChangeNotAllowed`).
- **AKS's azure-ip-masq-agent** translates pod flows leaving the VNet to the node's address; its optional user
  ConfigMap `azure-ip-masq-agent-config` (kube-system) merges with the reconciled one.
- **A new zone needs its gateway certificate** `<zone>-gateway--wildcard`, or its Gateway is invalid
  (`InvalidCertificateRef`) and Traefik answers 404.
- **Behind labfw, a denied source shows only in labfw's log** (Log Analytics, or `labfw logs --action deny --src <IP>`
  over SSH). Upstreams redirect to CDNs the allow-list must name too (`cdn.registry.k8s.io`,
  `production.cloudfront.docker.com`, `external-secrets.io`). labfw applies a policy change ~2 min after the Platform
  apply (`systemctl kill -s HUP labfw` at once). The fleet's HelmReleases retry forever (`retries: -1`).
- **Kestrel's default `Http1AndHttp2` is HTTP/1.1 only on a plain port**: h2c needs an `Http2`-only port.
- **Cilium DNS rules (ACNS only) must cover the pod's search suffixes** (incl. `<id>.<x>.internal.cloudapp.net`), or
  musl stops resolving. Without ACNS a policy may carry neither DNS rules nor `toFQDNs`.
- **A `Microsoft.Kubernetes.Data` policy rule may test only `type`, `location` and `tags`** of the cluster
  (`InvalidPolicyAliasFormat`, only at apply); scope by `not_scopes`. Custom mutations cannot be parameterized. New
  parameters on an assigned definition need a `defaultValue`. An assignment display name over 128 characters fails
  only at apply.
- **A policy that denies must be checked against what the platform itself writes**: Gatekeeper's audit has no request
  user, and AKS components write into team namespaces (Flux's `<config>-auth/-genkey/-protected-parameters`).
- **An NSG rule takes one service tag**; `Internet` + `VirtualNetwork` in one rule is a 400.
- **Leaving App Routing orphans its per-Gateway objects** (`<gateway>-approuting-istio` Deployment, LB Service, HPA,
  PDB, ServiceAccount): Deploy's apply deletes them for Gateways of another class. App Routing's gateway pods have no
  seccomp profile (gateway namespaces are PSS baseline).
- **The Image Integrity policy's ID also tags `K8sAzureV1PrintMutationsAnnotations`** constraints - filter them out when
  counting signature violations. Its Ratify CRDs are older than Ratify's docs. Notation cannot `notation login` on a
  runner; `az acr login` works.
- **Preview properties are invisible to `az aks show`**: `az rest` with `?api-version=2026-05-02-preview`.
- **Quota errors** show as `ErrCode_InsufficientVCPUQuota` on the cluster PUT. `az vm list-usage` values are strings.
  The `az quota` extension's `--limit-object` is broken; use `az rest` on `Microsoft.Quota/quotas/<name>?api-version=2023-02-01`.
- **Claude on Foundry needs `modelProviderData`** (azapi) and per-subscription quota (0 here).
- **GitHub OIDC**: subjects carry immutable IDs (`repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`);
  transient 503/504s - re-dispatch; long applies outlive the token (AADSTS700024 ~5 min) - sign in again before
  az/kubectl steps that follow a cluster build.
- **Azure refuses two Kustomizations of one Flux configuration on the same path** (`InvalidInputParameter`).
  `az k8s-configuration flux update --suspend` alone is refused - PATCH the property with `az rest`.
- **Flux `valuesFrom.targetPath` parses like `helm --set`** (a numeric ID became `1.872197e+06`): merge a whole YAML
  document; ESO's template data is `map[string]string` (use `index`, not `hasKey`). A substituted `true` becomes a
  YAML boolean - keep such settings non-boolean.
- **Grafana Fleet Management pipelines match the cluster name**: after a rename the collectors get only the survey
  pipelines. **k8s-monitoring on AKS** needs the pod annotation `kubernetes.azure.com/set-kube-service-host-fqdn: "true"`
  on every Alloy collector and kube-state-metrics (offline `helm template` misses it); their Cilium DNS rules must allow
  `*.hcp.<region>.azmk8s.io`.
- **The one 8 GiB system node is nearly full** (~5.8 GiB allocatable, ~2 GiB to spare without istiod and the VPA
  add-on): new system-pool workloads need small requests or node-critical priority. kube-bench pinned with `nodeName`
  must request no resources.
- **An ABAC condition may name only actions its role has** (`InvalidRoleAssignmentCondition`, only at apply).
  `kubectl auth can-i` on an Azure RBAC cluster answers `no - Azure does not have opinion...`: parse the first word.
- **Kubescape numbers CIS section 3 differently from kube-bench's `aks-1.8`**; report.py takes section 3 from
  kube-bench. Microsoft.Security is not registered (Defender plan unreadable = off).
- **A failing `check` block fails `terraform test` runs**. `merge()` of maps with conditional `{}` yields an object:
  wrap in `tomap()`.
- **`az aks command invoke` fails with "Operation returned an invalid status 'OK'"** (Lab admin, 2026-10-19) and Run
  Command over `az rest` needs an Entra ID cluster token: change the cluster through Git or a workflow on the VPN.
- **AKS creates the StorageClasses `default` and `managed-csi-premium-v2` even with every CSI driver off**: Deploy deletes
  them from a stateless cluster after every apply; `no-persistent-storage` refuses them back.
- **Deployment safeguards' `allowedVolumeTypes` defaults to `[]`** (every volume refused) and its warn-only
  `printMutationsAnnotations` reports every mutated pod: the assignment sets the restricted types and
  `effectForWarnOnlyPolicies = Disabled`. Behind labfw a denied TLS flow is reset at its SNI (curl 35) and a denied HTTP
  request gets 470, which the Isolation tests count as blocked; zone pods reach neither IMDS nor 168.63.129.16 (fleet
  `firewall-egress` egressDeny).
- `kubectl debug` has no `-o`; `az aks install-cli` can hit GitHub's rate limit - re-run. Renew Certificate's DNS-01
  can fail once - re-run.
- **A private endpoint's /32 system route beats every UDR**, and `private_endpoint_network_policies = Enabled`
  makes its answers follow the subnet's table: with a table that sends the VNet's address space to a firewall,
  same-subnet clients (the system node → the API server's endpoint) get asymmetric answers and the firewall drops
  them. Never enable it on snet-system (2026-10-20 outage).
- **Credentials handed over in chat** go to the vault with `store-secret.yml`, never into Git or a workflow input.
- The auto-mode classifier refused Run Command on labfw for workflows; read labfw's denials from Log Analytics.
