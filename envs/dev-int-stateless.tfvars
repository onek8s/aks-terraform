# What every stateless cell of the OneK8s dev environment shares - applied before the cell's own file:
#
#   terraform apply -var-file=envs/dev-int-stateless.tfvars -var-file=envs/dev-int-stateless-az2.tfvars
#
# (Deploy passes both.) A cell's file holds what tells it from its siblings: its name, availability zone and
# network, its zones and namespaces, its Flux path, and the network mode under study (overlay in az2, pod
# subnet in az3; design H15). shared/envs/dev.tfvars is applied first: the resource group, the cells'
# networks, the vaults, the registry and the workspace named below are its.

location = "germanywestcentral"

# ---------------------------------------------------------------------------------------------------
# Non-production cost savings
#
# Every setting in this block departs from the module's defaults, which are the production settings
# of the OneK8s design (acc and prd use the defaults). Together they let a lab cell run on ONE small
# system node instead of two larger ones (default_node_pool, in each cell's file), at the price of an
# SLA, of Azure's standard gateway and of pod right-sizing. Do not copy this block to an acceptance or
# production environment. They depend on each other: the single 8 GiB system node (~5.8 GiB
# allocatable) holds the platform only with Traefik and without the VPA add-on. Going back to
# production means all of them together.
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

# The dev environment's resource group, created by shared/. It holds every cluster of the environment
# and what they share. Every cell's system pool is in its network's snet-system.
resource_group_name = "rg-aks-dev"
node_subnet_name    = "snet-system"

# The internal exposure (design D52): the internal zones only; sub-aks-dev plays sub-aks-dev-int.
exposure = "int"

# The environment's platform Key Vault, created by shared/: the gateways' certificates, the Grafana
# Cloud credentials - and each cluster's customer-managed keys, created in it (design section 4.2):
# key-<cluster>-kms for the secrets in etcd, key-<cluster>-disk for every node's OS disk (encryption
# at host covers the ephemeral one). KMS data encryption (preview): AKS reaches the vault - which takes
# no public network access - as a trusted service; classic KMS would need API Server VNet Integration,
# which the encrypted cell network refuses (D58, D60).
key_vault_name = "kv-onek8s-gwc-platform"
customer_managed_keys = {
  key_vault_name           = "kv-onek8s-gwc-platform"
  key_vault_network_access = "Private"
  kms_data_encryption      = true
}

# The public zone onek8s.lol in rg-onek8s-dns, provisioned outside Terraform. Each cluster's
# external-dns gets an identity of its own, granted on it; an internal cell publishes nothing there -
# its zones' names go into shared/'s private zones (internal_dns_zone_names, per cell).
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_resource_group_name = "rg-onek8s-dns"

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from.
persistent_storage_enabled = false
portable_disks_enabled     = false

# The environment's container registry, created by shared/. The kubelet pulls the images from it as
# the cluster's identity, with AcrPull - no image pull secret.
container_registry_name = "acronek8sdev"

# The environment's Log Analytics workspace, created by shared/: each cluster's Kubernetes audit log
# (kube-audit-admin and guard) - design section 6.2, CIS AKS Benchmark 2.1.1.
log_analytics_workspace_name = "log-dev-platform"

# AKS Image Integrity (preview): Ratify checks the Notation signature of every image for the Azure
# Policy add-on, which reports unsigned ones (audit only). Its identity and the signing certificate
# are shared/'s (image_signing).
image_integrity_enabled = true

# The private API server (design D58) over Private Link: its private endpoint is in snet-system, reached
# by the nodes directly and by the management network, the labfw VPN and the GitHub runners (which join
# that VPN) through the hub. No private DNS zone: the cell resolves through labfw's DNS proxy in the hub,
# so the public FQDN names the private address.
private_cluster_public_fqdn_enabled = true
private_dns_zone_mode               = "none"

# No Flux webhook: an internal cell has no public entry point for GitHub's deliveries (behind labfw a
# public load balancer cannot answer), so no platform gateway either. Flux polls every minute.
flux_github_webhook = false

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster. None yet in the build tenant.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# The Azure Policy add-on (design section 2.7): Gatekeeper evaluates the policies that
# onek8s/azure-landing-zone assigns to the subscription (stacks/aks-policy).
azure_policy_enabled = true
