# Private endpoints of the environment's services (OneK8s design sections 5 and 8; backlog item 3): the
# platform vault, every zone vault, the container registry (Premium only, which Azure requires for it: prd's, D62), the
# agents' Foundry resource and the Terraform state account, in the environment network's shared private endpoint
# subnet (the design's snet-shared-pe of the backend spoke), registered in the landing zone's private link DNS
# zones in the hub. The cells and the management network - the labfw VPN's clients among them, the GitHub-hosted
# runners too - resolve the services through the hub firewall's DNS proxy, which answers from those zones: the
# private address. With `hub`, the environment network is peered with the hub, so the firewall reaches the
# endpoints.
#
# private_endpoints.public_network_access = false (the user's ask, 2026-10-15: no public endpoints) then turns the
# services' public network access off - the vaults, the registry, Foundry, the state account and the environment's
# Log Analytics workspace (whose private path is the landing zone's Azure Monitor Private Link scope). Azure's
# trusted services keep their way in (bypass AzureServices): the disk encryption sets and KMS (the clusters' keys in
# the platform vault) and the registry's own build tasks. Every workflow that reads a data plane joins the labfw VPN
# first (.github/actions/labfw-vpn).
locals {
  private_endpoints = var.private_endpoints != null
  # Public network access of the environment's services: on without private endpoints
  public_network_access = !local.private_endpoints || try(var.private_endpoints.public_network_access, true)
  private_dns_zone_names = {
    vault    = ["privatelink.vaultcore.azure.net"]
    registry = ["privatelink.azurecr.io"]
    account  = ["privatelink.cognitiveservices.azure.com", "privatelink.openai.azure.com", "privatelink.services.ai.azure.com"]
    blob     = ["privatelink.blob.core.windows.net"]
  }
  private_dns_zone_ids = local.private_endpoints ? {
    for subresource, zones in local.private_dns_zone_names : subresource => [
      for zone in zones : "${var.private_endpoints.dns_zone_resource_group_id}/providers/Microsoft.Network/privateDnsZones/${zone}"
    ]
  } : {}

  # key => the service and its sub-resource
  private_endpoint_targets = !local.private_endpoints ? {} : merge(
    { "kv-platform" = { id = azurerm_key_vault.this.id, name = azurerm_key_vault.this.name, subresource = "vault" } },
    { for zone, vault in azurerm_key_vault.zone : "kv-${zone}" => { id = vault.id, name = vault.name, subresource = "vault" } },
    var.container_registry_name == null || !local.container_registry_premium ? {} : {
      acr = { id = azurerm_container_registry.this[0].id, name = azurerm_container_registry.this[0].name, subresource = "registry" }
    },
    var.ai_foundry == null ? {} : {
      foundry = { id = azurerm_cognitive_account.agents[0].id, name = azurerm_cognitive_account.agents[0].name, subresource = "account" }
    },
    var.private_endpoints.state_storage_account_id == null ? {} : {
      state = { id = var.private_endpoints.state_storage_account_id, name = element(split("/", var.private_endpoints.state_storage_account_id), 8), subresource = "blob" }
    },
  )
}

resource "azurerm_subnet" "private_endpoints" {
  count = local.private_endpoints ? 1 : 0

  name                              = var.private_endpoints.subnet_name
  resource_group_name               = local.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this[0].name
  address_prefixes                  = [var.private_endpoints.address_prefix]
  private_endpoint_network_policies = "Enabled"

  lifecycle {
    precondition {
      condition     = var.virtual_network_create
      error_message = "private_endpoints puts the endpoints into the environment network that virtual_network_create creates."
    }
  }
}

resource "azurerm_private_endpoint" "this" {
  for_each = local.private_endpoint_targets

  name                          = "pe-${each.value.name}"
  location                      = var.location
  resource_group_name           = local.resource_group_name
  subnet_id                     = azurerm_subnet.private_endpoints[0].id
  custom_network_interface_name = "nic-pe-${each.value.name}"

  private_service_connection {
    name                           = "psc-${each.value.name}"
    private_connection_resource_id = each.value.id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "hub"
    private_dns_zone_ids = local.private_dns_zone_ids[each.value.subresource]
  }
}

# The environment network and the hub, peered both ways, so the hub firewall reaches the endpoints.
resource "azurerm_virtual_network_peering" "environment_to_hub" {
  count = var.hub != null && var.virtual_network_create ? 1 : 0

  name                         = "peer-${var.virtual_network_name}-to-hub"
  resource_group_name          = local.resource_group_name
  virtual_network_name         = azurerm_virtual_network.this[0].name
  remote_virtual_network_id    = local.hub_virtual_network.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_environment" {
  provider = azurerm.hub
  count    = var.hub != null && var.virtual_network_create ? 1 : 0

  name                         = "peer-hub-to-${var.virtual_network_name}"
  resource_group_name          = local.hub_virtual_network.resource_group_name
  virtual_network_name         = local.hub_virtual_network.name
  remote_virtual_network_id    = azurerm_virtual_network.this[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# The Terraform state account (Deploy's TF_STATE_STORAGE_ACCOUNT): the workflow creates it before any state exists,
# so it is not a resource of this configuration - only its network access and authentication are set here. Entra
# ID only (the backend's use_azuread_auth), and with public_network_access = false only through its private
# endpoint: Deploy joins the labfw VPN before `terraform init`. Break glass, should the VPN or the endpoint be gone:
# Lab admin `az storage account update --public-network-access Enabled` (Azure Resource Manager stays reachable).
resource "azapi_update_resource" "state_storage" {
  count = local.private_endpoints && try(var.private_endpoints.state_storage_account_id, null) != null ? 1 : 0

  type        = "Microsoft.Storage/storageAccounts@2023-05-01"
  resource_id = var.private_endpoints.state_storage_account_id
  body = {
    properties = {
      allowSharedKeyAccess = false
      publicNetworkAccess  = local.public_network_access ? "Enabled" : "Disabled"
      networkAcls = {
        defaultAction = local.public_network_access ? "Allow" : "Deny"
        bypass        = "AzureServices"
      }
    }
  }

  # The endpoint first, so the runner that applies this still reaches the state afterwards
  depends_on = [azurerm_private_endpoint.this]
}
