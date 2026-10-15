output "key_vault_id" {
  description = "Resource ID of the shared Key Vault."
  value       = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  description = "URI of the shared Key Vault. A namespace's secrets are the ones named `<namespace>--<name>`."
  value       = azurerm_key_vault.this.vault_uri
}

output "key_vault_identities" {
  description = "Per namespace, the shared identity it reads the vault as, in every cluster of the environment."
  value = {
    for namespace, identity in azurerm_user_assigned_identity.key_vault : namespace => {
      name         = identity.name
      client_id    = identity.client_id
      principal_id = identity.principal_id
      vault_uri    = local.namespace_key_vault_uris[namespace]
    }
  }
}

output "dns_zone_name_servers" {
  description = "Name servers of the public zone, for the domain's NS records at its registrar. Null without a zone or with a private one."
  value       = try(local.dns_zone.name_servers, null)
}

output "container_registry_login_server" {
  description = "Login server of the environment's container registry, `<name>.azurecr.io`. Null without one."
  value       = one(azurerm_container_registry.this[*].login_server)
}

output "global_hostnames" {
  description = "Per global hostname, the Traffic Manager name it is a CNAME to."
  value       = { for name, profile in azurerm_traffic_manager_profile.global : "${name}.${var.dns_zone_name}" => profile.fqdn }
}

output "zone_key_vault_uris" {
  description = "Per isolation zone, the URI of its Key Vault."
  value       = { for zone, vault in azurerm_key_vault.zone : zone => vault.vault_uri }
}

output "cell_subnet_ids" {
  description = "Per cell, its subnets' resource IDs by name."
  value = {
    for cell in keys(local.cells) : cell => {
      for key, subnet in local.cell_subnets : subnet.name => azurerm_subnet.cell[key].id if subnet.cell == cell
    }
  }
}

output "image_signing_certificate_name" {
  description = "Name of the image signing certificate in the platform vault. Null without image_signing."
  value       = one(azurerm_key_vault_certificate.image_signing[*].name)
}

output "image_verification_client_id" {
  description = "Client ID of the identity the clusters' image signature verifier (Ratify) reads the registry and the signing certificate as. Null without image_signing."
  value       = one(azurerm_user_assigned_identity.image_verification[*].client_id)
}

output "log_analytics_workspace_id" {
  description = "ID of the environment's Log Analytics workspace, or null without one."
  value       = one(azurerm_log_analytics_workspace.platform[*].id)
}

output "exposure" {
  description = "The exposure these shared resources serve (`int` or `ext`, OneK8s design decision D52), or null when none is stated."
  value       = var.exposure
}

output "ai_foundry" {
  description = "The agents' Foundry resource name and model deployment, for aks-ai-agents' model.foundryResource and model.name."
  value       = var.ai_foundry == null ? null : { resource = azurerm_cognitive_account.agents[0].name, model = try(azapi_resource.agents_model[0].name, null) }
}
