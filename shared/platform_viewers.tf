# The platform viewers (OneK8s design section 2.6, "Soft multi-tenancy"): Entra ID groups that see
# what the namespaces' own groups may not - the names of every namespace in the environment's
# clusters and of every secret in its vaults - and no content of either. The Azure portal's
# Kubernetes views pick a namespace from the cluster's list of them, which a namespace's own groups
# cannot read; a member of a namespace group and of this one browses its own namespace there.
#
# One custom role, defined at the environment's resource group and assignable only there - nothing
# at the subscription or above - so the code also runs where a hardened landing zone keeps the
# subscription's role definitions to its platform team. Custom role names are unique in the tenant,
# hence the resource group in the name.
locals {
  resource_group_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}"
}

resource "azurerm_role_definition" "platform_viewer" {
  count = length(var.platform_viewer_group_object_ids) > 0 ? 1 : 0

  name              = coalesce(var.platform_viewer_role_name, "OneK8s Platform Viewer (${local.resource_group_name})")
  scope             = local.resource_group_id
  assignable_scopes = [local.resource_group_id]
  description       = "Lists the namespaces of the clusters and the secrets of the Key Vaults in ${local.resource_group_name} - names and attributes only, no workload, no secret value."

  permissions {
    actions = [
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      # The clusters in the portal, and a kubeconfig to reach them with (Entra ID; what it may do
      # inside is the data actions below and the Kubernetes RBAC of the caller's other groups).
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
      "Microsoft.KeyVault/vaults/read",
    ]
    data_actions = [
      # Azure RBAC for Kubernetes: get, list and watch namespaces - nothing inside them.
      "Microsoft.ContainerService/managedClusters/namespaces/read",
      # Listing a vault and a secret's attributes, without its value (getSecret).
      "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
    ]
  }

  depends_on = [azurerm_resource_group.this]
}

resource "azurerm_role_assignment" "platform_viewer" {
  for_each = toset(var.platform_viewer_group_object_ids)

  principal_id       = each.value
  scope              = local.resource_group_id
  role_definition_id = azurerm_role_definition.platform_viewer[0].role_definition_resource_id
  principal_type     = "Group"
}
