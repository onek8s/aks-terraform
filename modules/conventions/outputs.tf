output "location_code" {
  description = "Short code of the region, for resource names. Empty for a region with no code yet - add it to naming.location_codes or local.location_codes."
  value       = local.location_code
}

output "key_vault_read_conditions" {
  description = "Per namespace, the ABAC condition that holds `Key Vault Secrets User` to reading its own secrets."
  value       = local.key_vault_read_conditions
}

output "key_vault_write_conditions" {
  description = "Per namespace, the ABAC condition that holds `Key Vault Secrets Officer` to managing its own secrets."
  value       = local.key_vault_write_conditions
}

output "key_vault_edit_conditions" {
  description = "Per namespace, the ABAC condition that holds the `edit` groups' Secrets Editor role to writing its own secrets."
  value       = local.key_vault_edit_conditions
}

output "key_vault_secrets_editor_data_actions" {
  description = "The data actions of the namespace `edit` groups' custom Key Vault role: write, update and read the attributes of a secret, never its value."
  value       = local.key_vault_secrets_editor_data_actions
}

output "shared_key_vault_identity_names" {
  description = "Per namespace, the name of the identity it reads the environment's shared Key Vault as. Empty without an environment."
  value       = local.shared_key_vault_identity_names
}

output "image_verification_identity_name" {
  description = "Name of the identity the clusters' image signature verifier (Ratify) reads the registry and the signing certificate as. Null without an environment."
  value       = local.image_verification_identity_name
}

output "image_signing_certificate_name" {
  description = "Name of the certificate in the environment's platform Key Vault that the platform signs its images with. No namespace's share (`<namespace>--`) covers it."
  value       = "image-signing"
}

output "names" {
  description = "The names asked for in var.names, by the same keys, made by the naming policy. The caller refuses them where policy_errors, invalid_names or names_without_location_code is not empty - a module's own preconditions cannot be tested for."
  value       = local.names
}

output "policy_errors" {
  description = "What is wrong with the naming policy itself - unknown resource types or placeholders, unusable region codes: empty when nothing is."
  value       = local.policy_errors
}

output "invalid_names" {
  description = "The names the naming policy makes that Azure refuses, as `<name> (<type>)`: empty when every name is valid."
  value       = local.invalid_names
}

output "names_without_location_code" {
  description = "The names (`<type> <name>`) whose template needs the region's short code when the region has none: empty when none does."
  value       = local.names_without_location_code
}

output "templates" {
  description = "The naming policy's template of every resource type: the defaults with the policy's own merged over them."
  value       = local.templates
}
