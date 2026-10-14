# External cell `ext-stateless-az2` of the OneK8s dev environment - a stateless cluster in availability zone 2
# (OneK8s design section 8), on the Free tier: one system node, no uptime SLA. Its sibling is
# aks-dev-ext-stateless-az1 (envs/dev-ext-stateless-az1.tfvars); every external application runs in both,
# and Azure Traffic Manager hands out one or the other (shared/: global_hostnames).
# shared/envs/dev.tfvars is applied first.
#
#   terraform workspace select -or-create dev-ext-stateless-az2
#   terraform apply -var-file=envs/dev-ext-stateless-az2.tfvars

name     = "aks-dev-ext-stateless-az2"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

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
virtual_network_name = "vnet-dev-ext-stateless-az2"
node_subnet_name     = "snet-system"

# The cell's exposure (OneK8s design, decision D52): internal and external workloads are separate
# clusters in separate subscriptions; this is an external cell, so it holds the external zones only -
# one per country, each with its own nodes, subnets and Key Vault. sub-aks-dev plays sub-aks-dev-ext.
exposure = "ext"

isolation_zones = {
  ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
  ext-se = { node_subnet_name = "snet-ext-se-nodes" }
}

# Azure CNI Overlay powered by Cilium with ACNS: Hubble, FQDN network policies and eBPF host routing
# (design section 16).
advanced_networking = {}

# SHARED. The environment's platform Key Vault, created by shared/ and looked up here: the gateways'
# certificates, the Flux webhook token - and this cluster's customer-managed keys, created here in it
# (design section 18): key-aks-dev-ext-stateless-az2-kms for the secrets in etcd, key-...-disk for every
# node's OS disk.
key_vault_name   = "kv-onek8s-dev-platform"
key_vault_create = false
customer_managed_keys = {
  key_vault_name = "kv-onek8s-dev-platform"
}

# The platform's namespaces with a share of the platform vault: each zone's gateway and the platform
# gateway read their listener certificate, `<namespace>--wildcard`. flux-system is added for the
# webhook token, and every managed namespace below on its own.
key_vault_namespaces = ["platform-gateway", "ext-fi-gateway", "ext-se-gateway"]

# An application namespace's share is in its zone's vault (design section 6).
key_vault_namespace_vaults = {
  ext-fi-example = "kv-onek8s-dev-ext-fi"
}

# SHARED. The public zone onek8s.lol - the external zones' names and the platform gateway's - in
# rg-onek8s-dns, provisioned outside Terraform. This cluster's external-dns gets an identity of its
# own, granted on it. An external cell has no internal zone, so no private zone either.
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"

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

# The Gateway API implementation of the zones' and the platform's Gateways, which aks-fluxcd-platform
# deploys: `traefik` (Traefik Proxy per Gateway, from gateways/traefik of this repository) or
# `approuting-istio` (App Routing's istiod: 1 CPU and 4 GiB of requests before the first Gateway,
# https://github.com/Azure/AKS/issues/5939).
gateway_implementation = "traefik"

# A public API server - the one exception of the dev lab to design section 3, which has no network
# path into the cells' networks. Entra ID authenticates every call; local accounts are disabled.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster. None yet in the build tenant.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# The Azure Policy add-on (design section 14): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy).
azure_policy_enabled = true

# The system pool: one amd64 node in availability zone 2, 4 vCPU and 8 GiB (the platform's
# controllers and the Azure Policy add-on do not fit in 2 vCPU). One node holds everything only with
# Traefik as the Gateway API implementation and the VPA add-on off (below): App Routing's istiod
# would add 1 CPU and 4 GiB of requests (https://github.com/Azure/AKS/issues/5939), the VPA add-on
# ~2.4 GiB, and 5.8 GiB of the node's 8 is allocatable; either one back means node_count = 2. On
# Azure Linux 3.0 - which eBPF host routing needs on every node - with encryption at host, SSH off
# and the CriticalAddonsOnly taint: only the platform's own controllers run here, every
# isolation zone's pods on that zone's NAP nodes.
# Standard_D4als_v6 is offered in both zones the cells use and supports VNet encryption. A system
# node pool cannot run on Spot VMs, and a node pool cannot change its architecture or OS in place.
default_node_pool = {
  vm_size             = "Standard_D4als_v6"
  availability_zones  = ["2"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
}

# Node auto provisioning (NAP, the AKS-managed Karpenter) for the isolation zones' nodes - design
# section 4. The platform repository's node-pools define two NodePools per zone, on-demand and spot,
# each in its zone's subnet (isolation_zones) and in this cell's availability zone.
node_auto_provisioning_enabled = true

# Lab cost exception (dev only, 2026-10-14): no VPA add-on. Its recommender, updater and admission
# controller request ~2.4 GiB, which one 8 GiB system node does not hold beside the rest; the cell
# keeps one system node instead of two. aks-hello's VerticalPodAutoscaler is left out with it
# (aks-fluxcd-example, stateless/). Pod right-sizing (design section 4) stays the design for acc/prd.
vertical_pod_autoscaler_enabled = false

# The `example` team's application, in the ext-fi zone (design section 7: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys stateless/ of
# onek8s/aks-fluxcd-example into it, and its routes attach to the ext-fi gateway. Ingress and egress
# are closed to its own namespace by the namespace's default policies; the platform's Cilium baseline
# opens DNS and the zone gateway, and the team's own FQDN policy anything outside the cluster.
managed_namespaces = {
  ext-fi-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 7; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "ext-fi"
    }
    # Who may work in the namespace (design section 7, D49): an Entra ID group per Kubernetes role,
    # bound by RoleBindings platform-<role>. Lab groups grp-onek8s-dev-ext-fi-example-<role>, each with
    # a tester application the isolation tests sign in as (tests/isolation/namespace-access-testers.yaml).
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
      # The zone's domain, for the hostnames of the team's routes.
      substitute = {
        zone_domain = "ext-fi.dev.onek8s.lol"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-ext-stateless-az2"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform gateway publishes Flux's webhook receiver
# (flux-webhook-dev-ext-stateless-az2.onek8s.lol), checked against the token shared/ keeps in the platform
# vault.
flux_github_webhook = true
