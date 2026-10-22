# KMS data encryption (preview, Kubernetes 1.33+) with the cluster's own key - customer_managed_keys
# .kms_data_encryption, OneK8s design section 4.2. The Kubernetes secrets (and other resource objects) in etcd
# are encrypted with key-<cluster>-kms like classic KMS does, but AKS reaches a vault without public network
# access through its trusted services exception (the vault's bypass AzureServices) - classic KMS reaches a
# private vault only with API Server VNet Integration, which Azure refuses on an encrypted network with v4+ VM
# sizes (D58). So the platform vault takes no public network access at all (shared/ private_endpoints).
#
# The AVM module has no input for it: set beside the module like Image Integrity (image_integrity.tf), a read,
# merge and PUT of the cluster on the preview API after everything the module does - the module then states no
# KMS of its own (local.azure_key_vault_kms is null). The key is named without a version: AKS follows the
# key's yearly rotation by itself. Once on, it cannot be turned off again (AKS's own rule).
resource "azapi_update_resource" "kms_data_encryption" {
  count = local.kms_data_encryption ? 1 : 0

  resource_id = module.aks.resource_id
  type        = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  body = {
    properties = {
      securityProfile = {
        # KMS data encryption names the vault in either mode (AKS: "Key Vault resource ID must be specified
        # when customer-managed key (CMK) properties change")
        azureKeyVaultKms = {
          enabled               = true
          keyId                 = azurerm_key_vault_key.cluster["kms"].versionless_id
          keyVaultNetworkAccess = var.customer_managed_keys.key_vault_network_access
          keyVaultResourceId    = data.azurerm_key_vault.customer_managed_keys[0].id
        }
        kubernetesResourceObjectEncryptionProfile = {
          infrastructureEncryption = "Enabled"
        }
      }
    }
  }
  locks = [module.aks.resource_id]

  depends_on = [module.aks, azapi_update_resource.image_integrity, azurerm_role_assignment.cluster_customer_managed_keys]
}
