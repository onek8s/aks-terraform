# What an environment's clusters share: the Key Vault and the identities their namespaces read it as,
# and the DNS zones they publish their hostnames in. In a state of its own, so that any cluster of the
# environment can be destroyed, built again or replaced by the next while all of this stays - which is
# what lets a workload move from one cluster to another. Each cluster looks these up by name (its
# `key_vault_create = false`, `dns_zone_create = false`) and adds only what is its own: a federated
# credential on each identity, and its external-dns's grant on the zones. See the README, "Shared
# resources".
#
# Everything here is named as the environment's - `shared` in an identity's name, the environment in
# the vault's - where a cluster's resources carry the cluster's name.

data "azurerm_client_config" "current" {}

# The resource group everything shared - and every cluster of the environment - lives in. Created here
# with resource_group_create, so an empty subscription from the landing zone is all an environment
# needs; otherwise it exists already and is only named.
resource "azurerm_resource_group" "this" {
  count = var.resource_group_create ? 1 : 0

  name     = local.names.resource_group
  location = var.location
}

# The resource group, whichever way it came to be: the resources below wait for it this way.
locals {
  resource_group_name = var.resource_group_create ? azurerm_resource_group.this[0].name : local.names.resource_group
}

# The clusters' network, with virtual_network_create: one virtual network, and the subnets the
# clusters' node pools name in node_subnet_name and their pods in pod_subnet_name (a subnet whose name
# ends in `-pods` is delegated to AKS, as Azure CNI Pod Subnet needs). Without it, virtual_network_name
# names a network that exists already.
resource "azurerm_virtual_network" "this" {
  count = var.virtual_network_create ? 1 : 0

  name                = var.virtual_network_name
  location            = var.location
  resource_group_name = local.resource_group_name
  address_space       = var.virtual_network_address_space
}

resource "azurerm_subnet" "this" {
  for_each = var.virtual_network_create ? var.subnets : {}

  name                 = each.key
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [each.value]

  # A pod subnet, as a cell's (cells.tf).
  dynamic "delegation" {
    for_each = endswith(each.key, "-pods") ? [1] : []
    content {
      name = "aks-delegation"
      service_delegation {
        name    = "Microsoft.ContainerService/managedClusters"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

check "a_created_network_is_named" {
  assert {
    condition     = !var.virtual_network_create || (var.virtual_network_name != null && length(var.virtual_network_address_space) > 0)
    error_message = "virtual_network_create needs virtual_network_name and virtual_network_address_space."
  }
}

module "conventions" {
  source = "../modules/conventions"

  location             = var.location
  environment          = var.environment
  exposure             = var.exposure
  naming               = var.naming
  key_vault_namespaces = toset(keys(var.key_vault_namespaces))
  names                = local.name_requests
}

# The names of what this configuration creates, from the naming policy (var.naming, see
# modules/conventions) - a variable that names a resource itself wins. A cell's network, NSGs and
# route table take the cell's key (`dev-int-stateless-az3`) as their `{name}`, a zone's route table the cell and
# the zone (`dev-int-stateless-az3-int-se`), a zone's vault the zone.
locals {
  name_requests = merge(
    # Only the names no variable gives: a resource named in its variable needs nothing of the policy.
    var.resource_group_name != null ? {} : { resource_group = { type = "resource_group" } },
    var.key_vault_name != null ? {} : { key_vault = { type = "key_vault", name = "platform" } },
    var.container_registry_name != null || !var.container_registry_create ? {} : { container_registry = { type = "container_registry" } },
    var.log_analytics_workspace_name != null || !var.log_analytics_workspace_create ? {} : { log_analytics_workspace = { type = "log_analytics_workspace", name = "platform" } },
    try(var.ai_foundry.name, "-") != null ? {} : { ai_services = { type = "ai_services", name = "agents" } },
    var.monthly_budget == null ? {} : { consumption_budget = { type = "consumption_budget" } },
    { for zone in keys(local.isolation_zones) : "zone_key_vault/${zone}" => { type = "key_vault", name = zone } if !contains(keys(var.zone_key_vault_names), zone) },
    { for cell in keys(local.cells) : "virtual_network/${cell}" => { type = "virtual_network", name = cell } },
    { for cell in keys(local.cells) : "route_table/${cell}" => { type = "route_table", name = cell } if var.hub != null },
    { for key, table in local.cell_zone_route_tables : "route_table/${key}" => { type = "route_table", name = "${table.cell}-${table.zone}" } },
    { for key, subnet in local.cell_subnets : "network_security_group/${key}" => { type = "network_security_group", name = "${subnet.cell}-${trimprefix(subnet.name, "snet-")}" } },
    { for name in keys(local.global_hostnames) : "traffic_manager_profile/${name}" => { type = "traffic_manager_profile", name = replace(name, ".", "-"), domain = coalesce(var.dns_zone_name, "-") } },
  )

  names = merge(module.conventions.names, {
    resource_group          = coalesce(var.resource_group_name, try(module.conventions.names.resource_group, null))
    key_vault               = coalesce(var.key_vault_name, try(module.conventions.names.key_vault, null))
    container_registry      = var.container_registry_name != null ? var.container_registry_name : try(module.conventions.names.container_registry, null)
    log_analytics_workspace = var.log_analytics_workspace_name != null ? var.log_analytics_workspace_name : try(module.conventions.names.log_analytics_workspace, null)
    ai_services             = var.ai_foundry == null ? null : coalesce(var.ai_foundry.name, try(module.conventions.names.ai_services, null))
  })

  # Every enabled isolation zone's vault: its name in zone_key_vault_names, or the policy's.
  zone_key_vault_names = {
    for zone in keys(local.isolation_zones) : zone => lookup(var.zone_key_vault_names, zone, try(local.names["zone_key_vault/${zone}"], null))
  }
}

locals {
  # Each writer of each namespace, keyed like the cluster configuration's namespace grants.
  key_vault_writers = {
    for writer in flatten([
      for namespace, share in var.key_vault_namespaces : [
        for writer in share.writers : merge(writer, { namespace = namespace })
      ]
    ]) : "${writer.namespace}/writer/${writer.principal_id}" => writer
  }

  # The namespace's groups, as on its Kubernetes Secrets: `admin` manages its secrets, like its
  # writers - and merged with them, so a group that is both is granted once; `edit` writes and updates
  # them without reading a value (the Secrets Editor role below), unless it is also the admin group or
  # a writer, which grants more; `view` gets nothing, as Kubernetes' `view` sees no Secret.
  key_vault_group_writers = merge({
    for grant in flatten([
      for namespace, share in var.key_vault_namespaces : [
        for group in compact([share.groups.admin]) : {
          namespace      = namespace
          principal_id   = lower(group)
          principal_type = "Group"
        }
      ]
    ]) : "${grant.namespace}/writer/${grant.principal_id}" => grant
  }, local.key_vault_writers)

  key_vault_group_editors = {
    for grant in flatten([
      for namespace, share in var.key_vault_namespaces : [
        for group in compact([share.groups.edit]) : {
          namespace    = namespace
          principal_id = lower(group)
        }
      ]
    ]) : "${grant.namespace}/editor/${grant.principal_id}" => grant
    if !contains(keys(local.key_vault_group_writers), "${grant.namespace}/writer/${grant.principal_id}")
  }
}

# The vault, on the Azure RBAC permission model - access policies know no conditions - and reached
# over its private endpoint (private_endpoints.tf), authenticated with Entra ID. With isolation zones it is the environment's
# platform vault (OneK8s design sections 4.1 and 4.2): the gateways' certificates, the clusters'
# customer-managed keys and the platform's own secrets, while the applications' secrets live in their
# zone's vault below.
resource "azurerm_key_vault" "this" {
  location                   = var.location
  name                       = local.names.key_vault
  resource_group_name        = local.resource_group_name
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled = true
  # A deleted secret can be recovered for the default 90 days. Purge protection stays off unless the
  # vault holds customer-managed keys - a disk encryption set refuses a key from a vault without it -
  # so that a prototype's vault can otherwise be purged and its name reused.
  purge_protection_enabled = var.key_vault_purge_protection_enabled
  # Without public network access only through its private endpoint - and Azure's trusted services: the clusters'
  # disk encryption sets and KMS (AKS's KMS data encryption, private mode) use the keys here
  public_network_access_enabled = local.public_network_access
  network_acls {
    default_action = local.public_network_access ? "Allow" : "Deny"
    bypass         = "AzureServices"
  }
}

# One vault per isolation zone (design section 2.5): the secrets of the zone's applications, each
# application reading only its own under an ABAC condition, as below. Nothing of one zone is in
# another zone's vault.
resource "azurerm_key_vault" "zone" {
  for_each = local.zone_key_vault_names

  location                   = var.location
  name                       = each.value
  resource_group_name        = local.resource_group_name
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  # Without public network access only through its private endpoint (the zone's External Secrets Operator)
  public_network_access_enabled = local.public_network_access
  network_acls {
    default_action = local.public_network_access ? "Allow" : "Deny"
    bypass         = "AzureServices"
  }
}

locals {
  # The vault each namespace's share is in: its zone's, or the platform vault for a namespace with no
  # zone.
  key_vault_ids = merge({ for zone, vault in azurerm_key_vault.zone : zone => vault.id }, { "" = azurerm_key_vault.this.id })
  namespace_key_vault_ids = {
    for namespace, share in var.key_vault_namespaces : namespace => local.key_vault_ids[share.zone == null ? "" : share.zone]
  }
  namespace_key_vault_uris = {
    for namespace, share in var.key_vault_namespaces : namespace => share.zone == null ? azurerm_key_vault.this.vault_uri : azurerm_key_vault.zone[share.zone].vault_uri
  }
}

# The identity each namespace reads its own secrets as, in every cluster of the environment. A cluster
# adds a federated credential of its own for its namespace's `key-vault` service account; Azure
# allows 20 on an identity.
resource "azurerm_user_assigned_identity" "key_vault" {
  for_each = var.key_vault_namespaces

  location            = var.location
  name                = module.conventions.shared_key_vault_identity_names[each.key]
  resource_group_name = local.resource_group_name
}

# Reading the namespace's own secrets, by name. Listing the vault is refused - see the README, "Key
# Vault" - and left to the platform viewers.
resource "azurerm_role_assignment" "key_vault_namespace_reader" {
  for_each = var.key_vault_namespaces

  principal_id         = azurerm_user_assigned_identity.key_vault[each.key].principal_id
  scope                = local.namespace_key_vault_ids[each.key]
  role_definition_name = "Key Vault Secrets User"
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = module.conventions.key_vault_read_conditions[each.key]
}

# Managing the namespace's own secrets, and no others.
resource "azurerm_role_assignment" "key_vault_namespace_writer" {
  for_each = local.key_vault_group_writers

  principal_id         = each.value.principal_id
  scope                = local.namespace_key_vault_ids[each.value.namespace]
  role_definition_name = "Key Vault Secrets Officer"
  principal_type       = each.value.principal_type
  condition_version    = "2.0"
  condition            = module.conventions.key_vault_write_conditions[each.value.namespace]
}

# The `edit` groups' role (OneK8s design section 2.6, D51): write and update a secret and read its
# attributes, never its value - see modules/conventions. Defined and assignable at the environment's
# resource group, like the platform viewers' role; custom role names are unique in the tenant, hence
# the resource group in the name.
resource "azurerm_role_definition" "key_vault_secrets_editor" {
  count = length(local.key_vault_group_editors) > 0 ? 1 : 0

  name              = coalesce(var.key_vault_secrets_editor_role_name, "OneK8s Key Vault Secrets Editor (${local.resource_group_name})")
  scope             = local.resource_group_id
  assignable_scopes = [local.resource_group_id]
  description       = "Writes and updates Key Vault secrets and reads their attributes, without reading a value. Assigned under an ABAC condition holding it to one namespace's secrets."

  permissions {
    data_actions = module.conventions.key_vault_secrets_editor_data_actions
  }

  depends_on = [azurerm_resource_group.this]
}

# Writing the namespace's own secrets without reading them, and no others.
resource "azurerm_role_assignment" "key_vault_namespace_editor" {
  for_each = local.key_vault_group_editors

  principal_id       = each.value.principal_id
  scope              = local.namespace_key_vault_ids[each.value.namespace]
  role_definition_id = azurerm_role_definition.key_vault_secrets_editor[0].role_definition_resource_id
  principal_type     = "Group"
  condition_version  = "2.0"
  condition          = module.conventions.key_vault_edit_conditions[each.value.namespace]
}

# Every vault, whole: the platform's secrets and certificates - the gateways' listener certificates
# - are put there by them.
resource "azurerm_role_assignment" "key_vault_admin" {
  for_each = {
    for pair in setproduct(var.key_vault_admin_group_object_ids, keys(local.key_vault_ids)) : "${pair[0]}/${pair[1]}" => { group = pair[0], vault = pair[1] }
  }

  principal_id         = each.value.group
  scope                = local.key_vault_ids[each.value.vault]
  role_definition_name = "Key Vault Administrator"
  principal_type       = "Group"
}

# The token GitHub signs the Flux webhook's deliveries with, in flux-system's share of the vault - and
# in the share of every team namespace of flux_github_webhook_namespaces, whose own Receiver
# reconciles the team's repository. The Flux webhooks workflow sets it as the secret of the
# repositories' webhooks - one per cluster, each to its own hostname, all with this token.
resource "random_password" "flux_github_webhook" {
  count = var.flux_github_webhook ? 1 : 0

  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "flux_github_webhook" {
  count = var.flux_github_webhook ? 1 : 0

  key_vault_id = azurerm_key_vault.this.id
  name         = "flux-system--github-webhook-token"
  value        = random_password.flux_github_webhook[0].result
  content_type = "text/plain"

  lifecycle {
    precondition {
      condition     = contains(keys(var.key_vault_namespaces), "flux-system")
      error_message = "The Flux webhook's token is flux-system's secret, and flux-system has no share in key_vault_namespaces to read it with."
    }
  }
}

resource "azurerm_key_vault_secret" "flux_github_webhook_namespace" {
  for_each = var.flux_github_webhook ? toset(var.flux_github_webhook_namespaces) : toset([])

  key_vault_id = lookup(local.namespace_key_vault_ids, each.key, azurerm_key_vault.this.id)
  name         = "${each.key}--github-webhook-token"
  value        = random_password.flux_github_webhook[0].result
  content_type = "text/plain"

  lifecycle {
    precondition {
      condition     = contains(keys(var.key_vault_namespaces), each.key)
      error_message = "${each.key} has no share in key_vault_namespaces to read its webhook token with."
    }
  }
}

# The Isolation tests' fixture (design section 7.1, R7): a secret in the share of each namespace of
# isolation_test_namespaces, which the tests read as the namespace's own identity - and which every
# other namespace's identity must be refused.
resource "random_password" "isolation_test" {
  for_each = toset(var.isolation_test_namespaces)

  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "isolation_test" {
  for_each = toset(var.isolation_test_namespaces)

  key_vault_id = lookup(local.namespace_key_vault_ids, each.key, azurerm_key_vault.this.id)
  name         = "${each.key}--isolation-test"
  value        = random_password.isolation_test[each.key].result
  content_type = "text/plain"

  lifecycle {
    precondition {
      condition     = contains(keys(var.key_vault_namespaces), each.key)
      error_message = "${each.key} has no share in key_vault_namespaces to read its isolation test secret with."
    }
  }
}

# The one zone every cluster of the environment publishes in - public (Azure DNS) or private (Azure
# Private DNS, dns_zone_private). Each cluster's external-dns owns its own records under its own name,
# so the clusters never touch each other's - and a hostname moves with its workload.
#
# Either is created here with dns_zone_create, or looked up. dev's onek8s.lol is public and looked up:
# it was created once with the Azure CLI, outside every state, so that rebuilding the environment never
# changes the name servers the registrar points at. A public zone created here is delegated by
# pointing the registrar at its name servers (dns_zone_name_servers); a private one is linked to the
# clusters' network, so that its names resolve in every cluster of the environment and nowhere else.
resource "azurerm_dns_zone" "this" {
  count = var.dns_zone_name != null && var.dns_zone_create && !var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = coalesce(var.dns_zone_resource_group_name, local.resource_group_name)
}

resource "azurerm_private_dns_zone" "this" {
  count = var.dns_zone_name != null && var.dns_zone_create && var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = coalesce(var.dns_zone_resource_group_name, local.resource_group_name)
}

data "azurerm_virtual_network" "this" {
  count = length(azurerm_private_dns_zone.this) == 1 && !var.virtual_network_create && var.virtual_network_name != null ? 1 : 0

  name                = var.virtual_network_name
  resource_group_name = local.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count = length(azurerm_private_dns_zone.this) == 1 && var.virtual_network_name != null ? 1 : 0

  name                  = var.virtual_network_name
  resource_group_name   = azurerm_private_dns_zone.this[0].resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[0].name
  virtual_network_id    = one(concat(azurerm_virtual_network.this[*].id, data.azurerm_virtual_network.this[*].id))
}

check "a_created_private_zone_has_a_network_to_resolve_in" {
  assert {
    condition     = !(var.dns_zone_private && var.dns_zone_create) || var.virtual_network_name != null
    error_message = "The private zone ${coalesce(var.dns_zone_name, "-")} is created without virtual_network_name, so it is linked to no network and its names resolve nowhere."
  }
}

data "azurerm_dns_zone" "this" {
  count = var.dns_zone_name != null && !var.dns_zone_create && !var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = coalesce(var.dns_zone_resource_group_name, local.names.resource_group)
}

data "azurerm_private_dns_zone" "this" {
  count = var.dns_zone_name != null && !var.dns_zone_create && var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = coalesce(var.dns_zone_resource_group_name, local.names.resource_group)
}

locals {
  dns_zone = one(concat(azurerm_dns_zone.this, azurerm_private_dns_zone.this, data.azurerm_dns_zone.this, data.azurerm_private_dns_zone.this))
}

# Hostnames every external cell of the environment serves at once - hello.ext-fi.dev.onek8s.lol -
# behind an Azure Traffic Manager profile each: DNS answers with one cluster's public
# address or another's, weighted alike, and leaves out a cluster whose health probe fails. Each
# cluster's own public hostname (`public-<cluster>.<zone>`, published by its external-dns) is an
# endpoint, and the global hostname is a CNAME to the profile. The clusters' external-dns leave the
# global hostname alone (aks-fluxcd-platform excludes it), so this is its only record.
#
# The probe asks for the global hostname itself, with HTTPS - Traffic Manager does not check the
# certificate - on the path every cluster serves it on. A short TTL lets a client move to another
# cluster soon after one goes away.
locals {
  # Only for a deployed external zone: none in the internal exposure, none for a hostname whose zone
  # is not among the enabled isolation zones.
  global_hostnames = var.dns_zone_name == null || var.dns_zone_private || var.exposure == "int" ? {} : {
    for name, hostname in var.global_hostnames : name => hostname
    if hostname.zone == null || try(local.isolation_zones[hostname.zone].exposure == "ext", false)
  }
  global_hostname_endpoints = merge([
    for name, hostname in local.global_hostnames : {
      for endpoint in hostname.endpoints : "${name}/${endpoint}" => { name = name, target = endpoint }
    }
  ]...)
}

check "global_hostnames_need_a_public_zone" {
  assert {
    condition     = !var.dns_zone_private || length(var.global_hostnames) == 0
    error_message = "global_hostnames are Traffic Manager CNAMEs, which a private zone cannot point at: none is created."
  }
}

resource "azurerm_traffic_manager_profile" "global" {
  for_each = local.global_hostnames

  # Traffic Manager names are global (the DNS label below): the policy's `traffic_manager_profile`,
  # by default the zone, the environment and the hostname - whose dots a profile's name may not have.
  name                   = local.names["traffic_manager_profile/${each.key}"]
  resource_group_name    = local.resource_group_name
  traffic_routing_method = "Weighted"

  dns_config {
    relative_name = local.names["traffic_manager_profile/${each.key}"]
    ttl           = each.value.ttl
  }

  monitor_config {
    protocol                     = "HTTPS"
    port                         = 443
    path                         = each.value.health_path
    interval_in_seconds          = 30
    timeout_in_seconds           = 10
    tolerated_number_of_failures = 2

    custom_header {
      name  = "host"
      value = "${each.key}.${var.dns_zone_name}"
    }
  }
}

resource "azurerm_traffic_manager_external_endpoint" "global" {
  for_each = local.global_hostname_endpoints

  name       = replace(each.value.target, ".", "-")
  profile_id = azurerm_traffic_manager_profile.global[each.value.name].id
  target     = each.value.target
  weight     = 1
}

resource "azurerm_dns_cname_record" "global" {
  for_each = local.global_hostnames

  name                = each.key
  zone_name           = local.dns_zone.name
  resource_group_name = local.dns_zone.resource_group_name
  ttl                 = each.value.ttl
  target_resource_id  = azurerm_traffic_manager_profile.global[each.key].id
}
