# The environment's platform Key Vault, created by shared/ with the namespaces' identities and every
# grant on it, and only looked up here: the cluster adds a federated credential of its own to each
# identity and nothing else, so it can be destroyed and built again - or replaced by the next cluster
# - while the secrets and the identities stay. What keeps the namespaces apart is not the vault but
# the names of the secrets in it: a namespace owns the secrets whose names start with `<namespace>--`,
# and every grant on the vault carries an Azure ABAC condition holding it to that prefix (shared/,
# modules/conventions). See the README, "Key Vault".
data "azurerm_key_vault" "this" {
  count = local.key_vault_enabled ? 1 : 0

  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

# The identity each namespace reads its own secrets as - the environment's shared one,
# `id-<region>-<environment>-shared-kv-<namespace>` (modules/conventions), so a namespace is the same
# principal, with the same client ID and the same grants, in every cluster of the environment. A
# namespace with a share here has to have one in shared/ too, or its identity is not there to find.
#
# External Secrets Operator has no Azure identity of its own: a SecretStore in the namespace names the
# `key-vault` service account, and the operator requests a token for it on every read - so a
# namespace's store can read that namespace's secrets and no others.
data "azurerm_user_assigned_identity" "key_vault" {
  for_each = local.key_vault_namespaces

  name                = module.conventions.shared_key_vault_identity_names[each.key]
  resource_group_name = var.resource_group_name
}

# The cluster's credential on each identity, named after the cluster. An identity carries one per
# cluster of the environment - Azure allows 20 - and each is destroyed with its cluster, leaving the
# identity to the rest.
resource "azurerm_federated_identity_credential" "key_vault" {
  for_each = local.key_vault_namespaces

  name                      = "aks-${var.name}"
  user_assigned_identity_id = data.azurerm_user_assigned_identity.key_vault[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:${each.key}:${local.key_vault_service_account}"

  lifecycle {
    # A namespace's prefix must not be the start of another namespace's: `team--a` would own every
    # secret of `team`, since `team--a--x` starts with `team--`. Kubernetes allows a double hyphen in a
    # namespace name, so it is refused here.
    precondition {
      condition     = !strcontains(each.key, "--")
      error_message = "${each.key} cannot be given a share of Key Vault ${coalesce(var.key_vault_name, "-")}: a namespace owns the secrets named `<namespace>--...`, and a name with `--` in it would overlap with another namespace's. Rename the namespace, or leave it out of key_vault_namespaces."
    }
  }
}
