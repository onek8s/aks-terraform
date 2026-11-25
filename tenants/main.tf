# The environment's tenants: every application namespace of every cell, apart from the cells
# themselves (design section 3.3). A tenant is one file of the catalogue; this stack turns it into what
# each cell of its zone needs for it - the managed namespace with its owner, quota, default policies and
# placement, its groups' namespace access, its Flux configurations (the team's repository and the
# platform's part of the namespace) and the federation of its vault identity with each cell. The cells
# keep what is the cluster's: node pools - a dedicated pool too, which a tenant only refers to - Flux,
# the gateways. shared/ reads the same catalogue for each namespace's identity and vault grants.

locals {
  # API versions, as in the cells (locals.tf of the repository root).
  aks_api_version                      = "2026-05-02-preview"
  kubernetes_configuration_api_version = "2024-11-01"

  resource_group_id = "/subscriptions/${coalesce(var.subscription_id, data.azurerm_client_config.current.subscription_id)}/resourceGroups/${var.resource_group_name}"

  # The catalogue's files, `<namespace>.yaml`, then `tenants` on top.
  catalogue_files = var.catalogue_dir == null ? toset([]) : fileset("${path.root}/${var.catalogue_dir}", "*.yaml")
  catalogue = {
    for file in local.catalogue_files : trimsuffix(file, ".yaml") => yamldecode(file("${path.root}/${var.catalogue_dir}/${file}"))
  }
  tenants = module.schema.tenants

  # Each tenant in each cell it goes to, keyed `<cell>/<namespace>`: every cell holding its zone, or the
  # cells it names.
  cell_tenants = {
    for pair in flatten([
      for namespace, tenant in local.tenants : [
        for cell, settings in var.cells : {
          key       = "${cell}/${namespace}"
          cell      = cell
          namespace = namespace
          tenant    = tenant
        } if(tenant.cells == null ? contains(settings.zones, tenant.zone) : contains(tenant.cells, cell))
      ]
    ]) : pair.key => pair
  }

  # Every zone of every cell, keyed `<cell>/<zone>`, with the namespaces its gateway watches: its own and
  # each of its tenants' in that cell.
  cell_zones = {
    for pair in flatten([
      for cell, settings in var.cells : [
        for zone in settings.zones : {
          key  = "${cell}/${zone}"
          cell = cell
          zone = zone
          watch_namespaces = concat(["${zone}-gateway"], sort([
            for key, pair in local.cell_tenants : pair.namespace if pair.cell == cell && pair.tenant.zone == zone
          ]))
        }
      ]
    ]) : pair.key => pair
  }

  zones = toset([for tenant in values(local.tenants) : tenant.zone])

  # What each cell says about itself, read back from Azure.
  cluster_ids      = { for cell, cluster in data.azapi_resource.cluster : cell => cluster.id }
  oidc_issuer_urls = { for cell, cluster in data.azapi_resource.cluster : cell => cluster.output.issuer }
  network_policies = { for cell, cluster in data.azapi_resource.cluster : cell => try(cluster.output.network_policy, null) }
  platform_repository = {
    for cell, flux in data.azapi_resource.platform_flux_configuration : cell => {
      url                   = flux.output.url
      branch                = flux.output.branch
      sync_interval_seconds = flux.output.sync_interval_seconds
    }
  }
  # The labels of each of a cell's node pools (none: an empty map).
  pool_labels = {
    for cell, pools in data.azapi_resource_list.agent_pools : cell => [for labels in coalesce(try(pools.output.labels, null), []) : coalesce(labels, {})]
  }
}

data "azurerm_client_config" "current" {}

module "schema" {
  source = "./schema"

  tenants = merge(local.catalogue, var.tenants)
}

module "conventions" {
  source = "../modules/conventions"

  location             = var.location
  environment          = var.environment
  naming               = var.naming
  key_vault_namespaces = keys(local.tenants)
  names = {
    for zone in local.zones : "zone_key_vault/${zone}" => { type = "key_vault", name = zone } if !contains(keys(var.zone_key_vault_names), zone)
  }
}

# Each cell, by its name: its ID, its OIDC issuer (for the federations) and its network policy engine.
data "azapi_resource" "cluster" {
  for_each = var.cells

  type      = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  name      = each.key
  parent_id = local.resource_group_id

  response_export_values = {
    issuer         = "properties.oidcIssuerProfile.issuerURL"
    network_policy = "properties.networkProfile.networkPolicy"
  }
}

# The cell's own Flux configuration: its tenants' platform configurations read the same repository on
# the same branch (the cell's branch, design section 3.3).
data "azapi_resource" "platform_flux_configuration" {
  for_each = var.cells

  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  name      = "platform"
  parent_id = data.azapi_resource.cluster[each.key].id

  response_export_values = {
    url                   = "properties.gitRepository.url"
    branch                = "properties.gitRepository.repositoryRef.branch"
    sync_interval_seconds = "properties.gitRepository.syncIntervalInSeconds"
  }
}

# The cell's node pools' labels: which zones have pools of their own (placement) and which tenants a
# dedicated pool (`platform/pool=<namespace>`, the cell's namespace_node_pools).
data "azapi_resource_list" "agent_pools" {
  for_each = var.cells

  type      = "Microsoft.ContainerService/managedClusters/agentPools@${local.aks_api_version}"
  parent_id = data.azapi_resource.cluster[each.key].id

  response_export_values = {
    labels = "value[].properties.nodeLabels"
  }
}

# The identity each namespace reads its share of its zone's vault as - shared/'s, the same in every cell.
data "azurerm_user_assigned_identity" "key_vault" {
  for_each = local.tenants

  name                = module.conventions.shared_key_vault_identity_names[each.key]
  resource_group_name = var.resource_group_name
}

# Each zone's vault, which holds its tenants' shares.
data "azurerm_key_vault" "zone" {
  for_each = local.zones

  name                = lookup(var.zone_key_vault_names, each.key, try(module.conventions.names["zone_key_vault/${each.key}"], null))
  resource_group_name = var.resource_group_name
}

# The cluster's credential on each tenant's identity, named after the cluster: an identity carries one
# per cell of the environment (Azure allows 20), and a cell that leaves the list takes its own along.
resource "azurerm_federated_identity_credential" "key_vault" {
  for_each = local.cell_tenants

  name                      = "aks-${each.value.cell}"
  user_assigned_identity_id = data.azurerm_user_assigned_identity.key_vault[each.value.namespace].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.oidc_issuer_urls[each.value.cell]
  subject                   = "system:serviceaccount:${each.value.namespace}:key-vault"
}
