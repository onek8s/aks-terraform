# Cell `stateless-az1` of the OneK8s dev environment - a stateless cluster in availability zone 1
# (OneK8s design section 8), on the Free tier: one system node, no uptime SLA. Its sibling is
# aks-dev-stateless-az2 (envs/dev-stateless-az2.tfvars); every external application runs in both,
# and Azure Traffic Manager hands out one or the other (shared/: global_hostnames).
# shared/envs/dev.tfvars is applied first.
#
#   terraform workspace select -or-create dev-stateless-az1
#   terraform apply -var-file=envs/dev-stateless-az1.tfvars

name     = "aks-dev-stateless-az1"
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
virtual_network_name = "vnet-dev-stateless-az1"
node_subnet_name     = "snet-system"

isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes" }
  int-se = { node_subnet_name = "snet-int-se-nodes" }
  ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
  ext-se = { node_subnet_name = "snet-ext-se-nodes" }
}

# Azure CNI Overlay powered by Cilium with ACNS: Hubble, FQDN network policies and eBPF host routing
# (design section 16).
advanced_networking = {}

# SHARED. The environment's platform Key Vault, created by shared/ and looked up here: the gateways'
# certificates, the Flux webhook token - and this cluster's customer-managed keys, created here in it
# (design section 18): key-aks-dev-stateless-az1-kms for the secrets in etcd, key-...-disk for every
# node's OS disk.
key_vault_name   = "kv-onek8s-dev-platform"
key_vault_create = false
customer_managed_keys = {
  key_vault_name = "kv-onek8s-dev-platform"
}

# The platform's namespaces with a share of the platform vault: each zone's gateway and the platform
# gateway read their listener certificate, `<namespace>--wildcard`. flux-system is added for the
# webhook token, and every managed namespace below on its own.
key_vault_namespaces = ["platform-gateway", "int-fi-gateway", "int-se-gateway", "ext-fi-gateway", "ext-se-gateway"]

# An application namespace's share is in its zone's vault (design section 6).
key_vault_namespace_vaults = {
  ext-fi-example = "kv-onek8s-dev-ext-fi"
}

# SHARED. The public zone onek8s.lol - the external zones' names and the platform gateway's - in
# rg-onek8s-dns, provisioned outside Terraform; and the internal zones' private zones, created by
# shared/ in rg-aks-dev and linked to the cells' networks. This cluster's external-dns gets an
# identity of its own, granted on all of them.
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"
internal_dns_zone_names      = ["int-fi.dev.onek8s.lol", "int-se.dev.onek8s.lol"]

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from.
persistent_storage_enabled = false
portable_disks_enabled     = false

# SHARED. The environment's container registry, created by shared/. The kubelet pulls the images from
# it as this cluster's identity, with AcrPull - no image pull secret.
container_registry_name = "acronek8sdev"

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

# The system pool: one amd64 node in availability zone 1, 4 vCPU and 8 GiB (the platform's
# controllers and the Azure Policy add-on do not fit in 2), on Azure Linux 3.0 - which eBPF host
# routing needs on every node - with encryption at host, SSH off and the CriticalAddonsOnly taint:
# only the platform's own controllers run here, every isolation zone's pods on that zone's NAP nodes.
# Standard_D4als_v6 is offered in both zones the cells use and supports VNet encryption. A system
# node pool cannot run on Spot VMs, and a node pool cannot change its architecture or OS in place.
default_node_pool = {
  vm_size             = "Standard_D4als_v6"
  availability_zones  = ["1"]
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

# The `example` team's application, in the ext-fi zone (design section 7: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys stateless/ of
# onek8s/aks-fluxcd-example into it, and its routes attach to the ext-fi gateway. Ingress and egress
# are closed to its own namespace by the namespace's default policies; the platform's Cilium baseline
# opens DNS and the zone gateway, and the team's own FQDN policy anything outside the cluster.
managed_namespaces = {
  ext-fi-example = {
    labels = {
      "platform/zone" = "ext-fi"
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
  path   = "./clusters/dev-stateless-az1"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform gateway publishes Flux's webhook receiver
# (flux-webhook-dev-stateless-az1.onek8s.lol), checked against the token shared/ keeps in the platform
# vault.
flux_github_webhook = true
