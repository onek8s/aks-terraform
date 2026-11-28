# Flux's webhook receivers behind an API Management instance that exists already (`api_management`;
# none in the lab - APIM is too expensive for it). Off unless one is named.
#
#   GitHub / Azure DevOps --HTTPS--> <APIM gateway>/<path>/<cell>/hook/<digest>
#     --> https://flux-webhook-<cell>.<dns_zone_name>/hook/<digest> (the cell's platform gateway)
#     --> notification-controller --> the Receiver whose path is /hook/<digest>
#
# One API per cell, each with a single POST operation and no subscription key (neither GitHub nor
# Azure DevOps can send one): the path's digest is the Receiver's own secret, and a GitHub Receiver
# checks the delivery's signature too - APIM passes body and headers through unchanged. Flux has no
# Azure DevOps Receiver type: an Azure DevOps service hook posts to a `generic` Receiver's path.
# APIM must reach each cell's platform gateway (`flux_github_webhook` of the cell).
locals {
  api_management = var.api_management == null ? null : {
    subscription_id     = split("/", var.api_management.id)[2]
    resource_group_name = split("/", var.api_management.id)[4]
    name                = split("/", var.api_management.id)[8]
  }
  api_management_cells = local.api_management == null ? {} : local.cells
}

data "azurerm_api_management" "flux_webhooks" {
  count    = local.api_management == null ? 0 : 1
  provider = azurerm.api_management

  name                = local.api_management.name
  resource_group_name = local.api_management.resource_group_name
}

resource "azurerm_api_management_api" "flux_webhook" {
  for_each = local.api_management_cells
  provider = azurerm.api_management

  name                  = "flux-webhook-${each.key}"
  display_name          = "Flux webhook ${each.key}"
  api_management_name   = local.api_management.name
  resource_group_name   = local.api_management.resource_group_name
  revision              = "1"
  path                  = "${var.api_management.path}/${each.key}"
  protocols             = ["https"]
  service_url           = "https://flux-webhook-${each.key}.${coalesce(var.dns_zone_name, "-")}"
  subscription_required = false

  lifecycle {
    precondition {
      condition     = var.flux_github_webhook && var.dns_zone_name != null
      error_message = "api_management routes to the cells' Flux webhook receivers: it needs flux_github_webhook (their token) and dns_zone_name (their hostnames)."
    }
  }
}

resource "azurerm_api_management_api_operation" "flux_webhook" {
  for_each = local.api_management_cells
  provider = azurerm.api_management

  operation_id        = "hook"
  display_name        = "Webhook delivery"
  api_name            = azurerm_api_management_api.flux_webhook[each.key].name
  api_management_name = local.api_management.name
  resource_group_name = local.api_management.resource_group_name
  method              = "POST"
  url_template        = "/hook/{digest}"

  template_parameter {
    name     = "digest"
    type     = "string"
    required = true
  }
}
