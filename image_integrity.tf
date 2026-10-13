# AKS Image Integrity (preview), with image_integrity_enabled: Ratify checks each image's Notation
# signature for the Azure Policy add-on (OneK8s design section 14). It reads the signatures in the
# environment's registry and the signing certificate in the platform vault as the environment's shared
# identity (shared/: image_signing), through this cluster's federated credential for Ratify's service
# account. Flux applies Ratify's configuration - which certificate, which registry, as which identity -
# from the values in local.flux_cluster_settings (aks-fluxcd-platform, infrastructure/image-verification).
data "azurerm_user_assigned_identity" "image_verification" {
  count = var.image_integrity_enabled ? 1 : 0

  name                = module.conventions.image_verification_identity_name
  resource_group_name = var.resource_group_name
}

# The signing certificate, for the subject Ratify trusts: only signatures made with this certificate
# count, whatever else the trust store may hold.
data "azurerm_key_vault_certificate" "image_signing" {
  count = var.image_integrity_enabled ? 1 : 0

  name         = module.conventions.image_signing_certificate_name
  key_vault_id = local.key_vault_id
}

# Named after the cluster, like the vault identities' credentials: one per cluster of the environment,
# destroyed with its cluster.
resource "azurerm_federated_identity_credential" "image_verification" {
  count = var.image_integrity_enabled ? 1 : 0

  name                      = "aks-${var.name}"
  user_assigned_identity_id = data.azurerm_user_assigned_identity.image_verification[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:${replace(var.image_integrity_service_account, "/", ":")}"
}
