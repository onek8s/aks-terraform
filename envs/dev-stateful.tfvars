# Cluster `stateful` of the OneK8s dev environment, on the Free tier: one system node pool, Azure CNI
# overlay with Cilium, no uptime SLA. Keeps state: persistent volumes, with the platform's
# `portable-disk` StorageClass whose disks outlive the cluster. Beside the stateless clusters
# (envs/dev-stateless-az<N>.tfvars) on the same shared resources, so that workloads can be moved
# between them. shared/envs/dev.tfvars is applied first. Defined, but not deployed for now.
#
#   terraform workspace select -or-create dev-stateful
#   terraform apply -var-file=envs/dev-stateful.tfvars

name     = "aks-dev-stateful"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# The dev environment's resource group, created by shared/envs/dev.tfvars. It holds every cluster of
# the environment and what they share. What is this cluster's own carries its name (`aks-dev-stateful`,
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

# SHARED. The one zone the Gateway's hostnames are published in, onek8s.lol - public, provisioned
# outside Terraform in rg-onek8s-dns. This cluster's external-dns gets an identity of its own,
# granted on the zone, and owns its own records in it; the Flux repository is told where it is and
# whether it is public or private (dns_zone_private).
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"

# The disks of the platform's `portable-disk` StorageClass go to resource_group_name rather than the
# node resource group, so they outlive this cluster. The cluster identity is granted a role of its
# own for disks there, and nothing else.
portable_disks_enabled = true

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

# The Azure Policy add-on (OneK8s design section 14): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy) and reports the
# cluster's compliance to Azure Policy. Its pods ask for about 360m CPU and 868Mi of memory.
azure_policy_enabled = true

# Standard_D4pls_v5: one Arm64 node (Ampere Altra), 4 vCPU and 8 GiB, with availability zones.
# Two vCPU are not enough: the platform's pods ask for about 1600m of the 1900m a 2-vCPU node has,
# and the Azure Policy add-on for 360m more. Arm64 is cheaper than amd64 here - 0.146 USD an hour
# against 0.172 for Standard_D4als_v6 in swedencentral - and every image the clusters run is
# published for linux/arm64. Standard_D4pls_v6 (Cobalt 100, 0.132) had no capacity in the zone
# (OverconstrainedZonalAllocationRequest). A node pool cannot change its architecture: moving a cluster
# between amd64 and arm64 means building it again (the Deploy workflow's destroy, then apply). A
# system node pool cannot run on Spot VMs.
default_node_pool = {
  vm_size             = "Standard_D4pls_v5"
  enable_auto_scaling = false
  node_count          = 1
}

# The `example` team. Its own Flux configuration deploys apps/ of onek8s/aks-fluxcd-example into it -
# a public repository, read without a credential - and its apps publish themselves through the shared
# Gateway. It keeps the default closed ingress: a NetworkPolicy from aks-fluxcd-platform lets the
# Traefik pods in, and nothing else.
managed_namespaces = {
  example = {
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./apps"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-stateful"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform repository publishes Flux's webhook
# receiver (flux-webhook-dev-stateful.onek8s.lol), checked against the token shared/ keeps in the
# shared vault. flux-system gets this cluster's credential on its shared identity to read it.
flux_github_webhook = true
