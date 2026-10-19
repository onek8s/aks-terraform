# aks-terraform

The clusters of [OneK8s](https://onek8s.github.io/) - one Kubernetes platform for every cloud: minimal
Terraform for deploying AKS clusters with [Azure Verified Modules][avm], and the environment's
container registry. Azure is the first cloud implemented; the applications and their deployment
(Flux, the Gateway API, open standards - see the design's
[open standards and portability](https://onek8s.github.io/docs/1.3-open-standards-and-portability.html))
are meant to move to another cloud unchanged.

| Repository | Role |
| --- | --- |
| [onek8s.github.io](https://github.com/onek8s/onek8s.github.io) | The design |
| [azure-landing-zone](https://github.com/onek8s/azure-landing-zone) | The Azure landing zone: tenant, management groups, policy, hub, subscriptions |
| **aks-terraform** | The AKS clusters and what an environment's clusters share: network, Key Vault, container registry, DNS |
| [aks-fluxcd-platform](https://github.com/onek8s/aks-fluxcd-platform) | What Flux deploys into every cluster |
| [aks-fluxcd-example](https://github.com/onek8s/aks-fluxcd-example) | An application team's repository |
| [aks-hello](https://github.com/onek8s/aks-hello) | The example application |
| [aks-ai-agents](https://github.com/onek8s/aks-ai-agents) | AI agents for day-2 operations |

There is a single root module at the repository root. Everything an environment differs by lives in
a variables file under `envs/` - no per-environment Terraform code.

Every cluster is a cell of the OneK8s design: attached to the environment's resources that `shared/`
creates - its resource group, its own network, the vaults, the registry - with a private API server
(design D58) and Azure RBAC on every call.

[avm]: https://azure.github.io/Azure-Verified-Modules/

## Layout

| Path | Purpose |
| --- | --- |
| `main.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `terraform.tf` | The root module. Wraps [`Azure/avm-res-containerservice-managedcluster/azurerm`][module] 0.8.5 from the registry (Image Integrity, which it has no input for, is set beside it in `image_integrity.tf`): looks up the existing resources by name, creates the cluster identity and its role assignments, wires up private or public API server access, and creates the managed namespaces. |
| `key_vault.tf` | The cluster's Key Vault, and the identities and conditional role assignments that give each namespace its own share of it. See [Key Vault](#key-vault). |
| `envs/dev-int-stateless-az1.tfvars`, `envs/dev-int-stateless-az2.tfvars`, `envs/dev-int-stateful.tfvars` | The `dev` environment's clusters (since 2026-10-15, in germanywestcentral), `aks-dev-int-stateless-az1` (disabled in `shared/`: zone 1 is not available to the subscription), `aks-dev-int-stateless-az2` (running) and `aks-dev-int-stateful`, on the **Free** tier: one system node, no uptime SLA. Internal (`exposure = "int"`: Finland's zone `int-fi` only; Sweden's `int-se` is disabled in `shared/`). The stateless clusters are the design's cells - see [Cells of the OneK8s design](#cells-of-the-onek8s-design): each in an availability zone (1, 2) and a network of its own peered with the landing zone's hub, egress through labfw (`userDefinedRouting`), with the isolation zone's nodes from [node auto provisioning](#node-auto-provisioning), ACNS with eBPF host routing, customer-managed keys, an ephemeral OS disk and no persistent storage; no public entry point, so Flux polls (D70). The running one serves `hello-aks-dev-int-stateless-az2.int-fi.dev.onek8s.lol` on its zone's internal load balancer. The stateful one is defined but not deployed for now. |
| `shared/` | The environment's shared resources, a root module and state of its own: the resource group and network, the Key Vault, the identities the namespaces read it as, the private DNS zone, the container registry and the images it builds, and the Traffic Manager profiles of the hostnames every cluster serves. `shared/envs/dev.tfvars` is the `dev` environment's. See [Shared resources](#shared-resources). |
| `modules/conventions/` | What the two root modules have to work out the same way: the [naming policy](#naming-policy) and its region codes, the shared identities' names, the ABAC conditions of a namespace's share of the vault. |
| `scripts/policy-name.sh` | The naming policy's name of one resource, for the workflows that need a name no variables file states. |
| `tests/aks.tftest.hcl` | `terraform test` suite. The providers are mocked, so it plans the whole configuration - role assignment scopes, upgrade windows, every input validation - without a subscription. |
| `backend.hcl.example` | Template for the shared remote state backend. |
| `.tflint.hcl`, `.github/` | Lint configuration, the CI workflow that runs the offline checks, the manual deploy workflow for the dev environment's stacks, and the Dependabot schedule that watches the pinned module and provider versions. |

[module]: https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/0.8.5

## Prerequisites

These must exist before running Terraform:

- The environment's [shared resources](#shared-resources), applied: the **resource group**, the
  cell's **virtual network** with the system pool's subnet and each isolation zone's subnets, the
  **Key Vaults**, the registry and the Log Analytics workspace. The cluster looks them up by name.
- The one **DNS zone** the Gateway's hostnames are published in - a public Azure DNS zone, or with
  `dns_zone_private` an Azure Private DNS zone - only where `dns_zone_name` names it. [`shared/`](shared/)
  creates it, or it is provisioned outside Terraform (`dev`'s public `onek8s.lol`, in `rg-onek8s-dns`).
  See [Certificates and DNS](#certificates-and-dns).

The identity running Terraform needs `Contributor` on the resource group, permission to create role
assignments on the network and the DNS zones, and role definitions on the resource group for
`portable_disks_enabled`.

Every cluster runs the managed Gateway API CRDs, which are in **preview**. The subscription needs the
preview feature registered first:

```sh
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
az provider register --namespace Microsoft.ContainerService
```

A cluster with `image_integrity_enabled` runs AKS Image Integrity (Ratify), also in **preview**:

```sh
az feature register --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview
az provider register --namespace Microsoft.ContainerService
```

The `Microsoft.PolicyInsights` resource provider should be **registered in the subscription** for the
Azure Policy add-on:

```sh
az provider register --namespace Microsoft.PolicyInsights
```

A cluster with a [Flux repository](#gitops-with-flux) needs the `Microsoft.KubernetesConfiguration`
resource provider registered as well:

```sh
az provider register --namespace Microsoft.KubernetesConfiguration
```

## Usage

Edit the environment's variables file to name your existing resources, then apply it:

```sh
az login
terraform init

terraform workspace select -or-create dev-int-stateless-az1
terraform apply -var-file=envs/dev-ext-stateful.tfvars
```

An environment with [shared resources](#shared-resources) applies them first, from `shared/`:

```sh
cd shared
terraform init
terraform workspace select -or-create dev
terraform apply -var-file=envs/dev.tfvars
```

One root module serves every environment, so **each environment needs its own state**. Locally that
is one workspace per environment, as above. Adding an environment means adding a variables file;
nothing else changes.

Anything beyond a prototype belongs in remote state: local state is not shared, not locked and not
backed up. Uncomment `backend "azurerm"` in `terraform.tf`, copy `backend.hcl.example` to
`backend.hcl`, and give each environment its own key:

```sh
terraform init -backend-config=backend.hcl -backend-config="key=dev-int-stateless-az1.tfstate"
```

The backend holds a blob lease for the duration of an apply, so two people cannot write the same
state at once. Turn on versioning and soft delete for the container too - a truncated state file is
only recoverable if an earlier version survives.

The `dev` environment is deployed from GitHub: the [Deploy](.github/workflows/deploy.yml) workflow,
started by hand, plans one of its stacks - `dev-shared` (`shared/`), `dev-int-stateless-az1` or
`dev-int-stateful` - and, when run with `apply`, applies that plan; `destroy` deletes a cluster stack (never `dev-shared`), for a change a cluster cannot take in place, such as moving its nodes between amd64 and arm64. Each stack has its state as `<stack>.tfstate`. It runs in the
`dev` GitHub environment, signs in as the identity of the `AZURE_*` variables - a service principal
with the `AZURE_CLIENT_SECRET` secret, or GitHub OIDC without it - and keeps the state in the
storage account of the variables `TF_STATE_RESOURCE_GROUP` and `TF_STATE_STORAGE_ACCOUNT`, in
`sub-aks-dev` itself (created on the first run), so a lab reset takes it with the resources. It refuses to plan against an empty state unless told it is a first
deployment.

The configuration can be checked without an Azure subscription at all, which is exactly what CI
runs on every pull request:

```sh
terraform fmt -check -recursive
terraform validate
terraform test
tflint --init && tflint
```

## Cluster access

Local Kubernetes accounts are **disabled**, so there is no cluster-admin certificate to hand around
and `az aks get-credentials --admin` does not work. Everything authenticates as an Entra ID
identity, and [Azure RBAC][entraauthz] decides what that identity may do inside the cluster.

```sh
az aks get-credentials --resource-group <resource_group_name> --name "$(terraform output -raw name)"
kubectl get nodes
```

Two things have to be granted before that returns anything:

- **`Azure Kubernetes Service Cluster User Role`** on the cluster, to download a kubeconfig at all.
  This one is never created here.
- A Kubernetes-level role: every group in `entra_admin_group_object_ids` is assigned
  `Azure Kubernetes Service RBAC Cluster Admin` on the cluster, every group in
  `entra_reader_group_object_ids` `Azure Kubernetes Service RBAC Reader`. Anything narrower is a
  namespace's `groups` - see [Managed namespaces](#managed-namespaces).

Because the API server is private, the kubeconfig only resolves from a network that reaches it: the
labfw VPN in the lab. `az aks command invoke` runs a command in the cluster through the Azure control
plane instead:

```sh
az aks command invoke --resource-group <resource_group_name> \
  --name "$(terraform output -raw name)" --command "kubectl get nodes"
```

[entraauthz]: https://learn.microsoft.com/azure/aks/manage-azure-rbac

## Managed namespaces

Namespaces are created by AKS rather than by whatever deploys workloads into them, so that the
boundary a namespace draws is in place before anything lands in it. List the names in the variables
file and there is nothing else to write:

```hcl
managed_namespaces = {
  team-payments = {}
  team-search   = {}
}
```

Each one is a [managed namespace][namespaces]: an Azure resource that AKS reconciles into a
Kubernetes `Namespace`, a default `NetworkPolicy` and - where one is asked for - a default
`ResourceQuota`. Deleting the namespace inside the cluster does not get rid of it, and Azure role
assignments can be scoped to the namespace alone - see
[Who gets into a namespace](#who-gets-into-a-namespace).

### What a namespace gets by default

| | Default | What it means |
| --- | --- | --- |
| `network_policy.ingress` | `AllowSameNamespace` | Only pods of the same namespace can open a connection to a pod in it. |
| `network_policy.egress` | `AllowAll` | A pod may reach the API server, DNS, the internet and the rest of the cluster. |
| `adoption_policy` | `Never` | A Kubernetes namespace of that name that already exists fails the apply instead of being taken over. |
| `delete_policy` | `Keep` | Removing the entry deletes the Azure resource and leaves the Kubernetes namespace, and whatever runs in it, standing. |
| `resource_quota` | 2 cores and 4Gi of limits, 500m and 1Gi of requests | Azure requires a quota on every managed namespace, so this is a ceiling to raise or lower rather than one to turn off. |
| `pod_security` | `restricted` | The namespace is held to the hardened [Pod Security Standard][pss], enforced, audited and warned about - see [Pod Security Standards](#pod-security-standards). |

**Closed inbound, open outbound** is the shape this settles on: a workload talks out to what it
needs without anyone having to enumerate it, and nothing in another namespace talks in until it is
allowed to. It is the half of the pair that is worth having by default - the one that stops a
compromised or merely misconfigured workload in one namespace from reaching straight into another -
while a default-deny egress would break DNS, the API server and every outbound call on the first
day and be turned off again by the afternoon.

These are the namespace's *default* policies, not a ceiling. Kubernetes network policies are
additive, so a `NetworkPolicy` applied inside the namespace can only widen what these permit -
tightening egress for a particular workload is done by narrowing it here, not inside the cluster.

### Changing them

Anything in the table can be overridden on a single namespace:

```hcl
managed_namespaces = {
  # Fronted by the ingress controller, which runs in another namespace.
  team-payments = {
    network_policy = { ingress = "AllowAll" }
  }
  # Batch jobs that have no business reaching anything outside their own namespace.
  team-search = {
    network_policy = { egress = "AllowSameNamespace" }
    resource_quota = { cpu_limit = "4", memory_limit = "8Gi" }
  }
}
```

...or for the whole cluster at once through `managed_namespace_defaults`, which is what every
namespace falls back to:

```hcl
managed_namespace_defaults = {
  labels        = { "cost-centre" = "platform" }
  delete_policy = "Delete"
}
```

Both `ingress` and `egress` take `AllowAll`, `AllowSameNamespace` or `DenyAll`. `labels` and
`annotations` merge with the defaults key by key, so a namespace adds to the estate-wide set rather
than replacing it; everything else is a plain override. A namespace that names no quota figures is
sent the four figures of `managed_namespace_defaults` rather than none at all.

Quota figures are written the way a manifest writes them - `"500m"`, `"0.5"` or `"2"` for CPU,
`"512Mi"` or `"4Gi"` for memory. Azure takes the CPU ones in milliCPU alone, so `"2"` is sent on as
`"2000m"` and a figure finer than a milliCPU is refused rather than rounded away.

**Every namespace has a quota.** Azure requires all four figures on a managed namespace - the API
spec marks the quota optional and the service refuses a namespace that arrives without one - so
`resource_quota` sets a ceiling rather than deciding whether there is one. The figures cap the sum
of what the pods in the namespace request and are limited to, which also means a pod that declares
neither a request nor a limit is refused by the quota; a `LimitRange` inside the namespace is what
gives such pods their figures. A namespace that needs more room says so:

```hcl
managed_namespaces = {
  team-search = {
    resource_quota = { cpu_limit = "8", memory_limit = "16Gi" }
  }
}
```

### Pod Security Standards

Every managed namespace is held to the **`restricted`** [Pod Security Standard][pss] unless it says
otherwise. There is nothing to install: the standard is applied as the
`pod-security.kubernetes.io/*` labels the API server's built-in [Pod Security Admission][psa]
controller reads, so a labelled namespace is an enforced one.

Each namespace gets all three modes at `restricted`:

| Mode | What it does |
| --- | --- |
| `enforce` | Rejects a pod that breaks the standard. |
| `audit` | Records the violation in the API server audit log and lets the pod through. |
| `warn` | Returns a warning to whoever applied it and lets the pod through. |

`restricted` is genuinely strict - it wants `runAsNonRoot`, `allowPrivilegeEscalation: false`,
`seccompProfile: RuntimeDefault` and all capabilities dropped - and plenty of off-the-shelf charts
do not meet it as shipped. That is the point of it being the default: a workload that needs more has
to say so, in the variables file, where it is reviewed.

#### Exceptions

An exception is stated on the namespace that needs it, not by lowering the standard for the cluster:

```hcl
managed_namespaces = {
  # A monitoring agent that wants the host network and a privileged container.
  observability = {
    pod_security = { enforce = "privileged" }
  }
  # Charts that are not quite there yet, held at the middle standard while they catch up.
  team-search = {
    pod_security = { enforce = "baseline", warn = "baseline" }
  }
}
```

Each mode takes `restricted`, `baseline`, `privileged` - the level that permits everything, and so
the normal way to write an exception - or `none`, which leaves that label off the namespace
entirely.

**Relaxing `enforce` on its own leaves `audit` and `warn` where they were.** The pods that break the
standard still land in the audit log and still warn whoever applies them, so the exception is
visible and can be walked back later. Terraform warns when a namespace relaxes `enforce` *and* turns
off both of the other two: that is an exception nothing refuses and nothing records.

`version` pins the standard to a Kubernetes release:

```hcl
managed_namespace_defaults = {
  pod_security = { version = "v1.31" }
}
```

The default, `latest`, follows the cluster - which means an AKS upgrade can tighten what a namespace
enforces under a workload that was passing the day before. Pin it in an environment where that
matters, and move the pin deliberately.

The labels are set through `pod_security` alone; a `pod-security.kubernetes.io/*` key written into
`labels` by hand is refused, so a namespace cannot end up with two answers about what it enforces.

[psa]: https://kubernetes.io/docs/concepts/security/pod-security-admission/
[pss]: https://kubernetes.io/docs/concepts/security/pod-security-standards/

### Who gets into a namespace

`groups` binds an Entra ID group to each of Kubernetes' user-facing roles in the namespace - `view`,
`edit`, `admin` - as a `RoleBinding` the cluster's Flux configuration applies, and grants the group
`Azure Kubernetes Service Namespace User` on the namespace resource, so that its members fetch a
kubeconfig for that namespace alone (`az aks namespace get-credentials`) and nothing else. The same
groups get the matching rights on the namespace's secrets in its vault (`shared/`, design D49 and D51).
See the `managed_namespaces` variable.

### What to watch for

- **Something has to enforce the policies.** A `NetworkPolicy` in a cluster with no policy engine is
  an object nobody reads: the namespace looks closed in Azure and every pod in the cluster can still
  reach into it. Terraform warns on every plan when `network_profile.network_policy = "none"` and a
  namespace restricts anything.
- **A managed namespace is no longer yours to edit from `kubectl`.** AKS installs a component that
  reconciles the namespace against what Azure holds and blocks changes to the managed fields through
  the Kubernetes API, so the variables file becomes the only way to change them.
- **Names are Kubernetes namespace names**: lowercase letters, digits and hyphens. System namespaces
  cannot be on-boarded at all - `kube-system` and anything else starting with `kube-`,
  `gatekeeper-system`, `istio-system`, `app-routing-system` - and Terraform refuses the ones
  Microsoft names.
- **The labels cannot be edited back out from inside the cluster.** Because the namespace is
  managed, AKS blocks changes to its labels through the Kubernetes API - so `kubectl label namespace
  team-search pod-security.kubernetes.io/enforce=privileged` does not work, and an exception has to
  go through the variables file. That is the point, but it does mean a team cannot unblock itself at
  three in the morning.
- **A namespace grant does not carry over to the cluster.** `Azure Kubernetes Service Cluster User
  Role` and the cluster-wide `entra_admin_group_object_ids` are separate, and a principal that has
  only namespace grants cannot run `az aks get-credentials` or see anything outside its namespace -
  which is the point, but it does mean `kubectl get nodes` comes back forbidden for them.
- **`delete_policy = "Keep"` leaves the namespace behind.** Removing an entry from the variables
  file destroys the Azure resource but not the Kubernetes namespace, which is deliberate - a
  workload should not disappear because a line moved. Clean it up with `kubectl delete namespace`,
  or set `delete_policy = "Delete"` up front for namespaces that are meant to be disposable.

[namespaces]: https://learn.microsoft.com/azure/aks/concepts-managed-namespaces

## Upgrade window

The cluster upgrades itself - by default the `stable` channel for the Kubernetes version and the
`NodeImage` channel for node OS patching, both configurable through `auto_upgrade`. Those upgrades,
together with the weekly AKS release of the control plane and add-ons, are confined to a single
weekly [planned maintenance][maintenance] window. It defaults to the night between Tuesday and
Wednesday, 22:00 - 06:00 UTC.

Change it per environment in the variables file:

```hcl
maintenance_window = {
  day_of_week    = "Tuesday"
  start_time     = "23:00"
  duration_hours = 8
  utc_offset     = "+03:00"
}
```

Azure keeps the window at a fixed UTC offset and does not follow daylight saving time, so an offset
matching local winter time drifts an hour during summer time, and vice versa.

The window must be at least four hours long, or AKS does not attempt an upgrade at all. AKS only
*starts* work inside it: an upgrade still running when the window closes is allowed to finish, but
nothing new begins. Windows are best effort - AKS reserves the right to break them for urgent,
unplanned maintenance.

Pinning `kubernetes_version` and letting a channel move past it are mutually exclusive, and
Terraform refuses the combination: AKS would upgrade the cluster, the next apply would write the
pinned version back, and Azure rejects a downgrade. Pin the version and set
`auto_upgrade = { kubernetes_channel = "none" }`, or pin only the minor version and use `"patch"`.

[maintenance]: https://learn.microsoft.com/azure/aks/planned-maintenance

## Monitoring and ingress

Monitoring is handled by third party solutions running inside the cluster, so **nothing is sent to
Azure Monitor**. Ingress is the [Kubernetes Gateway API][gatewayapi], served by Traefik or App
Routing's Gateway API implementation (`gateway_implementation`) - see [Ingress through the Gateway API](#ingress-through-the-gateway-api). The Azure features that would
otherwise duplicate them are off on every cluster, with no variable to turn them back on:

| Disabled | What it would have done |
| --- | --- |
| [Container Insights][insights] (`omsagent`) | Ships node and pod telemetry to a Log Analytics workspace. |
| [Azure Monitor managed Prometheus][prometheus] | Scrapes cluster metrics into an Azure Monitor workspace. |
| Control plane [diagnostic setting][diagnostics] | Ships the API server, audit and autoscaler logs to a Log Analytics workspace. |
| [Defender for Containers][defender] | Runs the Defender security agent on the nodes for threat detection. |
| [Application Routing][approuting]'s NGINX (`webAppRouting.enabled`, `nginx`) | Installs and manages the NGINX ingress controller for the Ingress API, which the platform does not use. App Routing's Gateway API implementation is separate, see below. |
| [Application Gateway for Containers][agcaddon] (`applicationLoadBalancer`) | Runs the ALB Controller add-on, which programs an Azure-hosted, public Gateway API load balancer. |

Most of them are stated as disabled rather than simply left unconfigured, because Azure can turn them
on by itself otherwise: a subscription running the **Defender for Containers plan** with
auto-provisioning on enables the security agent on clusters as they appear.

Two consequences worth knowing about:

- **The control plane's audit log** is the one thing collected on the Azure side: the control plane
  is not part of the cluster, so no in-cluster agent can pick up `kube-audit-admin` or `guard`; a
  diagnostic setting (`audit_logs.tf`) sends them to the environment's Log Analytics workspace
  (`log_analytics_workspace_name`, design section 6.2).
- **Nothing else is billed for ingestion**, and the cluster emits platform metrics only.

The AKS cost analysis add-on is off (design D46): cost per namespace and team comes from OpenCost in
the clusters' Grafana stack.

The **Azure Policy add-on** is on by default (`azure_policy_enabled`), so policy definitions
assigned to the subscription or resource group are enforced inside the cluster rather than merely
reported on.

[approuting]: https://learn.microsoft.com/azure/aks/app-routing
[approutinggw]: https://learn.microsoft.com/azure/aks/app-routing-gateway-api
[aks5939]: https://github.com/Azure/AKS/issues/5939
[traefikgw]: https://doc.traefik.io/traefik/providers/kubernetes-gateway/
[defender]: https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction
[diagnostics]: https://learn.microsoft.com/azure/aks/monitor-aks-reference
[insights]: https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview
[prometheus]: https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview

## Ingress through the Gateway API

Every cluster publishes its workloads through the [Kubernetes Gateway API][gatewayapi]. What this
configuration provides is the API itself; the controller serving it is deployed through
[Flux](#gitops-with-flux):

| Setting | What it does |
| --- | --- |
| `ingressProfile.gatewayAPI.installation = "Standard"` | The [managed Gateway API CRDs][managedgw], standard channel. AKS installs and upgrades them, so nothing else in the cluster may bring its own. |
| `ingressProfile.webAppRouting.gatewayAPIImplementations.appRoutingIstio.mode` | `Enabled` with `gateway_implementation = "approuting-istio"`, else `Disabled`: [App Routing's Gateway API implementation][approutinggw], a sidecar-less Istio control plane (`istiod` in `aks-istio-system`) serving the GatewayClass `approuting-istio`. No service mesh, no sidecars, no Istio CRDs; AKS upgrades it in place with the cluster. |
| `ingressProfile.applicationLoadBalancer.enabled = false` | No Application Gateway for Containers add-on. Stated rather than left out, so a cluster that had it loses it; it keeps the module on a preview API - `2026-03-02-preview`, which also knows App Routing Istio. |

`gateway_implementation` picks what serves the Gateways - the same Gateways, listeners, certificates
and Cilium policies either way; only the GatewayClass they name changes, which the Flux repository
is told as `gateway_class_name_<gateway>` - and the implementation as `gateway_implementation`, the
kustomize component that adds what only it takes (App Routing's `parametersRef` ConfigMap, which
Traefik refuses with `Accepted: False`):

| `gateway_implementation` | What runs | Cost |
| --- | --- | --- |
| `traefik` (the dev cells, a non-production cost saving) | [Traefik Proxy][traefikgw] per Gateway, a Helm release with its own GatewayClass `traefik-<gateway>`, deployed from this repository's [`gateways/traefik`](gateways/traefik) by a Flux configuration per Gateway, `traefik-<gateway>` (`traefik.tf`). It reads the Gateway API objects from the API server itself; its own Cilium policy lets it. | 2 x 25m / 64 MiB of requests per Gateway, no control plane. |
| `approuting-istio` (the default, production) | App Routing's istiod, which runs an Envoy Deployment per Gateway (below). | istiod alone requests 500m and 2 GiB per replica, at least two, not customizable ([Azure/AKS#5939][aks5939]): a second system node in every lab cell. |
| null | No implementation: the stateful cluster (R9a), which states it. | - |

Traefik's manifests live here rather than in the Flux repository so that the choice and everything
it brings are one change of this repository. Switching re-creates the Gateways under their new class
(Flux `force`): the cell's gateways are down for a few minutes, so drain the cell in Traffic Manager
first where that matters. Leaving App Routing leaves its per-Gateway objects behind (istiod, which
would remove them, is gone): every Deploy apply of a cluster deletes `<gateway>-approuting-istio`
(Deployment, Service, autoscaler, disruption budget, ServiceAccount) for each Gateway that names
another class.

With App Routing, for every Gateway of class `approuting-istio`, istiod creates an Envoy Deployment, a `LoadBalancer`
Service, an autoscaler (at least two replicas) and a disruption budget in the Gateway's namespace,
shaped by the ConfigMap the Gateway names in `spec.infrastructure.parametersRef` - within the
add-on's allow list. The Flux repository runs one such Gateway per isolation zone - `<zone>` in
`<zone>-gateway` - all on the system pool. The zones' gateways are on the system pool so that a zone's own nodes exist
only for its applications: a zone without any has none. The system subnet's NSG therefore lets
HTTPS in from the internet and from the virtual network. Each is behind a `LoadBalancer` Service
of its own:

- **An internal zone's** is an [internal load balancer][ilb] in the zone's `snet-<zone>-ilb`
  (`service.beta.kubernetes.io/azure-load-balancer-internal-subnet`), reachable from inside the
  network only. The cluster identity holds `Network Contributor` on the whole network (node auto
  provisioning), which is all AKS needs.
- **An external zone's** is public: Azure Traffic Manager
  (`global_hostnames` in `shared/`) points an application's one hostname at it in every cell.

Traffic reaches the pods from the zone's gateway pods inside the cluster, which the platform's
Cilium baseline lets in - from the zone's own gateway only.

What App Routing's implementation does not offer: rate limits, request size limits and `EnvoyFilter` (the
Gateway API has no standard fields for them), egress gateways, and customizing the access log. It
cannot run beside the Istio service mesh add-on.

### Certificates and DNS

The Gateway terminates TLS with certificates it reads from Kubernetes Secrets. App Routing's own Key
Vault and Azure DNS integration is not used: it would read the vault through the Secrets Store CSI
driver, which the design leaves off (R7b), and write DNS as one identity for every zone. So both are
done from inside the cluster, by workloads the Flux repository deploys, each acting as an identity
created here:

- **Certificates** are kept in the environment's platform [Key Vault](#key-vault) as
  `<zone>-gateway--wildcard` - the share of the vault that belongs to the zone's gateway namespace,
  so a zone's gateway reads its own certificate and no other. External Secrets Operator syncs it
  into the Secret the zone's listener names, as `<zone>-gateway/key-vault`, unpacking the secret
  behind the certificate as PKCS#12 - so a certificate is imported as a `.pfx`, never as PEM. A new
  version is picked up within the hour.

  Each zone's listener serves its zone's wildcard certificate (`*.<zone>.dev.onek8s.lol`), issued
  and renewed by the
  [Renew Certificate](.github/workflows/renew-certificate.yml) workflow: Let's Encrypt, with the
  DNS-01 challenge solved in the environment's public `dns_zone_name` - imported into its
  `key_vault_name`, both read from the variables file that creates them - `shared/envs/dev.tfvars`
  for `dev`, `envs/<environment>.tfvars` for any other. It runs monthly for `dev`,
  and whenever the workflow changes on `main`, and renews when fewer than 30 days are left; run it
  by hand for another environment, other domains or the staging CA. It needs the variables `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `LETSENCRYPT_EMAIL` and the secret
  `AZURE_CLIENT_SECRET`, for a service principal holding `Key Vault Certificates Officer` and
  `Key Vault Secrets Officer` on the vault and `DNS Zone Contributor` on the zone. The Let's Encrypt
  account key is kept in the vault beside the certificate, as `letsencrypt-account-key` - a name in
  no namespace's share. Other certificates can still be imported by hand by an admin group.
- **DNS**: the internal zones' names are in Azure Private DNS zones of their own
  (`internal_dns_zone_names`, created by `shared/` and linked to every cell's network), on which
  `<cluster identity>-dns` is granted `Private DNS Zone Contributor` too. Everything else is in one
  zone, `dns_zone_name`, public or private (`dns_zone_private`). `<cluster
  identity>-dns` is federated with `external-dns/external-dns` and granted `DNS Zone Contributor` on
  a public zone, `Private DNS Zone Contributor` on a private one; the Flux repository is told which
  (`dns_zone_private`, and the external-dns provider in `dns_provider`: `azure` or
  `azure-private-dns`). external-dns keeps a record per listener hostname, pointing at the Gateway's
  address. The zone is
  looked up in `resource_group_name` unless `dns_zone_resource_group_name` says otherwise; `shared/`
  creates it (`dns_zone_create`, a private one linked to the clusters' network), or it exists
  already. Choosing between public and private is that one setting, alike in `shared/` and in every
  cluster. The Let's Encrypt DNS-01 challenge needs a public zone for the certificate's names,
  and so do `global_hostnames`. In `dev` the zone is the public `onek8s.lol`, the only domain.

## Key Vault

The vaults are the environment's, created by `shared/` with every share and grant on them - see
[Shared resources](#shared-resources) - and looked up by the cluster, which adds its federated
credential to each namespace's identity and nothing else. Every namespace reads only its own secrets:
the namespaces are kept apart by the names of the secrets, with [Azure ABAC conditions][kvabac] on the
role assignments.

**A namespace owns the secrets named `<namespace>--<name>`** - `ext-fi-example--api-key`,
`ext-fi-gateway--wildcard`. The namespaces with a share are every managed namespace and the ones
in `key_vault_namespaces`: each zone's gateway and `flux-system`.

There is more than one vault (OneK8s design section 2.5): `shared/` creates the environment's
**platform vault** (`key_vault_name`) - the gateways' certificates, the clusters' customer-managed
keys - and **one vault per zone** (`zone_key_vault_names`)
for the secrets of the zone's applications. An application namespace's share is in its zone's
vault: `zone` in `shared/`'s `key_vault_namespaces`, and `key_vault_namespace_vaults` in the
cluster, which tells the Flux repository each namespace's vault as `key_vault_url_<namespace>`.

| Who | Role on the vault | Condition |
| --- | --- | --- |
| The namespace's `key-vault` service account, as the environment's `id-<region>-<environment>-shared-kv-<namespace>` | `Key Vault Secrets User` | Reads the value and the metadata of a secret only if it is the namespace's own; lists nothing |
| The namespace's `writers` (shared/) and its `admin` group | `Key Vault Secrets Officer` | Creates, reads, changes, deletes, backs up, restores, recovers and purges the namespace's own secrets only; lists nothing |
| The namespace's `edit` group (D51) | Custom `OneK8s Key Vault Secrets Editor (<resource group>)`: `setSecret`, `update`, `readMetadata` | Creates and changes the namespace's own secrets and reads their attributes, by name - never a value; no delete, purge or restore; lists nothing |
| The platform viewers (shared/ `platform_viewer_group_object_ids`) | Custom `OneK8s Platform Viewer (<resource group>)`, defined and assigned at the resource group | Lists every secret's name and attributes, never a value; lists the clusters' namespaces |
| `key_vault_admin_group_object_ids` (shared/) | `Key Vault Administrator` | None: the whole vault, certificates included |

In the cluster, each namespace with a share has a `key-vault` service account - created by the Flux
repository - and a `SecretStore` naming it. External Secrets Operator has no Azure identity of its
own: it requests a token for that service account on every read, so a namespace's store reads that
namespace's secrets and no others, and a namespace's `writer` can put a secret in the vault for it
without anyone else's help.

```sh
az keyvault secret set --vault-name <key_vault_name> --name example--api-key --value ...
```

- **Soft multi-tenancy: no namespace sees another's secret names.** Reading metadata is under the
  name condition too, and Key Vault evaluates a condition on a list call as a whole rather than
  secret by secret - the collection has no name - so a list is refused to every namespace identity
  and group: each reads and writes its own secrets by name (`az keyvault secret show/set --name
  <namespace>--...`), which is all External Secrets Operator does. An `ExternalSecret` cannot `find`
  by pattern. Tools that browse the vault, the Azure portal among them, need the platform viewers'
  role, which lists every name - so keep secrets out of the names. The same pattern - one shared
  instance, a data-plane role per namespace scoped by a name or an inner scope - applies to other
  PaaS services; see OneK8s design section 6.
- **A namespace name with `--` in it is refused**, since its prefix would overlap another's:
  `team--a--x` starts with `team--`.
- **Certificates are imported by an admin group.** Conditions cover secret operations only, so a
  namespace's writers manage secrets; a certificate's private key is read as the secret behind it,
  under the same name, so the namespace's identity reads its own certificates as well.
- **Key Vault ABAC is in preview.**
- The vaults take no public network access (design D60): their private endpoints are in the
  environment network, and everything reaches them through the hub (the labfw VPN in the lab).

[kvabac]: https://learn.microsoft.com/azure/key-vault/general/rbac-abac

## Shared resources

An environment can run more than one cluster on the same **shared resources**, so that a workload can
move from one cluster to another - which is how a cluster is replaced rather than upgraded in place:
build the next one beside it, move the workloads over, destroy the old one. `dev` does this with
`aks-dev-int-stateless-az1`, `aks-dev-int-stateless-az2` and `aks-dev-int-stateful`, and everything - the
clusters and what they share - is in one resource group, `rg-aks-dev`, in `sub-aks-dev` of the
[landing zone](https://github.com/onek8s/azure-landing-zone). These are the **internal** exposure's
(since 2026-10-15; before, the external one's in swedencentral): the OneK8s design keeps internal and
external workloads in separate subscriptions and clusters (decision D52), with the countries as
isolation zones inside them - a country can be disabled (`isolation_zones.<zone>.enabled = false` in
`shared/`; Sweden is). `sub-aks-dev` plays `sub-aks-dev-int`; the lab has no external subscription,
which would run `shared/` and the same cluster configuration once more with `exposure = "ext"` and the
external zones (Traffic Manager only for a deployed external zone). Only `aks-dev-int-stateless-az2`
runs, behind the hub's labfw (`shared/` `hub`); az1 is disabled (`cells.<cell>.enabled = false`)
because the region's zone 1 is not available to `sub-aks-dev`. The one exception is the public zone
`onek8s.lol`, which is created once with the Azure CLI in `rg-onek8s-dns`, outside every state, so
that its name servers - which the registrar points at - outlive any rebuild.

The shared resources are a Terraform stack of their own, [`shared/`](shared/), with a state of its
own. Neither cluster's configuration creates them, so either cluster can be destroyed and built again
while they stay. `shared/` is applied first; the clusters look its resources up by name.

| | Shared - `shared/envs/dev.tfvars` | Per cluster - `envs/dev-<cluster>.tfvars` |
| --- | --- | --- |
| Resource group and networks | `rg-aks-dev`; per cell `vnet-dev-ext-stateless-az<N>` (`cells`) with `snet-system` and per isolation zone (`isolation_zones`) `snet-<zone>-nodes` and `snet-<zone>-ilb`, each behind its own NSG, VNet encryption on; `vnet-aks-dev` for the stateful cluster | Looked up: `resource_group_name`, `virtual_network_name`, `node_subnet_name`, `isolation_zones` |
| Key Vaults | The platform vault `kv-onek8s-gwc-platform` (purge protection, for the customer-managed keys) and one per enabled zone, `kv-onek8s-gwc-<zone>` - both named by the [naming policy](#naming-policy) unless `key_vault_name` / `zone_key_vault_names` name them - with every grant on them: the admin groups' `Key Vault Administrator`, the namespaces' writers and groups | Looked up: `key_vault_name`, `key_vault_namespace_vaults`, `customer_managed_keys` - the cluster's own keys are created in the platform vault |
| Exposure | `exposure`: `ext` in dev - every zone, vault and cell of the stack is of one exposure (OneK8s decision D52: internal and external workloads have a subscription and clusters each); only an internal stack has `internal_dns_zones` (private, linked to every cell's network), only an external one `global_hostnames` | `exposure`: the cluster's zones and managed namespaces are of it; only an internal cluster names `internal_dns_zone_names`, on which external-dns is granted |
| What a namespace reads the vault as | `id-sec-dev-shared-kv-<namespace>`, one per namespace, with its read access to its own share | A federated credential named `aks-<cluster>` on each, for the namespace's `key-vault` service account |
| DNS zone | `onek8s.lol`, public, looked up in `rg-onek8s-dns` (`dns_zone_create = false`, `dns_zone_private = false`). A private zone would be created here and linked to `vnet-aks-dev` | Looked up: `dns_zone_name`. external-dns runs as `id-sec-dev-aks-<cluster>-dns`, granted on the zone, and owns its own records in it (`txtOwnerId`) |
| Disks of persistent volumes | Created in `rg-aks-dev` by whichever cluster's Azure Disk CSI driver the claim is made in, for the platform's `portable-disk` StorageClass | `portable_disks_enabled`: the cluster identity's role `Portable disks (aks-dev-ext-stateful)` on the group, for disks and snapshots only. The stateless clusters - `persistent_storage_enabled = false`, no CSI drivers - have none |
| Container registry | `acronek8sdev` (`container_registry_name`): the images, which the registry builds itself with ACR tasks from the apps' public repositories at a pinned commit (`container_registry_builds`, such as `aks-hello:0.2.0` from github.com/onek8s/aks-hello) - nobody pushes, and no app repository holds an Azure credential. Not part of the landing zone. The tier follows the environment (`container_registry_sku`, design D62): Premium with a private endpoint and no public network access in `prd`, Basic on its public endpoint (Entra ID only) everywhere else - Azure offers private endpoints on Premium alone | Looked up: `container_registry_name`. `AcrPull` for the kubelet identity, so pods need no image pull secret |
| Hostnames every cluster serves | `global_hostnames`: `hello.ext-fi.dev.onek8s.lol`, a CNAME to an Azure Traffic Manager profile that weights the app's hostname in each cell - an A record of that cell's ext-fi gateway - alike and leaves out one whose probe fails | Each cell serves the hostname on its ext-fi Gateway; the route that names it tells its external-dns to leave the record alone |
| The cluster | | `aks-dev-<cluster>`, run by `id-sec-dev-aks-<cluster>`; its node resource group, which AKS deletes with it |

The names say which is which: a shared resource carries `shared` - or, for the zones, the
environment's domain - and a cluster's carries the cluster's name. The shared identities' names are
worked out the same way by both stacks, in [`modules/conventions`](modules/conventions/), which also
holds the [naming policy](#naming-policy), the region codes and the ABAC conditions that draw each
namespace's share of the vault.

- **A namespace is the same identity in every cluster.** Its client ID and its grants - including
  anything granted to it outside this repository - follow it to the next cluster. Azure allows 20
  federated credentials on an identity, so 20 clusters at once.
- **Every namespace with a share of the vault in a cluster has to be listed in `shared/`'s
  `key_vault_namespaces`**, or its identity is not there to look up and the cluster's plan fails.
  The namespaces' writers are listed there too, rather than taken from the clusters' namespace
  grants.
- **Disks outlive the cluster.** The Azure Disk CSI driver needs a grant outside the node resource
  group to create a disk there, which Microsoft documents as `Contributor`. In a group holding the
  other cluster too, that would let one cluster change the other, so each cluster gets a role of its
  own instead: `Microsoft.Compute/disks/*`, `Microsoft.Compute/snapshots/*` and reading the group.
  Attaching a disk is a write on the node's VM, which AKS has granted already.
- **Hostnames are each cluster's**, in the shared zones: the clusters publish under names of their
  own, so they never contend for a record.

Moving a workload between the clusters - its secrets, its volumes, its hostnames - is described in
aks-fluxcd-platform's README, "Moving a workload to another cluster".

[agcaddon]: https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon
[gatewayapi]: https://gateway-api.sigs.k8s.io/
[ilb]: https://learn.microsoft.com/azure/aks/internal-lb
[managedgw]: https://learn.microsoft.com/azure/aks/managed-gateway-api

## Naming policy

The names of what these stacks create come from a **naming policy** (`naming`, in
[`modules/conventions`](modules/conventions/)): one template per resource type, filled in from the
**location**, the **exposure**, the **environment** and what tells the resource from the others of
its type. Its defaults are the lab's names, so the lab's tfvars name almost nothing:

| Type | Default template | The lab's (dev, int, germanywestcentral) |
| --- | --- | --- |
| `resource_group` | `rg-aks-{environment}` | `rg-aks-dev` |
| `key_vault` | `kv-onek8s-{location_code}-{name}` | `kv-onek8s-gwc-platform`, `kv-onek8s-gwc-int-fi` |
| `container_registry` | `acronek8s{environment}` | `acronek8sdev` |
| `log_analytics_workspace` | `log-{environment}-{name}` | `log-dev-platform` |
| `user_assigned_identity` | `id-{location_code}-{environment}-{name}` | `id-gwc-dev-shared-kv-int-fi-example`, `id-gwc-dev-aks-int-stateless-az2` |
| `virtual_network`, `network_security_group`, `route_table` | `vnet-{name}`, `nsg-{name}`, `rt-{name}` | `vnet-dev-int-stateless-az2`, `nsg-dev-int-stateless-az2-int-fi-nodes`, `rt-dev-int-stateless-az2` (the system pool's), `rt-dev-int-stateless-az2-int-fi` (a zone's) |
| `private_endpoint`, `network_interface` | `pe-{name}`, `nic-{name}` | `pe-kv-onek8s-gwc-platform`, `nic-pe-kv-onek8s-gwc-platform` |
| `disk_encryption_set` | `des-{name}` | `des-aks-dev-int-stateless-az2` |
| `consumption_budget` | `budget-{environment}` | `budget-dev` |
| `traffic_manager_profile` | `{domain}-{environment}-{name}` | (`onek8s-lol-dev-hello-ext-fi-dev`, external only) |
| `ai_services` | `ais-onek8s-{environment}-{name}` | `ais-onek8s-dev-agents` |

The placeholders are `{environment}`, `{exposure}` (empty without one), `{location}`,
`{location_code}` (the region's short code, `naming.location_codes` over the built-in list),
`{name}` and `{domain}` (Traffic Manager's DNS zone). An empty placeholder leaves no stray hyphen; a
registry name loses everything but letters and digits; every name is checked against its type's Azure
rules at plan time, and an unknown type or placeholder fails the plan (output `names`). A variable that
names a resource itself (`resource_group_name`, `key_vault_name`, `zone_key_vault_names`,
`container_registry_name`, `log_analytics_workspace_name`, `ai_foundry.name`) still wins, resource by
resource; a registry or workspace without a name is created only with `container_registry_create` /
`log_analytics_workspace_create`. A cluster's own name, its subnets and what a cluster looks up are
stated in its tfvars as before - the cluster stack takes the same policy for its identities and its
disk encryption set, and `environment` when the cluster's name does not carry it in its second segment.

**A real estate's policy is not kept here.** Some of these names are global - Key Vault, the
registry, the AI Services subdomain, Traffic Manager - and a published convention tells anyone which
name the next vault will take. Keep the policy as JSON outside Git and give it to both stacks:

```json
{
  "templates": {
    "key_vault": "kv-<prefix>-{location_code}-{environment}-{name}",
    "container_registry": "cr<prefix>{location_code}{environment}{exposure}"
  },
  "location_codes": { "germanywestcentral": "dewc" }
}
```

- **Deploy workflow**: the `dev` environment's secret `NAMING_POLICY` holds that JSON; the run writes it
  to `naming.auto.tfvars.json` (ignored by Git, like every tfvars file outside `envs/`) and masks the
  templates' fixed parts, so the plan in this public repository's log does not show them. No secret: the
  defaults. Renew certificate reads the same secret through `scripts/policy-name.sh`.
- **By hand**: `{"naming": <the JSON>}` as `naming.auto.tfvars.json` in the stack's directory, or
  `-var-file=` a file elsewhere.

Changing a template renames what it names, and for most of these types a new name is a new resource
(a vault, a network, an identity and its grants): adopt a policy before the first apply of an
environment, or plan the move. The lab's other workflows (Store secret, Sign images, Lab power, the
VPN action, the tests) name the lab's resources directly; an estate with its own policy points them at
its names. The landing zone (onek8s/azure-landing-zone) names its own resources.

## Node auto provisioning

`node_auto_provisioning_enabled = true` turns on [node auto provisioning][nap] (NAP) - Karpenter,
run by AKS - for the nodes of the isolation zones (the design's
[node pools](https://onek8s.github.io/docs/2.3-node-pools.html)). The `dev` stateless clusters turn it
on. What it sends, and what it leaves to others:

- `nodeProvisioningProfile` `mode = Auto`, `defaultNodePools = None`. AKS installs Karpenter and the
  `NodePool` / `AKSNodeClass` CRDs, but none of its own `default` and `system-surge` NodePools, so
  no NAP node exists that a zone `NodePool` did not ask for. The system pool stays the classic node
  pool of `default_node_pool`, and a pod that runs there today - aks-hello, the platform's
  controllers - stays there: none of them tolerates a zone's taint, so no `NodePool` takes them.
- The `NodePool`s and `AKSNodeClass`es are onek8s/aks-fluxcd-platform's (`infrastructure/node-pools`):
  two per zone, on-demand and spot, amd64 and arm64. They are told the node subnet and the cell's
  availability zone as `nap_subnet_id` and `nap_availability_zone`, so the cell has to be one zone in
  an existing network - a check warns otherwise.
- The cluster identity gets Network Contributor on the whole virtual network rather than on the node
  subnet, as Microsoft documents NAP to need.
- Refused with the cluster autoscaler on the system pool, and without Azure CNI Overlay powered by
  Cilium - the two things AKS refuses NAP for.

Turning it on for an existing cluster is an update in place. To turn it off again, delete the zone
`NodePool`s first, so that their nodes are drained and removed, then set it back to `false`.

[nap]: https://learn.microsoft.com/en-us/azure/aks/node-autoprovision

## Pod-subnet cells: classic zone pools

A pod-subnet cell (design D74, `dev-int-stateless-az3`) runs Azure CNI Pod Subnet with dynamic IP
allocation: `network_profile.network_plugin_mode = "none"`, `default_node_pool.pod_subnet_name` (shared/'s
`snet-system-pods`) and every zone's `isolation_zones.<zone>.pod_subnet_name` (`snet-<zone>-pods`). AKS
refuses node auto provisioning with a pod subnet (Azure/karpenter-provider-azure issue 1351), so
`zone_node_pools` gives each zone four classic node pools instead - `<zone>`, `<zone>spot`, `<zone>arm`,
`<zone>armspot` (`intse`, ...) - from 0 nodes in the cell's availability zone, labelled and tainted
`platform/zone=<zone>` (and `platform/capacity=spot` on the spot pools) like the zone `NodePool`s, so the
platform's placement mutations work unchanged. The cluster autoscaler takes the `priority` expander; the
fleet's `infrastructure/autoscaler-priority` ConfigMap puts the spot pools first. The cluster identity gets
Network Contributor on the virtual network, as with NAP. When NAP supports the pod subnet, the pools move
back to the fleet's `NodePool`s with no network change.

## Cells of the OneK8s design

The `dev` stateless clusters are the design's cells. Beyond node auto provisioning, they set:

| Variable | What it does | Design |
| --- | --- | --- |
| `exposure` | `int` or `ext`: internal and external workloads never share a cluster (decision D52), so every zone and every managed namespace's `platform/zone` is of the cluster's exposure, and only an internal cluster writes the internal zones' private DNS - validated at plan. The Flux repository is told it as `cluster_exposure`. The `dev` cells are external | sections 3.1, 3.2 |
| `isolation_zones` | Each zone's node subnet in the cell's network; the Flux repository is told its ID as `nap_subnet_id_<zone>` for the zone's `AKSNodeClass`, so a zone's nodes are in the zone's subnet behind the zone's NSG | sections 2.1, 2.3, 2.4 |
| `advanced_networking` | Advanced Container Networking Services: Hubble (`observability`, off in the dev cells - D56), FQDN network policies (`advancedNetworkPolicies: FQDN`) and eBPF host routing (`accelerationMode: BpfVeth`). The last is sent in the create request - AKS refuses it for a running cluster, even one with only its own iptables rules - through the AVM module's `network_profile.advanced_networking.performance` input (0.8.5 and later); changing it means building the cell again. Needs Azure Linux 3.0 or Ubuntu 24.04 on every node - a check says so | section 5.1 |
| `customer_managed_keys` | `key-<cluster>-kms` for KMS etcd encryption and `key-<cluster>-disk` for the disk encryption set of every node's OS disk, in the platform vault - see [`encryption.tf`](encryption.tf). Only at creation: a cluster built without them is built again | section 4.2 |
| `default_node_pool.os_sku`, `encryption_at_host`, `ssh_access`, `node_taints` | Azure Linux 3.0, encryption at host (the subscription feature `Microsoft.Compute/EncryptionAtHost`, which the Deploy workflow registers), SSH off, and `CriticalAddonsOnly` so that only the platform's controllers run on the system pool - the Flux extension is told to tolerate it | sections 2.2, 2.3, 4.2 |
| `auto_upgrade` `none` / `None`, `kubernetes_version` | AKS never upgrades a cell on its own; every cell starts on 1.36 | section 3.5 |
| `internal_dns_zone_names` | The internal zones' private DNS, which an internal cell's external-dns writes | section 4.1 |

Always, on every cluster: the Secrets Store CSI driver add-on is off - secrets reach pods only as
Kubernetes Secrets from External Secrets Operator (design section 2.5).

## Production defaults and non-production cost savings

Every variable defaults to the **production setting** of the OneK8s design, so an acceptance or
production environment states what is its own (names, networks, zones, namespaces) and nothing
about how big or how managed the cluster is. A non-production environment that wants to spend less
turns on, by name, the cost savings below; the dev lab's tfvars keep them together in one block,
"Non-production cost savings", at the top of each file.

| Variable | Production default | Non-production cost saving (dev lab) | What the saving gives up |
| --- | --- | --- | --- |
| `sku_tier` | `Standard` - uptime SLA, API server scaled for load (D31) | `Free` | The control plane SLA; cost analysis. |
| `gateway_implementation` | `approuting-istio` - App Routing's Gateway API, the Azure standard offering, upgraded by AKS (D55) | `traefik` | A gateway Azure upgrades and supports; istiod's 1 CPU / 4 GiB of requests ([Azure/AKS#5939][aks5939]) is what is saved. |
| `vertical_pod_autoscaler_enabled` | `true` - pod right-sizing (section 2.3) | `false` | In-place right-sizing of the applications' pods; ~2.4 GiB of requests saved. |
| `advanced_networking` | `{}` - Hubble, FQDN policies, eBPF host routing (section 5.1) | `{ observability = false }` (D56) | Hubble flow logs and metrics. FQDN policies and eBPF host routing are never a saving: the zones' egress needs them. |
| `default_node_pool` | `node_count = 2`, `Standard_D4ds_v5` (16 GiB), `os_sku = "AzureLinux"` | `node_count = 1`, `Standard_D4alds_v6` (8 GiB) on an ephemeral OS disk (no Premium SSD) | A second node during upgrades and failures; room for istiod and the VPA add-on. Fits only together with `traefik` and the VPA add-on off. With one system node AKS's `cilium-operator` puts its second replica on a small zone spot node. |

The savings depend on each other - the one 8 GiB system node holds the platform only with Traefik and
without the VPA add-on - so going back to production means all of them: delete the block and apply.
Changing the gateway implementation re-creates the cell's Gateways; the rest are in-place updates.

## GitOps with Flux

A cluster syncs its main configuration from one public Git repository through [Flux][flux]. Name the
repository in the variables file:

```hcl
flux_git_repository = {
  url    = "https://github.com/example/cluster-config"
  branch = "main"                 # default
  path   = "./clusters/dev-int-stateless-az1" # default "./"
}
```

That installs the Flux cluster extension (`microsoft.flux`) into `flux-system`, kept on the newest
minor version of the `Stable` release train, and creates a Flux configuration named `platform` that
reconciles the Kustomization at `path` every `sync_interval_seconds` (default 300; the `dev`
clusters read every 60) and retries a failed run at the same interval. Flux prunes what is removed from the
repository. `platform` runs no health checks of its own (`wait = false`): it applies what `path`
holds - in practice the cluster's own Flux Kustomizations, each waiting for its objects - and is
done, so a commit is never held back behind one of them that is unhealthy.

There is no webhook: every cluster polls (design D70 - no public entry point in a cell).

The `platform` Kustomization is also given the Azure facts the repository cannot know on its own, as
Flux [post-build variables][postbuild], so they are never copied into it by hand:

| Variable | Value |
| --- | --- |
| `key_vault_url`, `key_vault_url_<namespace>`, `key_vault_client_id_<namespace>` | The platform vault, each namespace's vault, and for each namespace with a share the identity its `key-vault` service account reads it as - the namespace's hyphens as underscores, `key_vault_client_id_int_fi_gateway`. |
| `dns_zone_name`, `dns_zone_resource_group_name`, `dns_zone_subscription_id` | The zone of `dns_zone_name`. |
| `dns_zone_private`, `dns_provider` | Whether the zone is private (`"true"` / `"false"`), and the external-dns provider that writes it: `azure` or `azure-private-dns`. |
| `dns_identity_client_id` | The identity external-dns writes either zone as. |
| `nap_subnet_id`, `nap_subnet_id_<zone>`, `nap_availability_zone` | With `node_auto_provisioning_enabled`: the system pool's and each zone's node subnet for the `AKSNodeClass`es, and the system pool's one availability zone as Kubernetes spells it (`germanywestcentral-2`), which every zone `NodePool` requires. See [Node auto provisioning](#node-auto-provisioning). |
| `gateway_implementation`, `gateway_class_name_<zone>` | The Gateway API implementation and the class each zone's Gateway names. |
| `cluster_exposure`, `internal_dns_resource_group_name` | The cluster's exposure (D52) and, for an internal cluster, where the internal zones' private DNS is. |
| `image_verification_client_id`, `image_signing_certificate_name`, `image_signing_subject`, `container_registry_login_server` | With `image_integrity_enabled`: what Ratify verifies with. |
| `cluster_name`, `azure_tenant_id` | Always sent. |

A variable the cluster has no value for - those of a vault or zone that is not named - is left out rather than sent empty. They apply to what `path` holds itself; the repository passes them
on from there to whatever needs them. Leave `flux_git_repository` unset, and name no tenant
repository (below), and Flux is not installed at all.

[postbuild]: https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution

### Tenants

A managed namespace can deploy itself from a Git repository of its own - the team's - by naming it
in `flux`. The namespace, who gets into it, its share of the Key Vault and its repository are then
one entry in the variables file:

```hcl
managed_namespaces = {
  example = {
    groups = {
      edit = "00000000-0000-0000-0000-000000000000"
    }
    flux = {
      url         = "https://github.com/onek8s/aks-fluxcd-example"
      path        = "./apps"
      secret_name = "aks-fluxcd-example-git"
    }
  }
}
```

That creates a second Flux configuration, named after the namespace, **namespace-scoped** and
installed into the namespace itself. It reconciles `path` on `branch` (default `main`) every
`sync_interval_seconds` (default 300), retries at the same interval, prunes, and waits for what it
applied to become ready. Because it is an Azure resource of its own rather than a Kustomization
nested under `platform`, each team's sync status - and the error, when there is one - shows on its
own row in the portal's GitOps view of the cluster.

- The extension applies the repository as the `flux-applier` service account of that namespace and
  refuses references across namespaces, so a team's repository changes its own namespace and
  nothing else. There is no `targetNamespace`: the repository's `kustomization.yaml` sets
  `namespace:` for its objects itself.
- A private repository is read with `secret_name`, a Secret in the namespace. No credential passes
  through Terraform or Azure: the Flux repository syncs it from the namespace's share of the Key
  Vault (onek8s/aks-fluxcd-platform, `tenants/<team>/key-vault.yaml`).
- The rest of what a tenant needs inside the cluster - the `key-vault` service account and
  SecretStore, the ExternalSecrets, the Cilium baseline that lets the zone's gateway in - stays in the Flux
  repository, under `tenants/<team>/`.

[flux]: https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-gitops-flux2

## Node pool upgrades

Node image patching and Kubernetes upgrades roll the system pool one node at a time by default,
which is slow on anything but a small pool. `default_node_pool` controls the roll:

```hcl
default_node_pool = {
  max_surge                  = "33%"
  drain_timeout_minutes      = 30
  node_soak_duration_minutes = 5
}
```

`max_surge` is the extra capacity added while upgrading, so the subscription needs quota for it.
`drain_timeout_minutes` bounds how long a node is allowed to take to drain - a pod with a
restrictive disruption budget can otherwise hold the upgrade indefinitely - and
`node_soak_duration_minutes` waits after each node comes back before the next one is drained.

## Notes

- The system pool runs in **one availability zone** unless `default_node_pool.availability_zones` is
  set. Spreading it - `availability_zones = ["1", "2", "3"]` in a region that has them - is what
  raises the control plane SLA from 99.9% to 99.95% on the paid tiers, and keeps the cluster running
  through the loss of a datacentre. Zones can only be chosen when the pool is created; changing them
  later replaces it.
- The `Free` tier carries **no uptime SLA** for the control plane. `sku_tier = "Standard"` buys the
  99.9% (or 99.95% across availability zones) financially backed SLA, raises the supported node
  count and is what makes cost analysis available; production clusters belong there.
- **Workload identity** is on, together with the **OIDC issuer** it requires. Federate a Kubernetes
  service account with an Entra ID application against the `oidc_issuer_url` output instead of
  storing credentials in the cluster.
- Terraform **waits after creating the role assignments** before creating the cluster, because Azure
  RBAC is eventually consistent and the cluster is otherwise regularly refused access to the subnet
  it is supposed to join.
- Cluster operations are given **90 minutes** rather than the 30 the AzAPI provider defaults to.
  Giving up on the Terraform side does not stop the deployment: Azure carries on, and the cluster is
  left in `Creating` with nothing in state pointing at it.
- The cluster identity gets `Network Contributor` **on the whole virtual network** when node auto
  provisioning or the zones' node pools create nodes outside the system pool's subnet, and on that
  subnet alone otherwise - the least privilege AKS documents for a bring-your-own network - plus the
  cell's route tables, which AKS joins (`userDefinedRouting`).
- The cluster uses a **user assigned identity** created by this module. The identity exists because
  AKS has to be granted the network *before* the cluster is created, which a system assigned identity
  cannot be: it does not exist until the cluster does. Its name is **worked out, not configured**: by default `id-<region code>-<environment>-<function>`
  (the [naming policy](#naming-policy)'s `user_assigned_identity`), built from the cluster name and the
  region. A cluster name reads `<what it is>-<environment>-<which one>`, so `aks-dev-ext-stateful` in
  `swedencentral` is run by `id-sec-dev-aks-ext-stateful`. The region codes are the estate's own
  convention rather than anything Azure defines, so they live in `local.location_codes` in
  `modules/conventions/main.tf` and the policy's `location_codes`; a region that is listed in neither
  stops the plan rather than being given a guessed code. An identity cannot be renamed in place, so a name that changes replaces
  the identity, its principal ID and its role assignments - the replacement is built and granted
  before the old one goes, so the cluster is never left pointing at an identity that no longer
  exists.
- Cluster **tags are not managed here**. Automation outside Terraform adjusts them, so the existing
  tags are read back from Azure and passed to the module as-is. Otherwise every plan would propose
  deleting them, and that update alone would make Terraform re-read every computed cluster
  attribute, showing `fqdn`, `node_resource_group_name` and `oidc_issuer_url` as
  `(known after apply)` on an unchanged cluster.
- The **upgrade windows** are `azapi_resource` blocks in `main.tf` rather than module arguments. The
  module always sends a `startDate`, Azure answers with the date the window was created, and that
  difference shows up as an update in every later plan. Terraform can leave the property alone only
  by not mentioning it.
