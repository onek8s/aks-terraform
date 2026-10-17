# Encryption at rest with customer-managed keys - OneK8s design section 4.2 - for a cluster that names
# a vault in customer_managed_keys: the environment's platform vault, with purge protection. Two keys
# of the cluster's own, created before the cluster, since neither can be added to a running one:
#
#   key-<cluster>-kms   KMS: the control plane encrypts the Kubernetes secrets in etcd with it, as the
#                       cluster identity (Key Vault Crypto User on the key).
#   key-<cluster>-disk  The disk encryption set of every node's OS disk - the system pool's and the
#                       NAP nodes' - as the set's own identity (Key Vault Crypto Service Encryption
#                       User on the key). AKS takes one set per cluster, not one per node pool.
#
# The keys never expire; the rotation policy makes a new version every year, which the disk
# encryption set follows by itself and KMS on the next apply.
data "azurerm_key_vault" "customer_managed_keys" {
  count = var.customer_managed_keys == null ? 0 : 1

  name                = var.customer_managed_keys.key_vault_name
  resource_group_name = coalesce(var.customer_managed_keys.key_vault_resource_group_name, var.resource_group_name)
}

resource "azurerm_key_vault_key" "cluster" {
  for_each = var.customer_managed_keys == null ? toset([]) : toset(["kms", "disk"])

  name         = "key-${var.name}-${each.key}"
  key_vault_id = data.azurerm_key_vault.customer_managed_keys[0].id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]

  rotation_policy {
    automatic {
      time_after_creation = "P1Y"
    }
  }

  lifecycle {
    precondition {
      condition     = !local.system_assigned_identity
      error_message = "${var.name} runs on a system assigned identity, which does not exist before the cluster and so cannot be granted its KMS key. Attach the cluster to an existing virtual network."
    }
  }
}

resource "azurerm_disk_encryption_set" "this" {
  count = var.customer_managed_keys == null ? 0 : 1

  name                      = "des-${var.name}"
  location                  = var.location
  resource_group_name       = var.resource_group_name
  key_vault_key_id          = azurerm_key_vault_key.cluster["disk"].versionless_id
  auto_key_rotation_enabled = true
  encryption_type           = "EncryptionAtRestWithCustomerKey"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "disk_encryption_set_key" {
  count = var.customer_managed_keys != null && var.create_role_assignments ? 1 : 0

  principal_id         = azurerm_disk_encryption_set.this[0].identity[0].principal_id
  scope                = azurerm_key_vault_key.cluster["disk"].resource_versionless_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_type       = "ServicePrincipal"
}

# The cluster identity: the KMS key, and reading the disk encryption set it creates the nodes' disks
# with; with KMS data encryption also Key Vault Contributor on the vault, which AKS asks for.
resource "azurerm_role_assignment" "cluster_customer_managed_keys" {
  for_each = var.customer_managed_keys != null && var.create_role_assignments ? merge({
    kms_key             = { scope = azurerm_key_vault_key.cluster["kms"].resource_versionless_id, role = "Key Vault Crypto User" }
    disk_encryption_set = { scope = azurerm_disk_encryption_set.this[0].id, role = "Reader" }
    }, !var.customer_managed_keys.kms_data_encryption ? {} : {
    # KMS data encryption reads the vault's network settings (AKS's documented prerequisite)
    kms_vault = { scope = data.azurerm_key_vault.customer_managed_keys[0].id, role = "Key Vault Contributor" }
  }) : {}

  principal_id         = azurerm_user_assigned_identity.this[0].principal_id
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_type       = "ServicePrincipal"
}

# Azure checks the keys when the cluster is created, and role assignments take a while to take effect.
resource "time_sleep" "customer_managed_keys_propagation" {
  count = var.customer_managed_keys != null && var.create_role_assignments && var.role_assignment_propagation_delay != "0s" ? 1 : 0

  create_duration = var.role_assignment_propagation_delay
  triggers = {
    disk_encryption_set_key = one(azurerm_role_assignment.disk_encryption_set_key[*].id)
    cluster                 = join(",", [for assignment in azurerm_role_assignment.cluster_customer_managed_keys : assignment.id])
  }
}

locals {
  disk_encryption_set_id = one(azurerm_disk_encryption_set.this[*].id)
  # Classic KMS through the AVM module; KMS data encryption is set beside it (kms.tf)
  kms_data_encryption = var.customer_managed_keys == null ? false : var.customer_managed_keys.kms_data_encryption
  azure_key_vault_kms = var.customer_managed_keys == null || local.kms_data_encryption ? null : {
    enabled                  = true
    key_id                   = azurerm_key_vault_key.cluster["kms"].id
    key_vault_network_access = var.customer_managed_keys.key_vault_network_access
    # Only a private vault is named: AKS reaches it through a private endpoint of its own.
    key_vault_resource_id = var.customer_managed_keys.key_vault_network_access == "Private" ? data.azurerm_key_vault.customer_managed_keys[0].id : null
  }
}
