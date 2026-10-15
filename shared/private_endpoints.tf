# Private endpoints of the environment's services (OneK8s design sections 5 and 8; backlog item 3): the
# platform vault, every zone vault and - only on the Premium SKU, which Azure requires for it - the
# container registry, in the environment network's shared
# private endpoint subnet (the design's snet-shared-pe of the backend spoke), registered in the landing
# zone's private link DNS zones in the hub. The cells and the management network - the labfw VPN's
# clients among them - resolve the services through the hub firewall's DNS proxy, which answers from
# those zones: the private address. With `hub`, the environment network is peered with the hub, so the
# firewall reaches the endpoints.
#
# Public network access stays on while the deployment pipelines run on GitHub-hosted runners, which
# only reach the public endpoints (Deploy, Renew certificate, Sign images, Store secret).
locals {
  private_endpoints = var.private_endpoints != null
  private_dns_zone_ids = local.private_endpoints ? {
    vault    = "${var.private_endpoints.dns_zone_resource_group_id}/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    registry = "${var.private_endpoints.dns_zone_resource_group_id}/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
  } : {}

  # key => the service and its sub-resource
  private_endpoint_targets = !local.private_endpoints ? {} : merge(
    { "kv-platform" = { id = azurerm_key_vault.this.id, name = azurerm_key_vault.this.name, subresource = "vault" } },
    { for zone, vault in azurerm_key_vault.zone : "kv-${zone}" => { id = vault.id, name = vault.name, subresource = "vault" } },
    var.container_registry_name == null || var.container_registry_sku != "Premium" ? {} : {
      acr = { id = azurerm_container_registry.this[0].id, name = azurerm_container_registry.this[0].name, subresource = "registry" }
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
    private_dns_zone_ids = [local.private_dns_zone_ids[each.value.subresource]]
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
