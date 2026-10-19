# OneK8s - working notes for Claude sessions

OneK8s is an AKS platform design (https://onek8s.github.io, repo `onek8s/onek8s.github.io`) and its
implementation in the `onek8s` GitHub organisation. This file is the shared memory of earlier
sessions: what is deployed, how to operate it, and decisions already made. Keep it current when
something here changes.

## Repositories

| Repo | Role |
|---|---|
| `onek8s.github.io` | The design (`docs/<part>.<page>-*.md`, e.g. `2.3-node-pools.md`, `1.2-requirements.md`, `7.2-decisions.md`, `7.3-open-questions.md`). Code follows it; change it when a decision changes it. **Its sections were renumbered on 2026-10-17** into reading order (onek8s.github.io #58) and then into part.page numbers (#61); both mappings are in that repo's CLAUDE.md - notes and commits before that date cite the old numbers. |
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
| `isolation-tests.yml` | The negative requirement and isolation tests of design section 7.1 on one cell, each tagged with its R-number (summary table): cluster settings, `--admin` refused, platform policies present, probe placed by the mutations alone, cross-zone / cross-namespace / node / IMDS / every vault blocked, FQDN egress, forbidden manifests as server-side dry runs (PASS = refused, AUDIT = rule still in audit), external HTTPS, supply chain (ACR admin/anonymous off, kubelet only AcrPull, Ratify healthy and federated, every ACR image and running app image signed, the policy reports the unsigned probe, Flux webhook refuses a bad signature), Resource Graph public endpoints and local auth against `tests/isolation/allowed-public-endpoints.yaml`, Key Vault ABAC with a token for the namespace's own `key-vault` identity (own secret 200, others 403) and every role of the application identities (`check-key-vault-roles.py`), R6 namespace access (`check-namespace-access.py`: RoleBindings match the tfvars' `groups`, each role's rights by impersonating a group member and signed in as a tester app from `tests/isolation/namespace-access-testers.yaml`), R11 cell settings (AZ, NAP, VPA), R13 sync (Kubernetes version of the tfvars, Flux at the head of Git, `check-cells-in-sync.py`), R15 certificates vault -> Secret -> listener -> served, R16 every zone complete, R2 one exposure per cluster and subscription. **Only when the user asks for it** (2026-10-14: runs take 10-30 min and slowed progress) - no Deploy stage, no schedule; do not dispatch it on your own after a change. |
| `cis-benchmark.yml` (CIS benchmark) | CIS AKS Benchmark of one cluster: kube-bench (`aks-1.8`, Job per node in kube-system, section 3), Kubescape `cis-aks-t1.8.0` from the runner (section 4), the cluster's Azure settings (sections 2 and 5). `tests/cis/report.py` gives one row per recommendation and a score; a failure not in `tests/cis/accepted.yaml` (with its reason) fails the run. **By hand only** (2026-10-14, the user's choice to speed up testing: no schedule, no Deploy stage). |
| `sign-images.yml` (Sign images) | Notation-signs every image in the ACR with `image-signing` in the platform vault (azure-kv plugin, deploy identity); skips what already verifies. Runs after every Deploy apply of dev-shared, and by hand. |
| `renew-certificate.yml` | Let's Encrypt wildcards into the platform vault (5 certs, matrix, max-parallel 1). |
| `vcpu-quota.yml` | Raises the subscription's compute quotas via the Quota REST API, signed in as the org secret `AZURE_OWNER` (owner SPN JSON). `gpu` input: `StandardNCadsH100v5Family` (40 per GPU node, default 0 = leave). |
| `store-secret.yml` (Store secret) | Puts a secret into `kv-onek8s-gwc-platform` (over the VPN) without its value in Git, inputs or logs: `public-key` prints the vault RSA key `secret-transport`'s public key; encrypt the value with it (RSA-OAEP-256, `openssl pkeyutl`, ≤ 446 bytes) and run `store` with the name and base64 ciphertext. Use it for any credential the user hands over in chat. |
| `pr.yml` | CI: fmt, validate, `terraform test`. |
| `lab-power.yml` (Lab power) | Manual: `action` stop / start of the dev cells for a pause (`clusters`, default az2 az3; `firewall`). stop, per cluster: every Flux configuration suspended, Deployments/StatefulSets of the `platform/zone` namespaces scaled to 0 and waited for, NAP off (NodePool cpu limits 0, NAP nodes deleted, mode Manual - a NAP cluster cannot be stopped), `az aks stop`; then labfw's VM deallocated (custom role `OneK8s labfw Power`, azure-landing-zone). start: labfw first (+1 min), `az aks start`, mode Auto, Flux resumed (Git puts the limits and replicas back). Git unchanged. VPN for kubectl (concurrency `labfw-vpn`). |
| `entra-test-groups.yml` (Entra test groups) | Manual, as `AZURE_OWNER`: for a `namespace` and `roles` input, groups `grp-onek8s-dev-<ns>-<role>` (default view edit admin; `platform` + `viewers` for the platform viewers) and tester apps `onek8s-dev-<ns>-<role>-tester` (members, federated with the `dev` environment's subject `repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`). Idempotent; prints the IDs for the tfvars and `tests/isolation/namespace-access-testers.yaml`. |
| `vpn-clients.yml` (VPN clients) | The runners' labfw VPN configs as `dev` environment secrets (GH_OWNER): `copy-runners` (vault -> `LABFW_VPN_GITHUB_RUNNERS`), `new-peer` (key pair -> `LABFW_VPN_<PEER>`, prints the public key for azure-landing-zone `labfw.vpn.peers`). |
| `traffic-flow-docs.yml` (Traffic flow docs) | Manual (design section 5.3, D63): `aks-agent docs traffic` of aks-ai-agents generates the traffic flow pages of a `spoke` (default `dev-int`) - a Mermaid picture + page per application namespace and per zone - from Git alone (azure-landing-zone `firewall-applications/`, this repo's cell tfvars, aks-fluxcd-example's Flux path, the fleet's `policy/egress-allow-lists.yaml`; no Azure, no VPN, no cluster) into a checkout of azure-landing-zone `docs/traffic-flows/`, uploads them as an artifact and prints the findings (rules no configuration names, named destinations without a rule). When a page changed and `dry_run` is off, the documentation agent (model on Foundry: azure/login + labfw VPN, so the lab must be running) explains the findings and opens ONE PR to azure-landing-zone with GH_OWNER. `aks-agent docs traffic ... --check` fails when the pages are stale. |
| `lab-admin.yml` (Lab admin) | Manual, **last resort**: runs ONE `az` (as `AZURE_OWNER`, on the dev subscription) or `gh` (with `GH_OWNER`) command; `args` split like a shell, no pipes (use `--query`/`--jq`). For special changes nothing else covers (Entra ID, Graph, org/repo settings). The run log is readable by anyone who can read the repo: never print a secret. |

**Owner credentials (lab only, last option, allowed whenever needed):** `AZURE_OWNER` - org secret, `az ad sp
create-for-rbac` JSON of an SPN that is Owner on the lab subscriptions and **Global Administrator** of the lab
tenant (so Graph works: groups, apps, role assignments); `GH_OWNER` - org secret, a GitHub admin token of the
onek8s organization. Use them through `lab-admin.yml`,
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

## Current state of dev (2026-10-15)

- **The root module is the OneK8s cell and nothing else (2026-10-19, the user's ask: simplify the code like the design):**
  removed the paths no environment used and the design rules out - AKS Automatic (`sku_name`, system-assigned identity,
  hosted system profile, Azure's default-CIDR overlap case), clusters without a network (`virtual_network_name` and
  `node_subnet_name` are required), Kubernetes RBAC mode (`azure_rbac_enabled`), public API servers
  (`private_cluster_enabled`, `api_server_authorized_ip_ranges`), API Server VNet Integration (root `api_server_*`, shared
  `cells.<cell>.api_server_subnet` and `snet-apiserver`; H14), a bring-your-own private DNS zone (`private_dns_zone_name`,
  `fqdn_subdomain`), `dns_zone_create` in the root, `lock_kind`, `cluster_timeouts` (90 min, fixed), `enable_telemetry`,
  `create_role_assignments` (root and shared: every grant is made here), `role_assignment_propagation_delay` (60 s, fixed),
  `network_role_assignment_scope` (derived: the VNet with NAP or zone pools, the system subnet otherwise), the
  `*_resource_group_name` of what shared/ creates (always `resource_group_name`), `cost_analysis_enabled` (D46: off),
  Flux credentials for private repositories (`flux_git_credentials`; every repo is public), `managed_namespaces[*].access`
  (Azure RBAC per namespace; `groups` since D49 - the `namespace_user` grant of each group stays, same state keys),
  the root's own-vault path (`key_vault_create`: every cluster uses shared/'s vaults - key_vault.tf is the lookup and the
  federated credentials), the Flux GitHub webhook and the platform gateway (`flux_github_webhook`, `platform_gateway_enabled`,
  shared's `flux_github_webhook_namespaces`, the Flux webhooks workflow; D70) and the Dapr extension (`dapr.tf`, D65).
  `moved` blocks keep the identity and the propagation sleep at their state addresses; the `random` provider is gone.
  The stateful tfvars now states a private API server (D58) instead of a public one. Verified: Deploy plans of
  dev-shared, az2 and az3 on the branch - see the PR. The design's option E (D75, AKS Automatic per zone) is a path, not
  code: a cluster per zone with its own spoke would be a module of its own when decided (D64).
- **Lab results 2026-10-18 (all verified with Cluster status, which now checks the edge per route as a VPN client and lists
  each constraint's excluded namespaces):** **D73 applied** (zone route tables `rt-<cell>-<zone>` + Network Contributor on
  them in az2/az3): routes 200, `/weather` 200 through labfw on both cells, Flux all Ready - cross-zone denial (V31) not tested
  yet. **V28 holds**: `/status` `"protocol":"HTTP/2"` through Traefik - but only since **aks-hello 0.5.2** (h2c on its own port
  8081 `Http2`, HTTP/1.1 on 8080 for the probes; the Service targets port `h2c`): Kestrel's default `Http1AndHttp2` is
  HTTP/1.1 only on a plain port, so 0.5.1 behind `appProtocol: kubernetes.io/h2c` answered 500 on every route. **V30 holds**
  (TLS 1.2 refused, TLS 1.3 negotiated). **V29 fails**: `curl --http1.1` gets HTTP/1.1 200 - Go's crypto/tls lets an
  `http/1.1` client connect to an `h2`-only server without ALPN (golang/go#46310), so `alpnProtocols: [h2]` cannot refuse it;
  D70 needs option (c) (426 at the HTTP layer) or another proxy - **the user's decision, not taken**. Dapr on az3 was never
  installed and the trial is off since (see the az3 bullet below). Firewall policy (azure-landing-zone #89): `rcg-build-tenant`
  network rules before application rules ("Invalid rule priority"), `management-vpn` 443 to every cell's snet-system (API
  servers) + the management API PE subnet + jump host, SSH only to the jump host (`management-vpn-ssh`).
- **az3 is a pod-subnet cell (design D74, rebuilt 2026-10-18, the user's ask)**: Azure CNI Pod Subnet with dynamic IP
  allocation + Cilium (ACNS as before: FQDN + eBPF host routing, Hubble off), **no NAP** (refused with a pod subnet,
  karpenter-provider-azure issue 1351). Layout (the user's): nodes and ILBs in /24 slots of `address_space`
  10.100.0.0/16 like any cell (snet-system 10.100.0.0/24 - also the API server's private endpoint -, int-fi 10.100.1.0/24,
  int-se 10.100.2.0/24, ILB 10.100.2.128/27), pods in `pod_address_space` 100.64.0.0/16, a /20 per slot (`snet-system-pods`
  100.64.0.0/20, `snet-int-fi-pods` 100.64.16.0/20, `snet-int-se-pods` 100.64.32.0/20). shared/ `cells.<cell>` =
  `{ pod_network = "pod-subnet", pod_address_space = ... }` (the old `"subnet"` mode is gone): pod subnets get their
  pool's NSG rules, the `pods` rule lists the pod subnets, zone tables `rt-<cell>-<zone>` sit on the zone's node and pod
  subnets and route the other zones' node and pod slots to labfw. Root: `default_node_pool.pod_subnet_name`,
  `isolation_zones.<zone>.pod_subnet_name`, `zone_node_pools` (per zone `<zone>`, `<zone>spot`, `<zone>arm`,
  `<zone>armspot`, 0..max, labels/taints `platform/zone` + `platform/capacity=spot` like the NodePools; cluster autoscaler
  with the `priority` expander; Network Contributor on the VNet). Fleet: no `node-pools-int-se`, `autoscaler-priority`
  (ConfigMap `cluster-autoscaler-priority-expander`, spot first), `pod-addresses-to-firewall` stays. Landing zone: the zone
  IP groups list 10.100.x/24 too, SNAT private ranges include 10.100.0.0/16, the spot mutations also tolerate/prefer
  AKS's `kubernetes.azure.com/scalesetpriority=spot`. Lab Power's start skips NAP for a cluster with autoscaled pools.
  Quotas: Daldv6 8 (system node 4 + two D2alds_v6), low-priority 3 (one spot D2alds_v6). V32 (spot fallback, labfw's log
  naming the pod) still to verify.
- **Dapr trial: off (2026-10-18, the user's ask)** - removed from az3's tfvars and the fleet's az3 directory; `dapr.tf` went
  with the simplification below (2026-10-19); the fleet's unused `infrastructure/dapr` and the landing zone's `dapr-system`
  platform namespace stay for a later trial.
- **Zone-to-zone traffic through the hub firewall (2026-10-18, design D73, the user's ask): applied 2026-10-18** (#193; traffic verified, V31 cross-zone denial not tested yet).
  Until now `rt-<cell>` (0.0.0.0/0 -> firewall) sat on the system and every zone's node subnet, and traffic between
  the slots of one cell took the VNet's own system route (more specific than /0), so the firewall never saw it and
  only NSG + Cilium separated the zones - against what R5, section 2.4 and the isolation tests claimed. Now
  (shared/cells.tf) the system subnet keeps `rt-<cell>` with the default route alone, and every enabled zone's node
  subnet gets `rt-<cell>-<zone>` (naming type `route_table`, `{name}` = `<cell>-<zone>`): the default route plus a route
  per OTHER zone slot 1-14 (occupied or free, named `<zone>-via-hub-firewall` or `slot-<n>-via-hub-firewall`) to
  `hub.next_hop_ip`; never the zone's own slot (Azure applies a UDR to intra-subnet traffic too), never slot 0 (the
  system pool: kubelet tunnel, metrics-server, API server PE stay direct) or slot 15. The root module grants the cluster
  identity Network Contributor on each zone's table (`route_table_<zone>` scopes, locals.tf). Apply: the node subnets'
  associations move to the new tables (replace: a few seconds without a route table on the zone subnet - do it
  while the lab is quiet). Expected after apply: `int-fi` nodes/pods -> another zone's slot (az2 has only int-fi, so
  test with az3's int-se slot inside az3, or a second zone) denied and logged by labfw; cilium-health between zones
  fails (optional flow, design 2.4 ⑦). Overlay pods (100.201.0.0/16) are routed by Azure's overlay domain, not by UDRs:
  cross-zone pod-to-pod in an overlay cell stays Cilium's alone; in az3 (`pod_network = "pod-subnet"`) the pods carry the
  zone's addresses and the firewall sees them. Verify = design V31; azure-landing-zone needs no rule (default deny), but
  labfw must forward hairpinned traffic back into the same spoke - check its forward chain.
- **Naming policy (2026-10-18, design D72, the user's ask): built and verified** - Deploy plans of dev-shared, az2 and az3
  on 2026-10-18 changed no infrastructure (only the new `names` outputs; az3's one add is the pending Dapr trial). `modules/conventions` `naming` (both
  stacks' variable `naming`): a template per resource type (`resource_group`, `key_vault`, `container_registry`,
  `log_analytics_workspace`, `user_assigned_identity`, `virtual_network`, `network_security_group`, `route_table`,
  `private_endpoint`, `network_interface`, `disk_encryption_set`, `consumption_budget`, `traffic_manager_profile`,
  `ai_services`) over `{environment}`, `{exposure}`, `{location}`, `{location_code}`, `{name}`, `{domain}`, plus
  `location_codes`; **defaults = the lab's names** (shared/tests/naming.tftest.hcl asserts them; a run against the real
  dev.tfvars matched every name), so dev.tfvars no longer states `resource_group_name`, `key_vault_name`,
  `zone_key_vault_names`, `container_registry_name` (now `container_registry_create = true`), `log_analytics_workspace_name`
  (`log_analytics_workspace_create = true`) or `ai_foundry.name`; every enabled isolation zone gets its vault. A variable that
  names a resource still wins. The real estate's policy stays out of Git: `dev` environment secret `NAMING_POLICY` (JSON
  `{"templates": ..., "location_codes": ...}`) - Deploy writes it to `naming.auto.tfvars.json` and masks the templates' fixed
  parts; Renew certificate resolves unstated names with `scripts/policy-name.sh`. Not on the policy: a
  cluster's own name, subnets, child resources, the landing zone's resources; the other lab workflows still hard-code the lab's
  names. The cluster stack has `environment` for cluster names without it in the second segment.
- **TLS 1.3 only at the edge (2026-10-18, design D71, the user's decision): in the lab, V30 holds (see the results above).** The same ConfigMap sets
  `tls.options.default.minVersion: VersionTLS13`; `curl --tls-max 1.2 https://hello.int-fi.dev.onek8s.lol/` must fail in the
  handshake, plain `curl -v` shows `TLSv1.3` and, with a curl built on a library that offers X25519MLKEM768, the hybrid
  post-quantum key exchange (Go 1.25 default). Policy `gateway-tls` (azure-landing-zone, audit) reads the ConfigMap back:
  ALPN exactly `[h2]`, `minVersion` `VersionTLS13`. Traffic Manager's probe TLS version is undocumented (V30 on the first
  external cell; TCP monitoring is the fallback).
- **HTTP/2 only at the edge too (2026-10-18, design D70, the user's decision): in the lab, but V29 FAILS (Go's ALPN fallback, see the results above).** `gateways/traefik/release.yaml`
  mounts a file-provider ConfigMap `traefik-dynamic` whose `tls.options.default.alpnProtocols` is `[h2]`: a client announcing
  `http/1.1` is refused in the handshake; a client without ALPN still gets HTTP/1.1 (V29 measures). Reaches az2/az3 through the
  `traefik-<gateway>` Flux configurations at the next Lab power start. Verify over the VPN: `curl --http1.1 -sv https://hello.int-fi.dev.onek8s.lol/`
  must fail with `no application protocol`; plain `curl` (h2) must answer 200. If routes stop answering, the Gateway API provider
  did not take the `default` option - check Traefik's log for the file provider and the option name. Consequence recorded in the
  design: Traefik in every environment until App Routing can refuse HTTP/1.1; the platform gateway and the Flux webhook
  code is gone from this repo since 2026-10-19 (the simplification below; the fleet's `platform-gateway/`, `flux-webhook/`
  go with backlog item 7). Policy `h2c-upstream` (azure-landing-zone)
  holds every application Service port to `appProtocol: kubernetes.io/h2c`, audit first.
- **HTTP/2 upstream (2026-10-18, design D69, "HTTP/1.1 must die"): in the lab with aks-hello 0.5.2, V28 holds (the steps below are done).** aks-fluxcd-example's aks-hello Service
  carries `appProtocol: kubernetes.io/h2c` (merged, #37; reaches az2/az3 at the next Lab power start). aks-hello **0.5.1**
  (#15, merge commit b3b282ca272b3554fc39c90479bc76d9bc688543) reports `protocol` in `/status`. Steps when the lab is back:
  (1) `shared/envs/dev.tfvars` `container_registry_builds` entry `"aks-hello:0.5.1"` with that commit, Deploy `dev-shared`
  apply (builds and signs it); (2) aks-fluxcd-example overlays `newTag: 0.5.1`; (3) Cluster status `route_path: /status` on az2
  (Traefik) - expected `"protocol":"HTTP/2"` (V28); if `HTTP/1.1`, Traefik ignored the standard value - try `appProtocol: http2`
  or report it; a 503 means the pod did not speak h2c. (4) azure-landing-zone: write the `h2c-upstream` policy (every Service
  port an HTTPRoute references declares `appProtocol: kubernetes.io/h2c`; audit first - boot-log's busybox httpd is the known
  finding) and the fleet's CI check. The kubelet's httpGet probes stay HTTP/1.1 until 1.38 (`protocol: HTTP2`, KEP-5999).
- **Traffic flow documentation (2026-10-17, design section 5.3, D63 proposed)**: the first pages of `dev-int` are committed in
  azure-landing-zone `docs/traffic-flows/` (generated with `aks-agent docs traffic`, see the workflow row above). First finding:
  `stats.grafana.org` is allowed for both int-fi-example and int-se-example but nothing in aks-hello's configuration names it
  (the egress agent proposed it as "a plausible public API for metrics", a human merged azure-landing-zone's PRs) - either a
  hidden dependency of the image or a flow of something else on the node (az2 attributes node addresses to the application pods
  on it). **Settled 2026-10-17 (the user)**: it is Grafana's anonymous usage statistics (Alloy, Beyla, k8s-monitoring on every
  node) - a platform flow, now in azure-landing-zone `firewall_exposures.int.environments.dev.observability_fqdns` (rule
  `observability`, every cell) and removed from both application files. Regenerate after a rule or application change (the workflow, or the CLI locally with the
  four repos checked out side by side); the pages have no timestamp, so an unchanged world changes nothing.
- **The lab is RUNNING again since 2026-10-18** (Lab power start run 39107097559, the first full start: it needed #187, a second
  sign-in before kubectl, and #188, start only a stopped cluster, so a start can be re-run). Left running for further tests.
- **Run Deploy stacks one at a time**: every stack joins the labfw VPN as the one peer `github-deploy`, and parallel runs broke
  each other's tunnel (2026-10-18: a truncated state read, "connection refused" to a vault's private endpoint).
- (History) **The lab was stopped for the weekend (2026-10-16, Lab power run 38904999392, the user's ask: minimal cost, nothing
  removed)**: az2 and az3 `powerState Stopped`, labfw `deallocated` (no VPN: every data-plane workflow fails until the
  start), every Flux configuration and Kustomization suspended, the zone namespaces' Deployments at 0 (apps, and the
  zones' Traefik gateways and ESO - their namespaces carry `platform/zone` too), NAP `Manual` with every NodePool's cpu
  limit 0. **Bring it back with `Lab power` `start`** (labfw first, `az aks start`, NAP Auto without default pools,
  annotated replicas restored, Flux resumed, every HelmRelease force-reconciled); never undo those by hand. The sequence
  is the user's (2026-10-16): pause Flux, scale down in the cluster, wait, autoscaling off, stop - because **a NAP
  cluster cannot be stopped as it is** ("You can't stop clusters which use the NAP feature",
  learn.microsoft.com/azure/aks/start-stop-cluster; the system pool cannot scale to 0 either). Verified in that run:
  `az aks update --node-provisioning-mode Manual` is accepted once no NAP node or VM is left (~3 min), `az aks stop`
  then stops in ~5 min, the whole stop of two cells took 22 min. aks-fluxcd-example `lab/scale/kustomization.yaml` (a
  kustomize component every cell directory includes) is an independent Git-only switch for aks-hello's replicas (2 =
  running, what Git says now; 0 = off with the clusters running; the rollout guardrails allow 0).
  **The start path is untested**: a test `start` of az3 (run 38908224078) was cancelled by the user after labfw and
  `az aks start` had been issued - the user stopped az3 and labfw by hand (2026-10-16) and fixes the start next week if
  it fails. A stop re-run is idempotent (a cluster already Manual / suspended / at 0 is skipped step by step).
- **The registry is Basic and public again (2026-10-16, design D62, the user's ask: Premium is too much for a lab)**:
  shared/ `container_registry_sku` defaults by environment - Premium (private endpoint, data endpoint, no public access)
  in `prd` only, Basic on its public endpoint (Entra ID only, admin off) below it. dev's `acronek8sdev` was downgraded in
  place from Premium (its private endpoint removed); the labfw VPN action no longer pins its names, the isolation tests'
  `allowed-public-endpoints.yaml` lists it, the hub firewall's `container-registry` rule (azure-landing-zone, `*.blob.core.windows.net`
  for the layers) was already written for a public Basic registry.
- **No public endpoints (2026-10-16, design D60, the user's ask)**: vaults (firewall Deny + trusted bypass), ACR
  (was Premium with a private endpoint incl. data endpoint until D62 above), Foundry, the state account
  `stonek8sdevtfstate` (Entra ID only: backend `use_azuread_auth`; apply identity has Storage Blob Data Contributor) and
  `log-dev-platform` take **no public network access** (shared/ `private_endpoints.public_network_access = false`; endpoints
  in snet-shared-pe 172.20.2.0/26, hub zones incl. Foundry/blob). Log Analytics + DCE through the landing zone's hub
  **Azure Monitor Private Link scope** `ampls-hub-germanywestcentral` (endpoint in management snet-pe, 10.0.8.138; Open mode);
  labfw's workspace/DCE also private. **Every data-plane workflow joins the labfw VPN first**: Deploy on peer
  `github-deploy` (10.0.12.12, secret `LABFW_VPN_GITHUB_DEPLOY`), the rest on `github-runners` (secret
  `LABFW_VPN_GITHUB_RUNNERS`, concurrency group `labfw-vpn`) - GitHub `dev` environment secrets made by `vpn-clients.yml`
  (a private vault cannot hold its own VPN credential). The action pins the private names labfw's DNS answers into
  /etc/hosts (systemd-resolved routing domains did not work on runners). **KMS data encryption** (preview,
  `customer_managed_keys.kms_data_encryption`, kms.tf, azapi beside AVM) with `key_vault_network_access = "Private"` on az2
  and az3: classic KMS needs VNet integration for a private vault (refused, H14). Switching took two applies (on with
  Public, then Private) and AKS rewrites every Secret as `aksService` (exempted in `secrets-via-eso`, azure-landing-zone
  #69). Remaining public: labfw's IP (VPN/SNAT), AKS-managed node OS disks and extension Private Link scopes, the ALZ
  bootstrap state account (builds labfw itself). **Lab admin's runner is not on the VPN**: it cannot query Log Analytics
  or read vaults any more. Break glass: ARM stays public - `az ... update --public-network-access Enabled`.
  **onek8s/azure-lab-fw must stay public**: the labfw VM downloads its release anonymously (a private repo gives 404; the
  user tested it 2026-10-16 and made it public again). labfw's reconfigure skips the download of an installed release.
- **az2 is overlay + the hub firewall only, without ACNS (2026-10-16, design D61, the proposed default)**: rebuilt with
  `advanced_networking = null` (ACNS, eBPF host routing and Hubble off - decided at creation). The fleet patches az2's Cilium
  policies to layer 4 (no DNS proxy) and adds `firewall-egress-int-fi`; aks-hello 0.5.0 (Helsinki forecast, public IP from
  api.ipify.org at start - since 2026-10-16; `/public-ip` "Connection reset by peer" until labfw allows it) runs on int-fi's zone nodes from aks-fluxcd-example `firewall-egress-int-fi/`. labfw sees the zone's node addresses
  (172.22.17.x), denies api.open-meteo.com, and the egress agent attributes a zone node's address to the application pods on
  it (`node_candidates`, flows marked `viaNode`): it opened **azure-landing-zone#71** (int-fi-example -> api.open-meteo.com) -
  left open for the user. Verified: routes 200 through the int-fi ILB as a VPN client, `/weather` "Connection reset by peer".
  Gotchas: the runners' VPN routes needed int-fi's zone ranges (172.22.17.0/24) for its ILB; Cluster status reaches routes
  through the gateway's ILB (pod addresses are not routable with an overlay) and has `cilium_drops` (Cilium's drop monitor,
  for cells without Hubble). The model needs each flow's `cluster` (it passed the zone as cluster once); a blocked run no
  longer declines its flows, and `forget_declined` retries ones the model passed on (declined for a day otherwise).
- **az3, the firewall-egress cell (2026-10-15, design D59 - NOT decided, both models under test, H15)**:
  `aks-dev-int-stateless-az3`, zone 3, **Sweden's int-se only** (int-se enabled in shared/; az2 keeps int-fi). No overlay:
  `network_profile.network_plugin_mode = "none"` - since 2026-10-18 Azure CNI Pod Subnet (D74, see the pod-subnet bullet
  above; it was Azure CNI node subnet with NAP until then), every pool `max_pods = 250` (110 until 2026-10-18 - wrong: az2 runs AKS's overlay default of 250; dynamic allocation reserves nothing). Pods keep their addresses to labfw: the fleet's `pod-addresses-to-firewall` sets AKS's
  `azure-ip-masq-agent-config` to translate nothing; `infrastructure/zones/firewall-egress` lets int-se's apps out to `world`.
  labfw decides from azure-landing-zone `firewall-applications/<env>-<exposure>/<namespace>.yaml` (zone IP group as source),
  SNATs everything leaving 10.0.0.0/16, 10.100.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10. aks-hello 0.5.0 in int-se-example
  (aks-fluxcd-example `firewall-egress/`) fetches a Stockholm forecast from api.open-meteo.com every minute: denied by labfw
  from 100.64.32.x (verified 2026-10-15; `/weather` says "Connection reset by peer"); 0.5.0 also asks api.ipify.org once at start
  for the node's public IP (`/public-ip`), a second dependency for the same rule. labfw's denials go to Log Analytics
  (`log-labfw-germanywestcentral`, table `LabfwFirewallLog_CL`, Azure Monitor Agent on the VM; ~10 min latency).
- **Egress agent** (aks-ai-agents `egress-agent`, workflow `egress-agent.yml`, by hand only - it opens PRs with GH_OWNER):
  denied flows from that table (dev identity's Reader on sub-hub), `pods_by_ip` over the VPN, one PR per namespace to the
  landing zone. Model: **gpt-4.1-mini** on Foundry `ais-onek8s-dev-agents` (swedencentral, Entra ID; created by the user,
  imported as `ai_foundry.openai_deployments`; aks-ai-agents `model.provider: azure-openai`, openai_compat.py) - Claude
  Sonnet 5.5 there is attested as OneK8s/FI but **not deployed: 0 Foundry quota for every Claude model** (`deploy = false`).
  First real run 2026-10-15 opened **azure-landing-zone#66** (int-se-example -> api.open-meteo.com, 10 turns) - left open
  for the user's review: merging it allows the weather traffic. gpt-4.1-mini looped on guesses until `application_source`
  and the repeated-call guard; keep instructions step by step for it. **No token waste** (aks-ai-agents egress.py,
  `aks-agent egress new|propose`): only what was ingested after the last processed ingestion time (checkpoint), never more
  than `max_lookback_hours` (3) back (2026-10-16, the user's ask); only denials unless `include_allowed` (for a firewall that
  still allows by default; labfw logs denials only - azure-landing-zone `labfw.log_analytics.denied_only`). It is a
  workflow on a GitHub-hosted runner, dispatched by hand, not a running service. State in the Actions cache remembers proposals (pending until
  the PR merges/closes; merged 1 h, rejected 7 d), sources' namespaces and ignored sources (nodes, platform pods) - known
  flows are dropped before cluster access and the model sees only new, unproposed flows (verified: re-runs end at
  "new to look at: 0" or "to propose: 0", no model call). **Do not merge the agent's PRs: the user validates them.**
- **Grafana `cluster` label**: Fleet Management's k8s pipeline `k8s_monitoring_k8s_monitoring_aks_dev_stateless_az1` sets
  `cluster` from `CLUSTER_NAME` but matched only `cluster="aks-dev-stateless-az1"`, so az2/az3 got only the survey pipelines
  (`k8s_cluster_name`, no `cluster`). Workflow `fleet-management.yml` `match-clusters` fixes the matcher
  (`aks-dev-int-stateless-.*`) once the vault secret `flux-system--grafana-cloud` has `fleet-management-write-token`; the
  collectors' token gets 401 on UpdatePipeline. Not changed yet.
- **VPN clients reach az3's int-se gateway**: labfw's client routes include 10.100.0.0/24, 10.100.2.0/24 (since D74) and the pod /20s;
  `hello.int-se.dev.onek8s.lol` -> the int-se ILB (100.64.40.4 before the rebuild, now in 10.100.2.128/27) via labfw DNS, HTTP 200 over the VPN (Cluster status "as a VPN client").
- Cluster status has `route_path` (e.g. `/weather`): every route through its gateway pod over the VPN.
- **The lab moved (2026-10-15, design D57)**: after the Lab reset (azure-landing-zone, `skip_policies` off) the build
  tenant runs in **germanywestcentral** (the ALZ bootstrap stays in swedencentral) as the **internal exposure**:
  `sub-aks-dev` plays `sub-aks-dev-int`, `exposure = "int"`, Finland only (`int-fi`; `int-se` defined with
  `isolation_zones.<zone>.enabled = false`). Cells `dev-int-stateless-az1` (172.22.0.0/20, **disabled** with
  `cells.<cell>.enabled = false`: logical zone 1 of germanywestcentral is `NotAvailableForSubscription` for every VM size
  in sub-aks-dev) and `dev-int-stateless-az2` (172.22.16.0/20, zone 2, **the running cell**). Stacks/workflows:
  `dev-int-stateless-az1|az2`, `dev-int-stateful`; the `dev-ext-*` tfvars are gone (fleet keeps its `clusters/dev-ext-*`).
- **Network: azure-landing-zone mode `labfw` = firewall mode with labfw** (VM `labfw-fw`, Standard_B2ats_v2, 10.0.1.4,
  public IP 4.184.103.12, `rg-hub-labfw-germanywestcentral` in sub-hub; enforces `afwp-hub-int-germanywestcentral` + parent).
  shared/ `hub`: cells peered with `vnet-hub-germanywestcentral`, route table `rt-<cell>` 0.0.0.0/0 -> 10.0.1.4 on the system
  subnet and `rt-<cell>-<zone>` (0.0.0.0/0 + the other zones' slots -> 10.0.1.4, D73) on each zone's node
  subnet, VNet DNS = labfw's DNS proxy, internal private DNS (`int-fi.dev.onek8s.lol`) also linked to the hub. Clusters
  `outbound_type = "userDefinedRouting"`; the cluster identity gets Network Contributor on the route tables. Cell egress
  allow-lists: parent `rcg-platform` (AKS FQDN tag, `AzureCloud.germanywc` 443 - service tags use the short region name,
  `service_tag_region`; the long one matched nothing and labfw sent the no-SNI API server traffic to its app proxy, which denied it -
  `platform_source_fqdns` = chart/image sources) + child `rcg-aks-dev` (vaults, ACR, Grafana, zone lists). A denied
  flow shows in labfw's logs (azure-lab-fw view-logs or `labfw logs --action deny` via Run Command).
- **No public entry point in the internal cell**: a public LB cannot answer behind labfw (asymmetric routing), so
  no platform gateway and no Flux webhook (Flux polls every minute; the code for both was removed 2026-10-19). The fleet's `flux-system-key-vault` Kustomization gives flux-system its SecretStore.
  Traffic Manager: only for a deployed external zone (`global_hostnames.<name>.zone`), so none now.
- **Vaults `kv-onek8s-gwc-platform` and `kv-onek8s-gwc-int-fi`** (kv-onek8s-dev-platform is soft-deleted with purge
  protection in swedencentral until 2027-01). Store secret / Sign images use the new one. ACR `acronek8sdev` kept its name.
- **System node `Standard_D4alds_v6` with `os_disk_type = "Ephemeral"`** (no Premium SSD; quota family
  `standardDaldv6Family`). Quotas in germanywestcentral (sub-aks-dev): regional 38, Dpsv6 16, Daldv6 8, low-priority 3
  (a raise was throttled). sub-hub: Basv2 4 (raised for labfw).
- **Identity**: the landing zone recreated `id-aks-dev-apply-germanywestcentral` (client ID b975d49a-...); this repo's
  `dev` environment AZURE_CLIENT_ID was set to it with Lab admin (gh). Do the same after any rebuild of sub-mgmt.
- **labfw VPN** (WireGuard, UDP 51820 on 4.184.103.12): peer `olli-1` 10.0.12.10 (public key in azure-landing-zone
  terraform.tfvars, private key in `kv-onek8s-gwc-platform` as `labfw-vpn--olli-1-private-key`). The pool counts as
  management: API server private endpoints, jump host, the cells' 443 (int-fi gateway); DNS 10.0.12.1.
- **Internal app names by home cell** (2026-10-15, design section 3.1): `hello.int-fi.dev.onek8s.lol` (aks-fluxcd-example
  `apps/aks-hello-home`) next to the per-cell `hello-<cluster>...`. Every route carries `platform/home-cell: <cluster>`;
  external-dns-int publishes only routes naming its own cluster (`--annotation-filter=platform/home-cell=${cluster_name}`).
  The tfvars' `managed_namespaces.<ns>.flux.substitute.home_cell` (the same in every cell) stands in for the placement
  artifact. Not a true/false value: kustomize drops the quotes and a substituted `true` became a YAML boolean, which
  the API server refused. Not built yet: shared txt-owner-id + upsert-only (migration), a policy against the annotation.
- **labfw SSH and ping**: `ssh azureuser@10.0.12.1` over the VPN from `labfw.ssh.sources` (olli-1) with
  `labfw.ssh.authorized_keys` (azure-landing-zone tfvars); no NSG rule. Ping: firewall rule `management-ping-cells`
  plus the node subnets' NSG ICMP from labfw's address only - nodes answer; internal LBs and private endpoints never do.
- **Isolation tests** were only renamed mechanically for the internal one-zone cell (cross-zone, external HTTPS, R2
  steps still assume the external two-zone lab) - adapt before the next run.
- The notes below describe the external lab in swedencentral before 2026-10-15 unless they say otherwise.
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
  then Cluster status on it (Isolation tests only if the user asks). Do not rebuild it unless asked.
- **VPA add-on off in the dev cells** (2026-10-14, lab cost exception, the user's choice): `vertical_pod_autoscaler_enabled
  = false` in the stateless tfvars (default stays true, design section 2.3) - its ~2.4 GiB of requests (2 recommenders,
  2 updaters, 2 admission controllers) kept a cell off one 8 GiB system node. aks-hello's `VerticalPodAutoscaler`
  (`InPlaceOrRecreate`, RequestsOnly, CPU 3m-20m, memory 64Mi-128Mi) stays in aks-fluxcd-example `apps/` but
  `stateless/` deletes it with a patch (no CRD without the add-on). Isolation tests: R11 VPA follows the tfvars,
  the VPA dry runs are AUDIT without the CRD. To bring it back: tfvars true, drop the patch, `node_count = 2`.
- **Production defaults, lab savings in one block** (2026-10-15, the user's ask): variables.tf defaults are the
  production settings (`sku_tier = "Standard"`, `gateway_implementation = "approuting-istio"`, VPA on,
  `advanced_networking = {}`, system pool 2 x Standard_D4ds_v5 on `AzureLinux`); the dev tfvars state every
  departure in a "Non-production cost savings" block at the top (Free, traefik, VPA off, Hubble off, 1 x D4als_v6).
  README "Production defaults and non-production cost savings". The stateful tfvars state `gateway_implementation =
  null` (R9a, not a saving). A non-Cilium cluster must now say `advanced_networking = null`.
- **Hubble off in the dev cells** (2026-10-15, D56, the user's choice, lab cost exception): `advanced_networking =
  { observability = false }` in the stateless tfvars - ACNS stays on for FQDN policies and eBPF host routing (the
  isolation design needs both); no hubble-relay, flow logs or Hubble metrics. Bring back by dropping the line (in place).
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
  gateway namespaces on baseline PSS. Follow-ups in the design (section 7.1, "CIS benchmark").
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
- **Soft multi-tenancy** (2026-10-14, design section 2.5/2.6, D50): the ABAC conditions gate `readMetadata` too, so
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
- **Backlog**: 17 items in priority order in design section 7.1 ("Backlog, in priority order", 2026-10-17), four
  tiers: A now (1 promote the remaining policies to deny, 2 a real Azure Firewall and the external hub in `firewall`
  mode, 3 what the private API server and private endpoints left open), B before acceptance (4 version pipeline,
  5 agents on the build tenant, 6 the rest of the internal exposure, 7 the external exposure back with two cells for
  the cross-cell tests, 8 CIS follow-ups, 9 observability completion, 10 backups, 11 manifest CI checks, 17 traffic
  flow documentation follow-ups), C phase 3 (12 open verifications and acceptance tests, 13 pentest / review),
  D on trigger (14 stateful cluster, 15 WAF, 16 image promotion tests). Pick from the top unless the user says
  otherwise; update the list there when an item is done.
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
  (`aks-extsespot-*`, Standard_D2ps_v6 spot, arm64) and stays there (hubble-relay joined it until D56 turned Hubble off); NAP cannot consolidate it.
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
- **Private API server in dev too** (2026-10-15, D58, the user's ask; the public API server was a lab exception before):
  a classic private cluster over **Private Link** (endpoint in `snet-system`), `private_dns_zone_mode = "none"` + public
  FQDN (resolves to the private IP; an AKS-managed zone would be linked only to the cell VNet, which resolves through
  labfw in the hub - CIS 5.4.2 accepted for that). **Not API Server VNet Integration**: Azure refuses it on an encrypted
  VNet with v4+ VM sizes (`VNetEncryptionNotCompatibleWithAPIServerVNetIntegration`); shared/ `cells.<cell>.api_server_subnet`
  (off) would add the delegated `snet-apiserver` for it. A public cluster cannot be made private in place without VNet
  integration: the cell was rebuilt. **GitHub-hosted runners join the labfw VPN** (`.github/actions/labfw-vpn`, peer
  `github-runners` 10.0.12.11 - config in the `dev` environment secret `LABFW_VPN_GITHUB_RUNNERS` since D60, Deploy on its
  own peer) before kubectl; one peer, so Cluster status, Isolation tests, CIS and the other VPN workflows share the
  concurrency group `labfw-vpn`. If labfw's public IP or key changes, re-run `vpn-clients.yml`.
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
  tainted `CriticalAddonsOnly`, Kubernetes 1.36, auto-upgrade none, Free tier in dev (Standard is the default).
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

- **Changing a cell VNet's address space leaves the hub's peering `RemoteNotInSync`** (2026-10-18, az3's 10.100.0.0/16
  added): the hub routes nothing to the new range, so new nodes fail CSE with `VMExtensionError_OutboundConnFail`
  (aka.ms unreachable). shared/ `hub_to_cell` now carries `triggers` on the cell's address space, which syncs it; by hand:
  `az network vnet peering sync` on the hub side. Subnets moved and created in one apply can also race
  (`NetcfgSubnetRangesOverlap`) - re-run the apply.
- **AKS delegates a pod subnet** (`aks-delegation` to `Microsoft.ContainerService/managedClusters`) when the first pool
  joins it, and an update without it fails `SubnetMissingRequiredDelegation`: shared/ states it on every pod subnet.

- **Azure CNI node subnet gives 30 pods a node** unless `max_pods` says otherwise, and `maxPods` cannot change on a running
  pool (`PropertyChangeNotAllowed`): az3 was rebuilt for 110. **AKS's azure-ip-masq-agent** translates pod flows leaving the
  VNet to the node's address; its optional user ConfigMap `azure-ip-masq-agent-config` (kube-system) merges with the reconciled one.
- **A new zone needs its gateway certificate**: `<zone>-gateway--wildcard` (Renew certificate), or its Gateway is invalid
  (`InvalidCertificateRef`) and Traefik answers 404.
- **Claude on Foundry needs `modelProviderData`** (org, country, industry; azapi, not azurerm) and per-subscription quota -
  0 by default here. `Microsoft.CognitiveServices` must be registered (Deploy does it).
- The auto-mode classifier refused granting Run Command on labfw to an apply identity and a workflow running Run Command as
  the owner; read labfw's denials from Log Analytics instead.

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
- **Grafana Fleet Management pipelines match the cluster name** (seen 2026-10-15): the k8s monitoring pipeline
  `k8s_monitoring_k8s_monitoring_aks_dev_stateless_az1` matches `cluster="aks-dev-stateless-az1"`, and the chart sets the
  collector's `cluster` attribute to the cluster's name - so after each rename (`aks-dev-ext-...`, `aks-dev-int-...`) the
  collectors registered but got only Grafana's `ihub_kubernetes_survey*` pipelines: no cluster data. Fix the matcher in
  Grafana Cloud (D48: collection is managed there). Cluster status lists the pipelines' matchers and the collectors.
- **k8s-monitoring on AKS** refuses to render without the pod annotation
  `kubernetes.azure.com/set-kube-service-host-fqdn: "true"` on every Alloy collector and kube-state-metrics
  (detected from live node labels via `lookup`, so offline `helm template` misses it); with it, pods
  resolve `*.hcp.<region>.azmk8s.io`, which their Cilium DNS rules must allow.
- **The system node is nearly full**: on 2026-10-14 the two D4als_v6 held ~11 GiB of requests, istiod 4 GiB and
  the VPA add-on 2.4 GiB of it; without both, one node (~5.8 GiB allocatable) holds the rest with ~2 GiB to spare.
  New system-pool workloads need small requests or node-critical priority.
- **Leaving App Routing orphans its per-Gateway objects** (seen 2026-10-15): istiod's `<gateway>-approuting-istio`
  Deployment (crash-looping without istiod), public LoadBalancer Service (selector `gateway-name` also matches Traefik's
  pods), HPA, PDB and ServiceAccount stayed in every gateway namespace after the Traefik switch. Deploy's apply now
  deletes them for Gateways of another class (step "Remove App Routing's leftovers").
- **GitHub OIDC subjects of this org carry immutable IDs** (`repo:onek8s@340519759/aks-terraform@1340382905:environment:dev`),
  not `repo:onek8s/aks-terraform:...`: a federated credential on the short form gets 401 at Entra ID.
- **Azure refuses two Kustomizations of one Flux configuration on the same path** (`InvalidInputParameter`).
- **An ABAC condition may name only actions its role has** (`InvalidRoleAssignmentCondition: Action pattern ... is not
  referenced in role`, only at apply): a custom role needs its own condition (conventions `key_vault_edit_conditions`).
- `kubectl auth can-i` on an Azure RBAC cluster answers `no - Azure does not have opinion...`: parse the first word.
- **Credentials handed over in chat** go to the vault with `store-secret.yml` (encrypted to the vault key
  `secret-transport`), never into Git or a workflow input.
- **Behind labfw, a denied source shows only in labfw's log**: `labfw logs --action deny --src <node IP> --tail 20`
  (Lab admin Run Command on `labfw-fw`, or SSH over the VPN). Upstreams redirect to CDNs the allow-list must name too
  (`cdn.registry.k8s.io`, `production.cloudfront.docker.com`, `external-secrets.io`; 2026-10-15). labfw applies a policy
  change within ~2 min of the Platform apply (`systemctl kill -s HUP labfw` refreshes at once). The fleet's HelmReleases
  retry their install forever (`retries: -1`) so a release that timed out on a blocked source recovers by itself.
- **Long applies outlive the GitHub OIDC token** (AADSTS700024 ~5 min after the first sign-in): sign in again
  (azure/login) before az/kubectl steps that follow a cluster build.
- **`az aks command invoke`** (break-glass into the private cluster, no VPN needed) runs in namespace `aks-command`,
  which the AKS policy counts as a platform namespace since 2026-10-15 (namespace-ownership refused it before).
- **`az k8s-configuration flux update --suspend` alone is refused** (`ValidationFailed: source kind 'GitRepository' must
  contain corresponding body`): PATCH the one property with `az rest` (Lab power's `flux_suspend`); the extension's agent
  copies it to the cluster's Kustomizations within a minute.
- Waiting: use `/tmp/claude-0/bin/waitrun.sh <repo> <run_id>...` if it exists (polls the runs API),
  or a loop over the runs API; long foreground `sleep` is blocked in the sandbox.
