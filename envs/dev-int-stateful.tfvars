# The internal stateful cluster `int-stateful` of the OneK8s dev environment, on a lab budget (see "Non-production
# cost savings" below), Azure CNI Pod Subnet with Cilium. Keeps state: persistent volumes, with the platform's
# `portable-disk` StorageClass whose disks outlive the cluster. Beside the stateless clusters
# (envs/dev-int-stateless-az3.tfvars) on the same shared resources, so that workloads can be moved
# between them. shared/envs/dev.tfvars is applied first. Defined, but not deployed for now.
#
#   terraform workspace select -or-create dev-int-stateful
#   terraform apply -var-file=envs/dev-int-stateful.tfvars

name     = "aks-dev-int-stateful"
location = "germanywestcentral"

# Internal (design decision D52): the internal zones' stateful workloads only.
exposure = "int"

# ---------------------------------------------------------------------------------------------------
# Non-production cost savings
#
# Every setting in this block departs from the module's defaults, which are the production settings
# of the OneK8s design (acc and prd use the defaults). Do not copy it to an acceptance or production
# environment; delete it (or set each to its production value) to go back.
# ---------------------------------------------------------------------------------------------------

# AKS Free tier: no uptime SLA. Production: "Standard" (design D31).
sku_tier = "Free"

# The dev environment's resource group, created by shared/envs/dev.tfvars. It holds every cluster of
# the environment and what they share. What is this cluster's own carries its name (`aks-dev-int-stateful`,
# `id-sec-dev-aks-...`); what is shared carries `shared` (`id-sec-dev-shared-kv-...`).
resource_group_name = "rg-aks-dev"

# The environment's network, created by shared/: the nodes' subnet and the pods' (Azure CNI Pod Subnet).
virtual_network_name = "vnet-aks-dev"
node_subnet_name     = "snet-aks-nodes"
pod_subnet_name      = "snet-aks-pods"

# SHARED. The environment's platform Key Vault, created by shared/ and looked up here, and the
# int-fi zone's vault for the example team's secrets - each namespace reading only the ones named
# `<namespace>--<name>`, as the environment's shared identity `id-sec-dev-shared-kv-<namespace>`.
# This cluster adds a federated credential of its own to each; every grant on the vaults is shared/'s.
#
# Defined, not deployed: the stateful cluster of the design lives in the backend network with no
# gateway of its own (sections 3.1 and 4.1), which clusters/dev-int-stateful of the platform repository does
# not follow yet.
key_vault_name       = "kv-onek8s-gwc-platform"
key_vault_namespaces = []
key_vault_namespace_vaults = {
  int-fi-example = "kv-onek8s-gwc-int-fi"
}

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

# SHARED. The environment's Log Analytics workspace, created by shared/: this cluster's Kubernetes
# audit log (kube-audit-admin and guard) - design section 6.2, CIS AKS Benchmark 2.1.1.
log_analytics_workspace_name = "log-dev-platform"

# The private API server (design D58) over Private Link, like the cells': no private DNS zone, the
# public FQDN names the private address through the hub's DNS proxy.
private_cluster_public_fqdn_enabled = true
private_dns_zone_mode               = "none"

# OS patches in place (design section 3.5): the SecurityPatch channel patches the running nodes inside the
# maintenance window; Kubernetes versions move only through the pipeline (the default channel none).
auto_upgrade = {
  node_os_channel = "SecurityPatch"
}

# No Gateway API implementation: the stateful cluster has no gateway of its own (design R21), whatever
# the environment - not a cost saving.
gateway_implementation = null

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster: `Azure Kubernetes Service RBAC Cluster Admin` for the admins, `... RBAC Reader` for
# the readers. Members of both still need `Azure Kubernetes Service Cluster User Role` on the
# cluster to download a kubeconfig at all, which is granted elsewhere. None yet in the build tenant.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# The Azure Policy add-on (OneK8s design section 2.7): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy) and reports the
# cluster's compliance to Azure Policy. Its pods ask for about 360m CPU and 868Mi of memory.
azure_policy_enabled = true

# Non-production cost saving: ONE Standard_D4alds_v6 system node on an ephemeral OS disk (its local
# NVMe disk: no Premium SSD). Production: node_count = 2 on the default Standard_D4ds_v5 (design
# section 2.3).
#
# Standard_D4alds_v6: one amd64 node, 4 vCPU and 8 GiB, with availability zones 1 and 2. Two vCPU
# are not enough: the platform's pods ask for about 1600m of the 1900m a 2-vCPU node has, and the
# Azure Policy add-on for 360m more. The cheaper Arm64 sizes are not available for both zonal
# clusters in swedencentral: Standard_D4pls_v6 had no capacity in zone 1
# (OverconstrainedZonalAllocationRequest) and Standard_D4pls_v5 is offered in zone 2 only
# (AvailabilityZoneNotSupported), so the clusters stay on amd64 - 0.172 USD an hour. A node pool cannot change its architecture: moving a cluster
# between amd64 and arm64 means building it again (the Deploy workflow's destroy, then apply). A
# system node pool cannot run on Spot VMs.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  enable_auto_scaling = false
  node_count          = 1
}

# The `example` team. Its own Flux configuration deploys apps/ of onek8s/aks-fluxcd-example into it -
# a public repository, read without a credential - and its apps publish themselves through the shared
# Gateway. It keeps the default closed ingress: a Cilium policy from aks-fluxcd-platform lets the
# zone gateway's pods in, and nothing else.
managed_namespaces = {
  int-fi-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 2.6; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-fi"
    }
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./apps"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
      substitute = {
        zone_domain = "int-fi.dev.onek8s.lol"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateful"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}
