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
    }
  }
}

output "dns_zone_name_servers" {
  description = "Name servers of the public zone, for the domain's NS records at its registrar. Null without a zone."
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
