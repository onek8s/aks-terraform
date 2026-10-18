# Image signing (OneK8s design section 2.7), with image_signing: the platform signs every image the
# registry builds with a Notation signature, stored next to the image in the registry, and every
# cluster's AKS Image Integrity (Ratify on the Azure Policy add-on's Gatekeeper) checks that signature
# at admission - in audit, the only effect Image Integrity has while it is in preview.
#
#   - The signing certificate, here in the platform vault: self-signed, with a key that never leaves
#     the vault. Notation wants a code signing certificate whose subject names a country, a state and
#     an organisation. The Sign images workflow signs with the key in the vault (Notation's Azure Key
#     Vault plugin, as the deployment identity), so nothing private is anywhere else.
#   - The identity Ratify reads the registry (the signatures) and the certificate as, shared by every
#     cluster of the environment. Each cluster adds a federated credential for Ratify's service
#     account. Ratify reads the certificate through its secret, which for a key that cannot be
#     exported holds the public certificate only - and the grant is on that one secret, not the vault.
#
# A renewed certificate (30 days before it expires) is a new one: the Sign images workflow signs again
# every image whose signature the current certificate does not verify.
resource "azurerm_key_vault_certificate" "image_signing" {
  count = var.image_signing == null ? 0 : 1

  name         = module.conventions.image_signing_certificate_name
  key_vault_id = azurerm_key_vault.this.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = false
      key_size   = 3072
      key_type   = "RSA"
      reuse_key  = false
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pem-file"
    }

    x509_certificate_properties {
      subject            = var.image_signing.subject
      key_usage          = ["digitalSignature"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.3"] # code signing
      validity_in_months = var.image_signing.validity_in_months
    }
  }
}

resource "azurerm_user_assigned_identity" "image_verification" {
  count = var.image_signing == null ? 0 : 1

  location            = var.location
  name                = module.conventions.image_verification_identity_name
  resource_group_name = local.resource_group_name
}

locals {
  image_verification_grants = var.image_signing == null || local.names.container_registry == null || !var.create_role_assignments ? {} : {
    # The images' signatures, which are artifacts in the registry next to the images.
    registry = { scope = azurerm_container_registry.this[0].id, role = "AcrPull" }
    # The signing certificate, through its secret - only that one.
    certificate = { scope = "${azurerm_key_vault.this.id}/secrets/${module.conventions.image_signing_certificate_name}", role = "Key Vault Secrets User" }
  }
}

resource "azurerm_role_assignment" "image_verification" {
  for_each = local.image_verification_grants

  principal_id         = azurerm_user_assigned_identity.image_verification[0].principal_id
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_type       = "ServicePrincipal"

  depends_on = [azurerm_key_vault_certificate.image_signing]
}
