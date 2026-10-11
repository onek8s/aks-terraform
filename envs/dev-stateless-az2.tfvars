# Cluster `stateless-az2` of the OneK8s dev environment, on the Free tier: one system node pool,
# Azure CNI overlay with Cilium, no uptime SLA. Stateless: no persistent storage at all. One of the
# environment's stateless clusters with aks-dev-stateless-az1 (envs/dev-stateless-az1.tfvars): both
# run the same apps, and hello.onek8s.lol is served by whichever of them DNS hands out (shared/:
# global_hostnames). Its node pool is in availability zone 2. shared/envs/dev.tfvars is applied
# first.
#
#   terraform workspace select -or-create dev-stateless-az2
#   terraform apply -var-file=envs/dev-stateless-az2.tfvars

name     = "aks-dev-stateless-az2"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# The dev environment's resource group, created by shared/envs/dev.tfvars. It holds every cluster of
# the environment and what they share. What is this cluster's own carries its name (`aks-dev-stateless-az2`,
# `id-sec-dev-aks-...`); what is shared carries `shared` (`kv-onek8s-dev-shared`,
# `id-sec-dev-shared-kv-...`).
resource_group_name = "rg-aks-dev"

# The environment's network, created by shared/: every cluster's nodes share the subnet. With Azure
# CNI overlay only the nodes take addresses from it; the pod range is each cluster's own.
virtual_network_name = "vnet-aks-dev"
node_subnet_name     = "snet-aks-nodes"

# SHARED. The environment's Key Vault, created by shared/ and looked up here. It holds the secrets
# of every namespace - the listener certificates of ingress-gateway, the example team's - each
# namespace reading only the ones named `<namespace>--<name>`, as the environment's shared identity
# `id-sec-dev-shared-kv-<namespace>`. This cluster adds a federated credential of its own to
# each; every grant on the vault is shared/'s.
key_vault_name   = "kv-onek8s-dev-shared"
key_vault_create = false

# SHARED. The zones the Gateway's hostnames are published in, looked up here. The public one,
# onek8s.lol, lives in rg-onek8s-dns, created once outside Terraform; the private one is shared/'s.
# This cluster's external-dns gets an identity of its own, granted on both zones, and owns its own
# records in them; the Flux repository is told where they are.
dns_zone_name                = "onek8s.lol"
dns_zone_resource_group_name = "rg-onek8s-dns"
internal_dns_zone_name       = "internal.onek8s.lol"

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from. Hence no
# portable disks either, and the platform's clusters/dev-stateless-az2 runs no `portable-disk`
# StorageClass. Only workloads that keep no state run here - the `example` team syncs `stateless/` of
# its repository, without boot-log.
persistent_storage_enabled = false
portable_disks_enabled     = false

# SHARED. The environment's container registry, created by shared/ and looked up here - not part of
# the landing zone. The kubelet pulls the images from it as this cluster's identity, with AcrPull -
# no image pull secret.
container_registry_name = "acronek8sdev"

# A public API server, open to every address: a lab with no network path into the VNet. Entra ID
# authenticates every call; local accounts are disabled.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster: `Azure Kubernetes Service RBAC Cluster Admin` for the admins, `... RBAC Reader` for
# the readers. Members of both still need `Azure Kubernetes Service Cluster User Role` on the
# cluster to download a kubeconfig at all, which is granted elsewhere. None yet in the build tenant.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# No Azure Policy add-on: its Gatekeeper alone asks for 360m CPU and 868Mi of memory, a fifth of
# the single small node; the landing zone audits the subscription with Azure Policy instead.
azure_policy_enabled = false

# Standard_D2als_v6: the smallest size with availability zones in swedencentral and quota in the
# subscription - Standard_B2s has no zones there (AvailabilityZoneNotSupported), and the B-series v2
# family has no quota. 2 vCPU, 4 GiB, amd64. A system node pool cannot run on Spot VMs.
default_node_pool = {
  vm_size             = "Standard_D2als_v6"
  availability_zones  = ["2"]
  enable_auto_scaling = false
  node_count          = 1
}

# The `example` team. Its own Flux configuration deploys stateless/ of onek8s/aks-fluxcd-example into
# it - the apps of apps/ that keep no state, aks-hello but not boot-log - from a public repository,
# read without a credential, and its apps publish themselves through the shared Gateway. It keeps
# the default closed ingress: a NetworkPolicy from aks-fluxcd-platform lets the Traefik pods in, and
# nothing else.
managed_namespaces = {
  example = {
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./stateless"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-stateless-az2"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform repository publishes Flux's webhook
# receiver (flux-webhook-dev-stateless-az2.onek8s.lol), checked against the token shared/ keeps in
# the shared vault. flux-system gets this cluster's credential on its shared identity to read it.
flux_github_webhook = true
