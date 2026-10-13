output "location_code" {
  description = "Short code of the region, for resource names. Empty for a region with no code yet - add it to local.location_codes."
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
