# Internal cell `int-stateless-az3` of the OneK8s dev environment - a stateless cluster in availability zone 3
# (OneK8s design section 3.1), on a lab budget - see "Non-production cost savings" below - and the lab's
# FIREWALL-EGRESS cell (design D59, 2026-10-15): no overlay network. Its pods take addresses of their
# zone's node subnet in 100.64.0.0/16 (shared/: pod_network = "subnet") and keep them up to the hub's
# firewall (labfw), which decides every flow that leaves the cluster - by zone (the subnet) and by
# application (the pod's address, which the egress agent of onek8s/aks-ai-agents maps to its namespace).
# Cilium keeps only the policies inside the cluster. It runs Sweden's zone, int-se, only; az2 runs
# Finland's. shared/envs/dev.tfvars is applied first.
#
#   terraform workspace select -or-create dev-int-stateless-az3
#   terraform apply -var-file=envs/dev-int-stateless-az3.tfvars

name     = "aks-dev-int-stateless-az3"
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
# (aks-fluxcd-example, stateless/). Production: true - pod right-sizing (design section 2.3).
vertical_pod_autoscaler_enabled = false

# ACNS without container network observability (Hubble): no hubble-relay, flow logs or Hubble metrics
# (design D56). FQDN network policies and eBPF host routing stay on - the isolation zones' egress
# needs them, so they are never a cost saving. Production: advanced_networking = {} (all on, the
# default); turning Hubble back on is an in-place update.
advanced_networking = {
  observability = false
}

# The system pool: ONE amd64 node in availability zone 3, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption) - fits only with the two savings above - on an ephemeral OS disk on the size's local
# NVMe disk: no managed OS disk, so no Premium SSD (AKS gives a managed OS disk Premium SSD wherever
# the size supports it; the lab avoids Premium disks where it can).
# Production: node_count = 2 on the default Standard_D4ds_v5 (16 GiB) - room for istiod and the VPA
# add-on, and a node to spare during an upgrade (design section 2.3). AKS's cilium-operator runs two
# replicas on different nodes, so with one system node its second replica brings up one small zone
# spot node.
# The other attributes are the design's in every environment: Azure Linux 3.0 (eBPF host routing needs
# it on every node), encryption at host, SSH off, and the CriticalAddonsOnly taint - only the
# platform's own controllers run here, every isolation zone's pods on that zone's NAP nodes. A system
# node pool cannot run on Spot VMs, and a node pool cannot change its architecture or OS in place.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["3"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
  # No overlay (network_profile below): every pod takes an address of snet-system, reserved up front per node, and
  # Azure CNI node subnet defaults to 30 pods a node - fewer than the platform runs on its one system node. 110 is
  # the overlay cells' default; snet-system is a /20.
  max_pods = 110
}

# ---------------------------------------------------------------------------------------------------
# End of the non-production cost savings
# ---------------------------------------------------------------------------------------------------
# Every cluster starts on 1.36, the platform floor (design R12a). AKS never upgrades a cell on its
# own: the version pipeline changes it while the cell is drained (section 3.5).
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
virtual_network_name = "vnet-dev-int-stateless-az3"
node_subnet_name     = "snet-system"

# The cell's exposure (OneK8s design, decision D52): internal and external workloads are separate
# clusters in separate subscriptions; this is an internal cell, so it holds the internal zones only -
# one per enabled country, each with its own nodes, subnets and Key Vault. sub-aks-dev plays
# sub-aks-dev-int. This cell runs Sweden's int-se only (Finland's int-fi runs in az2).
exposure = "int"

isolation_zones = {
  int-se = { node_subnet_name = "snet-int-se-nodes" }
}

# Egress through the landing zone's hub firewall (labfw): the cell's subnets send 0.0.0.0/0 there
# (shared/: hub), so AKS creates no outbound load balancer rule. Cannot change on a running cluster.
#
# No overlay (design D59): Azure CNI node subnet with the Cilium dataplane - the one non-overlay mode node
# auto provisioning supports (not a pod subnet with dynamic IP allocation). Every pod takes an address of
# its node's subnet - the system pool's snet-system, a zone's snet-<zone>-nodes, /21s of 100.64.0.0/16 -
# and keeps it to labfw: the firewall's log names the pod, its rules the zone, and labfw translates every
# flow that leaves the landing zone (the internet; the corporate network, outside its private ranges).
# Cannot change on a running cluster.
network_profile = {
  outbound_type       = "userDefinedRouting"
  network_plugin_mode = "none"
}

# No platform gateway: a public load balancer cannot answer behind the hub firewall (its replies would
# leave by the default route), and an internal cell has no public entry point. So no Flux webhook
# either: Flux polls every minute.
platform_gateway_enabled = false

# SHARED. The environment's platform Key Vault, created by shared/ and looked up here: the gateways'
# certificates, the Grafana Cloud credentials - and this cluster's customer-managed keys, created here
# in it (design section 4.2): key-aks-dev-int-stateless-az3-kms for the secrets in etcd, key-...-disk for
# every node's OS disk (encryption at host covers the ephemeral one).
key_vault_name   = "kv-onek8s-gwc-platform"
key_vault_create = false
# KMS data encryption (preview): the vault has no public network access, and AKS reaches it as a trusted
# service - classic KMS would need API Server VNet Integration, which the encrypted cell network refuses (D58)
customer_managed_keys = {
  key_vault_name           = "kv-onek8s-gwc-platform"
  key_vault_network_access = "Private"
  kms_data_encryption      = true
}

# The platform's namespaces with a share of the platform vault: each zone's gateway reads its
# listener certificate, `<namespace>--wildcard`; flux-system the observability chart's credentials.
# Every managed namespace below is added on its own.
key_vault_namespaces = ["flux-system", "int-se-gateway"]

# An application namespace's share is in its zone's vault (design section 2.5).
key_vault_namespace_vaults = {
  int-se-example = "kv-onek8s-gwc-int-se"
}

# SHARED. The public zone onek8s.lol - the external zones' names and the platform gateway's - in
# rg-onek8s-dns, provisioned outside Terraform. This cluster's external-dns gets an identity of its
# own, granted on it; an internal cell publishes nothing there. Its zone's names go into shared/'s
# private zone int-se.dev.onek8s.lol (internal_dns_zones), which external-dns-int keeps.
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"

# SHARED. The int-se zone's private DNS, created by shared/ (internal_dns_zones) in rg-aks-dev: this
# cluster's external-dns-int publishes the zone's routes there.
internal_dns_zone_names = ["int-se.dev.onek8s.lol"]

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from.
persistent_storage_enabled = false
portable_disks_enabled     = false

# SHARED. The environment's container registry, created by shared/. The kubelet pulls the images from
# it as this cluster's identity, with AcrPull - no image pull secret.
container_registry_name = "acronek8sdev"

# SHARED. The environment's Log Analytics workspace, created by shared/: this cluster's Kubernetes
# audit log (kube-audit-admin and guard) - design section 6.2, CIS AKS Benchmark 2.1.1.
log_analytics_workspace_name = "log-dev-platform"

# AKS Image Integrity (preview): Ratify checks the Notation signature of every image for the Azure
# Policy add-on, which reports unsigned ones (audit only). Its identity and the signing certificate
# are shared/'s (image_signing).
image_integrity_enabled = true

# A private API server (design section 2.2, D58) over Private Link: its private endpoint is in snet-system,
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

# The Azure Policy add-on (design section 2.7): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy).
azure_policy_enabled = true

# Node auto provisioning (NAP, the AKS-managed Karpenter) for the isolation zones' nodes - design
# section 4. The platform repository's node-pools define two NodePools per zone, on-demand and spot,
# each in its zone's subnet (isolation_zones) and in this cell's availability zone.
node_auto_provisioning_enabled = true

# The `example` team's application, in the int-se zone (design section 2.6: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys firewall-egress/ of
# onek8s/aks-fluxcd-example into it - aks-hello on the zone's own nodes, with its weather forecast from
# the internet - and its routes attach to the int-se gateway. Ingress and egress inside the cluster are
# closed to its own namespace by the namespace's default policies; egress outside the cluster is left
# to labfw (design D59): the zone's platform policy lets it leave, and the firewall allows only what the
# zone's and the application's firewall rules name - anything else is denied there, and the egress agent
# proposes the rule.
managed_namespaces = {
  int-se-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 2.6; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-se"
    }
    # Inside the cluster, its own namespace only; outside it, the zone's platform policy lets everything
    # through to labfw (aks-fluxcd-platform, infrastructure/zones/firewall-egress).
    network_policy = {
      ingress = "AllowSameNamespace"
      egress  = "AllowSameNamespace"
    }
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./firewall-egress"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
      # The zone and its domain, for the team's routes; home_cell: the cluster that publishes the team's
      # internal names (design section 3.1) - this one, the only cell of int-se.
      substitute = {
        zone        = "int-se"
        zone_domain = "int-se.dev.onek8s.lol"
        home_cell   = "aks-dev-int-stateless-az3"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateless-az3"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# No Flux webhook: no platform gateway for GitHub to reach (platform_gateway_enabled above).
flux_github_webhook = false
