# The estate's conventions, shared by the cluster configuration at the repository root and the
# environment's shared resources in shared/: what they compute has to come out the same in both, or
# a cluster would look for a shared identity under a name nobody created, or hold a namespace to a
# share of the vault the shared configuration drew differently. No resources; only values.

locals {
  # Short code for the region, for the identity names. Azure has no standard for these, so this
  # is the estate's own convention rather than something derivable - a region that is not listed here
  # gets added here. The identity is refused rather than named with a guess.
  # Country codes ALPHA-2 & ALPHA-3: https://www.iban.com/country-codes 
  location_code = lookup(local.location_codes, var.location, "")
  location_codes = {
    finlandcentral = "fic"
    francecentral  = "frc"
    swedencentral  = "sec"
    westeurope     = "euw"
    uksouth        = "uks"
    ukwest         = "ukw"
  }

  # The identities a namespace reads the environment's shared Key Vault as - shared by every cluster
  # of the environment, created by shared/ and looked up by each cluster:
  # `id-<region code>-<environment>-shared-kv-<namespace>`. `shared` where a cluster's identity has
  # the cluster's own name, so the two never mix in a listing of the resource group.
  shared_key_vault_identity_names = var.environment == null ? {} : {
    for namespace in var.key_vault_namespaces : namespace => "id-${local.location_code}-${var.environment}-shared-kv-${namespace}"
  }

  # The identity the image signature verifier (Ratify, of AKS Image Integrity) reads the registry and
  # the signing certificate as, shared by every cluster of the environment like the ones above.
  image_verification_identity_name = var.environment == null ? null : "id-${local.location_code}-${var.environment}-shared-ratify"

  # The share of each: the secrets whose names start with this. Key Vault names are case-insensitive
  # and compared in lowercase, which a namespace name already is.
  key_vault_secret_prefixes = { for namespace in var.key_vault_namespaces : namespace => "${namespace}--" }

  # Azure ABAC conditions (version 2.0) holding a role assignment on the vault to one namespace's
  # secrets. A condition applies to the actions it names and leaves the rest of the role alone, so
  # each says: for these actions, only a secret under the prefix. An existing secret is matched by its
  # name as a resource; one being created or restored, which does not exist yet, by the name in the
  # request.
  #
  # Reading a secret - `Key Vault Secrets User`: its value and its metadata (attributes, versions).
  # Listing the vault is refused: Key Vault evaluates a condition on a list call against the whole
  # collection, which has no name, so a name condition on `readMetadata` refuses every list - and that
  # is the point (soft multi-tenancy, OneK8s design section 6): no namespace learns the names of
  # another namespace's secrets. Its own it reads by name, which is all External Secrets Operator
  # does. Listing the names is the platform viewers' (shared/, platform_viewer_group_object_ids).
  key_vault_read_conditions = {
    for namespace, prefix in local.key_vault_secret_prefixes : namespace => <<-CONDITION
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
       )
       OR
       (
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
    CONDITION
  }

  # What a namespace's `edit` group may do to the namespace's secrets (OneK8s design section 7, D51):
  # write and update them, and read their attributes, never their value - Kubernetes' `edit` writes a
  # Secret, and a person who may write a secret need not read the one already there. No delete,
  # purge, backup or restore: those stay with `admin` (`Key Vault Secrets Officer`). A custom role -
  # Azure has no built-in one without `getSecret` - held to the namespace's secrets by the write
  # condition below, like the Secrets Officer; its `readMetadata` is by name, so it lists nothing.
  key_vault_secrets_editor_data_actions = [
    "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
    "Microsoft.KeyVault/vaults/secrets/setSecret/action",
    "Microsoft.KeyVault/vaults/secrets/update/action",
  ]

  # Everything `Key Vault Secrets Officer` can do to a secret, on the namespace's secrets only: an
  # existing one by its name, a new or restored one by the name in the request - so no secret named
  # anything but `<namespace>--...` can be created. Listing is refused, as for reading.
  key_vault_write_conditions = {
    for namespace, prefix in local.key_vault_secret_prefixes : namespace => <<-CONDITION
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/update/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/delete'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/backup/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/recover/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/purge/action'})
       )
       OR
       (
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
      AND
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/setSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/restore/action'})
       )
       OR
       (
        @Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
    CONDITION
  }
}
