output "fqdn" {
  description = "Public FQDN of the API server, resolving to its private address. Null without `private_cluster_public_fqdn_enabled`."
  value       = module.aks.fqdn
}

output "identity_principal_id" {
  description = "Principal ID of the identity the cluster runs as. Grant it access to resources the cluster has to reach."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "identity_resource_id" {
  description = "Resource ID of the identity the cluster runs as."
  value       = azurerm_user_assigned_identity.this.id
}

output "key_vault_id" {
  description = "Resource ID of the environment's platform Key Vault. Null when `key_vault_name` is unset."
  value       = local.key_vault_id
}

output "key_vault_uri" {
  description = "URI of the environment's platform Key Vault, for `az keyvault secret set --id` and the like. Null when `key_vault_name` is unset. A namespace's secrets are the ones named `<namespace>--<name>`."
  value       = local.key_vault_uri
}

output "kubelet_identity_object_id" {
  description = "Object ID of the identity the nodes run as, granted `AcrPull` on the environment's registry."
  value       = try(module.aks.kubelet_identity.objectId, null)
}

output "managed_namespace_ids" {
  description = "Resource IDs of the managed namespaces, keyed by namespace name. An Azure role assignment scoped to one of these grants access to that namespace alone."
  value       = { for name, namespace in azapi_resource.managed_namespace : name => namespace.id }
}

output "name" {
  description = "Name of the AKS cluster."
  value       = module.aks.name
}

output "persistent_storage_enabled" {
  description = "Whether the cluster has persistent storage; Deploy deletes AKS's own StorageClasses from a stateless one."
  value       = var.persistent_storage_enabled
}

output "node_resource_group_id" {
  description = "Resource ID of the resource group holding the cluster infrastructure."
  value       = module.aks.node_resource_group_id
}

output "node_resource_group_name" {
  description = "Name of the resource group holding the cluster infrastructure."
  value       = module.aks.node_resource_group_name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, used for workload identity federation."
  value       = module.aks.oidc_issuer_profile_issuer_url
}

output "private_fqdn" {
  description = "Private FQDN of the API server."
  value       = module.aks.private_fqdn
}

output "resource_id" {
  description = "Resource ID of the AKS cluster."
  value       = module.aks.resource_id
}

output "names" {
  description = "The names this cluster took from the naming policy (var.naming): its identity and its disk encryption set."
  value       = module.conventions.names

  # The policy and its names are checked here, where a test can expect the failure.
  precondition {
    condition     = length(module.conventions.policy_errors) == 0
    error_message = "The naming policy (var.naming) is not one this configuration can use: ${join("; ", module.conventions.policy_errors)}. Its resource types and placeholders are listed in modules/conventions/variables.tf."
  }
  precondition {
    condition     = length(module.conventions.names_without_location_code) == 0
    error_message = "No short code is known for ${var.location}, and the naming policy needs one for: ${join(", ", module.conventions.names_without_location_code)}. Add it to naming.location_codes, or to local.location_codes in modules/conventions/main.tf."
  }
  precondition {
    condition     = length(module.conventions.invalid_names) == 0
    error_message = "The naming policy makes names Azure refuses: ${join(", ", module.conventions.invalid_names)}. Change the type's template in naming.templates."
  }
}
