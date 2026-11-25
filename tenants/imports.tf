# The move of the lab's tenants out of the cell's state (2026-11): until then the cell
# aks-dev-int-stateless-az3 held them (managed_namespaces), and its state forgets them (`removed` in the
# repository root's main.tf and key_vault.tf). Imported here on the first apply, so nothing is created
# twice or deleted; once applied these blocks change nothing and can go.
#
# Order (README, "Tenants"): apply this stack first, merge the fleet's change that drops its per-tenant
# tenants/ directories, then apply the cell.

locals {
  # The tenants the cell's state held, in the cells they were in.
  migrated_tenants = [
    for key in ["aks-dev-int-stateless-az3/int-se-example", "aks-dev-int-stateless-az3/int-fi-example"] : key
    if contains(keys(local.cell_tenants), key)
  ]

  # The namespace grants of int-fi-example's groups, by their role assignments' names (Azure gives an
  # assignment a GUID of its own; read with Lab admin, `az role assignment list --all`).
  migrated_namespace_user_grants = {
    for key, name in {
      "aks-dev-int-stateless-az3/int-fi-example/namespace_user/6d9ae939-5e03-4ddb-b378-baa7fa5b5180" = "cbf7c435-85f6-4caf-3053-d53e45bf6f77"
      "aks-dev-int-stateless-az3/int-fi-example/namespace_user/88ba3f87-2d13-46ea-8cff-eeccf6cbd0bc" = "2530e073-209e-125e-9b0a-cc9c4275ce0e"
      "aks-dev-int-stateless-az3/int-fi-example/namespace_user/71438fbc-0666-4d82-be17-54b61236d657" = "bb4b9d00-c802-cc0c-30f9-cad1752c7ae1"
    } : key => name if contains(keys(local.namespace_user_grants), key)
  }
}

import {
  for_each = toset(local.migrated_tenants)
  to       = azapi_resource.namespace[each.key]
  id       = "${local.cluster_ids[local.cell_tenants[each.key].cell]}/managedNamespaces/${local.cell_tenants[each.key].namespace}?api-version=${local.aks_api_version}"
}

import {
  for_each = toset([for key in local.migrated_tenants : key if contains(keys(local.team_flux_configurations), key)])
  to       = azapi_resource.team_flux_configuration[each.key]
  id       = "${local.cluster_ids[local.cell_tenants[each.key].cell]}/providers/Microsoft.KubernetesConfiguration/fluxConfigurations/${local.cell_tenants[each.key].namespace}?api-version=${local.kubernetes_configuration_api_version}"
}

# Only int-fi-example had groups, and so an access configuration; int-se-example's is new.
import {
  for_each = toset([for key in local.migrated_tenants : key if endswith(key, "/int-fi-example")])
  to       = azapi_resource.platform_flux_configuration[each.key]
  id       = "${local.cluster_ids[local.cell_tenants[each.key].cell]}/providers/Microsoft.KubernetesConfiguration/fluxConfigurations/${local.cell_tenants[each.key].namespace}-access?api-version=${local.kubernetes_configuration_api_version}"
}

import {
  for_each = toset(local.migrated_tenants)
  to       = azurerm_federated_identity_credential.key_vault[each.key]
  id       = "${data.azurerm_user_assigned_identity.key_vault[local.cell_tenants[each.key].namespace].id}/federatedIdentityCredentials/aks-${local.cell_tenants[each.key].cell}"
}

import {
  for_each = local.migrated_namespace_user_grants
  to       = azurerm_role_assignment.namespace_user[each.key]
  id       = "${local.cluster_ids[local.cell_tenants[local.namespace_user_grants[each.key].key].cell]}/managedNamespaces/${local.cell_tenants[local.namespace_user_grants[each.key].key].namespace}/providers/Microsoft.Authorization/roleAssignments/${each.value}"
}
