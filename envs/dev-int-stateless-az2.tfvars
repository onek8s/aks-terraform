# Internal cell `int-stateless-az2` of the OneK8s dev environment - a stateless cluster in availability zone 2
# (OneK8s design section 8), on a lab budget - see "Non-production cost savings" below. The lab's only
# running cell since 2026-10-15: internal exposure, Finland's zone only, in germanywestcentral, routed
# through the landing zone's hub firewall (labfw). Its sibling envs/dev-int-stateless-az1.tfvars is
# disabled (zone 1 is not available to sub-aks-dev). shared/envs/dev.tfvars is applied first.
#
#   terraform workspace select -or-create dev-int-stateless-az2
#   terraform apply -var-file=envs/dev-int-stateless-az2.tfvars

name     = "aks-dev-int-stateless-az2"
location = "germanywestcentral"

sku_name = "Base"

# ---------------------------------------------------------------------------------------------------
# Non-production cost savings
#
# Every setting in this block departs from the module's defaults, which are the production settings
# of the OneK8s design (acc and prd use the defaults). Together they let a lab cell run on ONE small
# system node instead of two larger ones, at the price of an SLA, of Azure's standard gateway and of
# pod right-sizing. Do not copy this block to an acceptance or production environment.
#
# They depend on each other: the single 8 GiB system node (~5.8 GiB allocatable) holds the platform
# only with Traefik and without the VPA add-on. Going back to production means all of them together:
# delete the block (or set each to its production value below) and apply.
# ---------------------------------------------------------------------------------------------------

# AKS Free tier: no uptime SLA, API server not scaled for load. Production: "Standard" (design D31).
sku_tier = "Free"

# Gateway API implementation: Traefik Proxy, one small Deployment per Gateway (2 x 25m/64Mi), no
# control plane (gateways/traefik of this repository, deployed by Flux). Production:
# "approuting-istio" - App Routing's Gateway API, the Azure standard offering, upgraded by AKS - whose
# istiod alone requests 1 CPU and 4 GiB that cannot be tuned (https://github.com/Azure/AKS/issues/5939;
# design D55). Switching re-creates the cell's Gateways (minutes without them).
gateway_implementation = "traefik"

# No Vertical Pod Autoscaler add-on: its recommender, updater and admission controller request
# ~2.4 GiB on the system pool. aks-hello's VerticalPodAutoscaler is left out with it
# (aks-fluxcd-example, stateless/). Production: true - pod right-sizing (design section 4).
vertical_pod_autoscaler_enabled = false

# ACNS without container network observability (Hubble): no hubble-relay, flow logs or Hubble metrics
# (design D56). FQDN network policies and eBPF host routing stay on - the isolation zones' egress
# needs them, so they are never a cost saving. Production: advanced_networking = {} (all on, the
# default); turning Hubble back on is an in-place update.
advanced_networking = {
  observability = false
}

# The system pool: ONE amd64 node in availability zone 2, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption) - fits only with the two savings above - on an ephemeral OS disk on the size's local
# NVMe disk: no managed OS disk, so no Premium SSD (AKS gives a managed OS disk Premium SSD wherever
# the size supports it; the lab avoids Premium disks where it can).
# Production: node_count = 2 on the default Standard_D4ds_v5 (16 GiB) - room for istiod and the VPA
# add-on, and a node to spare during an upgrade (design section 4). AKS's cilium-operator runs two
# replicas on different nodes, so with one system node its second replica brings up one small zone
# spot node.
# The other attributes are the design's in every environment: Azure Linux 3.0 (eBPF host routing needs
# it on every node), encryption at host, SSH off, and the CriticalAddonsOnly taint - only the
# platform's own controllers run here, every isolation zone's pods on that zone's NAP nodes. A system
# node pool cannot run on Spot VMs, and a node pool cannot change its architecture or OS in place.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["2"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
}

# ---------------------------------------------------------------------------------------------------
# End of the non-production cost savings
# ---------------------------------------------------------------------------------------------------
# Every cluster starts on 1.36, the platform floor (design R12a). AKS never upgrades a cell on its
# own: the version pipeline changes it while the cell is drained (section 12).
kubernetes_version = "1.36"
auto_upgrade = {
  kubernetes_channel = "none"
  node_os_channel    = "None"
}

# The dev environment's resource group, created by shared/envs/dev.tfvars. It holds every cluster of
# the environment and what they share.
resource_group_name = "rg-aks-dev"

# The cell's own network, created by shared/ (cells): the system pool in snet-system, each isolation
# zone's NAP nodes in its own snet-<zone>-nodes and its internal load balancer in snet-<zone>-ilb,
# every subnet behind its own NSG, VNet encryption on.
virtual_network_name = "vnet-dev-int-stateless-az2"
node_subnet_name     = "snet-system"

# The cell's exposure (OneK8s design, decision D52): internal and external workloads are separate
# clusters in separate subscriptions; this is an internal cell, so it holds the internal zones only -
# one per enabled country, each with its own nodes, subnets and Key Vault. sub-aks-dev plays
# sub-aks-dev-int. Sweden's int-se is disabled in the lab (shared/envs/dev.tfvars), so it is not here.
exposure = "int"

isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes" }
}

# Egress through the landing zone's hub firewall (labfw): the cell's subnets send 0.0.0.0/0 there
# (shared/: hub), so AKS creates no outbound load balancer rule. Cannot change on a running cluster.
network_profile = {
  outbound_type = "userDefinedRouting"
}

# No platform gateway: a public load balancer cannot answer behind the hub firewall (its replies would
# leave by the default route), and an internal cell has no public entry point. So no Flux webhook
# either: Flux polls every minute.
platform_gateway_enabled = false

# SHARED. The environment's platform Key Vault, created by shared/ and looked up here: the gateways'
# certificates, the Grafana Cloud credentials - and this cluster's customer-managed keys, created here
# in it (design section 18): key-aks-dev-int-stateless-az2-kms for the secrets in etcd, key-...-disk for
# every node's OS disk (encryption at host covers the ephemeral one).
key_vault_name   = "kv-onek8s-gwc-platform"
key_vault_create = false
customer_managed_keys = {
  key_vault_name = "kv-onek8s-gwc-platform"
}

# The platform's namespaces with a share of the platform vault: each zone's gateway reads its
# listener certificate, `<namespace>--wildcard`; flux-system the observability chart's credentials.
# Every managed namespace below is added on its own.
key_vault_namespaces = ["flux-system", "int-fi-gateway"]

# An application namespace's share is in its zone's vault (design section 6).
key_vault_namespace_vaults = {
  int-fi-example = "kv-onek8s-gwc-int-fi"
}

# SHARED. The public zone onek8s.lol - the external zones' names and the platform gateway's - in
# rg-onek8s-dns, provisioned outside Terraform. This cluster's external-dns gets an identity of its
# own, granted on it; an internal cell publishes nothing there. Its zone's names go into shared/'s
# private zone int-fi.dev.onek8s.lol (internal_dns_zones), which external-dns-int keeps.
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"

# SHARED. The int-fi zone's private DNS, created by shared/ (internal_dns_zones) in rg-aks-dev: this
# cluster's external-dns-int publishes the zone's routes there.
internal_dns_zone_names = ["int-fi.dev.onek8s.lol"]

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from.
persistent_storage_enabled = false
portable_disks_enabled     = false

# SHARED. The environment's container registry, created by shared/. The kubelet pulls the images from
# it as this cluster's identity, with AcrPull - no image pull secret.
container_registry_name = "acronek8sdev"

# SHARED. The environment's Log Analytics workspace, created by shared/: this cluster's Kubernetes
# audit log (kube-audit-admin and guard) - design section 19, CIS AKS Benchmark 2.1.1.
log_analytics_workspace_name = "log-dev-platform"

# AKS Image Integrity (preview): Ratify checks the Notation signature of every image for the Azure
# Policy add-on, which reports unsigned ones (audit only). Its identity and the signing certificate
# are shared/'s (image_signing).
image_integrity_enabled = true

# A private API server (design section 3, D58) over Private Link: its private endpoint is in snet-system,
# reached by the nodes directly and by the management network, the labfw VPN and the GitHub runners
# (which join that VPN) through the hub. Not API Server VNet Integration: Azure refuses it on an
# encrypted network with v4+ VM sizes (VNetEncryptionNotCompatibleWithAPIServerVNetIntegration). No
# private DNS zone: the cell resolves through labfw's DNS proxy in the hub, so the public FQDN names
# the private address.
private_cluster_enabled             = true
private_cluster_public_fqdn_enabled = true
private_dns_zone_mode               = "none"
api_server_vnet_integration_enabled = false

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster. None yet in the build tenant.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# The Azure Policy add-on (design section 14): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy).
azure_policy_enabled = true

# Node auto provisioning (NAP, the AKS-managed Karpenter) for the isolation zones' nodes - design
# section 4. The platform repository's node-pools define two NodePools per zone, on-demand and spot,
# each in its zone's subnet (isolation_zones) and in this cell's availability zone.
node_auto_provisioning_enabled = true

# The `example` team's application, in the int-fi zone (design section 7: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys stateless/ of
# onek8s/aks-fluxcd-example into it, and its routes attach to the int-fi gateway. Ingress and egress
# are closed to its own namespace by the namespace's default policies; the platform's Cilium baseline
# opens DNS and the zone gateway, and the team's own FQDN policy anything outside the cluster.
managed_namespaces = {
  int-fi-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 7; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-fi"
    }
    # Who may work in the namespace (design section 7, D49): an Entra ID group per Kubernetes role,
    # bound by RoleBindings platform-<role>. The lab groups grp-onek8s-dev-ext-fi-example-<role>, reused
    # from the external lab, each with a tester application the isolation tests sign in as
    # (tests/isolation/namespace-access-testers.yaml).
    groups = {
      view  = "6d9ae939-5e03-4ddb-b378-baa7fa5b5180"
      edit  = "88ba3f87-2d13-46ea-8cff-eeccf6cbd0bc"
      admin = "71438fbc-0666-4d82-be17-54b61236d657"
    }
    network_policy = {
      ingress = "AllowSameNamespace"
      egress  = "AllowSameNamespace"
    }
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./stateless"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
      # The zone and its domain, for the team's routes: the gateway they attach to and their hostnames.
      # dns_publish: whether this cell publishes the team's home-cell names (<app>.<zone domain>,
      # design section 8: an internal app runs in one home cell, whose external-dns alone publishes
      # it) - the home cell of every internal app in the lab. A lab stand-in for the design's placement artifact.
      substitute = {
        zone        = "int-fi"
        zone_domain = "int-fi.dev.onek8s.lol"
        dns_publish = "true"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateless-az2"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# No Flux webhook: no platform gateway for GitHub to reach (platform_gateway_enabled above).
flux_github_webhook = false
