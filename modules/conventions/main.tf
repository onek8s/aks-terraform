# The estate's conventions, shared by the cluster configuration at the repository root and the
# environment's shared resources in shared/: what they compute has to come out the same in both, or
# a cluster would look for a shared identity under a name nobody created, or hold a namespace to a
# share of the vault the shared configuration drew differently. No resources; only values.

locals {
  # Short code for the region, for the `{location_code}` of the names. Azure has no standard for
  # these, so this is the estate's own convention rather than something derivable - a region that is
  # not listed here gets added here, or in the naming policy's location_codes. A name that needs the
  # code is refused rather than made with a guess.
  # Country codes ALPHA-2 & ALPHA-3: https://www.iban.com/country-codes 
  location_code = lookup(local.location_codes, var.location, "")
  location_codes = merge({
    finlandcentral     = "fic"
    francecentral      = "frc"
    germanywestcentral = "gwc"
    swedencentral      = "sec"
    westeurope         = "euw"
    uksouth            = "uks"
    ukwest             = "ukw"
  }, var.naming.location_codes)

  # The naming policy (var.naming): one template per resource type. The defaults are the lab's names,
  # as they were before there was a policy, so the lab's resources keep theirs - a changed template is
  # a new name, and for most of these types a new name is a new resource.
  default_templates = {
    resource_group          = "rg-aks-{environment}"
    virtual_network         = "vnet-{name}"
    network_security_group  = "nsg-{name}"
    route_table             = "rt-{name}"
    private_endpoint        = "pe-{name}"
    network_interface       = "nic-{name}"
    key_vault               = "kv-onek8s-{location_code}-{name}"
    container_registry      = "acronek8s{environment}"
    log_analytics_workspace = "log-{environment}-{name}"
    user_assigned_identity  = "id-{location_code}-{environment}-{name}"
    disk_encryption_set     = "des-{name}"
    consumption_budget      = "budget-{environment}"
    traffic_manager_profile = "{domain}-{environment}-{name}"
    ai_services             = "ais-onek8s-{environment}-{name}"
  }
  templates = merge(local.default_templates, var.naming.templates)

  # What Azure takes as a name of each type: its pattern, which includes the length. The global ones
  # (Key Vault, registry, AI Services subdomain, Traffic Manager's DNS label) are the strictest.
  name_rules = {
    resource_group          = "^[-\\w.()]{0,89}[-\\w()]$"
    virtual_network         = "^[a-zA-Z0-9][-\\w.]{0,62}\\w$"
    network_security_group  = "^[a-zA-Z0-9]([-\\w.]{0,78}\\w)?$"
    route_table             = "^[a-zA-Z0-9]([-\\w.]{0,78}\\w)?$"
    private_endpoint        = "^[a-zA-Z0-9][-\\w.]{0,62}\\w$"
    network_interface       = "^[a-zA-Z0-9]([-\\w.]{0,78}\\w)?$"
    key_vault               = "^[a-zA-Z](-?[a-zA-Z0-9]){2,23}$"
    container_registry      = "^[a-zA-Z0-9]{5,50}$"
    log_analytics_workspace = "^[a-zA-Z0-9][a-zA-Z0-9-]{2,61}[a-zA-Z0-9]$"
    user_assigned_identity  = "^[a-zA-Z0-9][-\\w]{2,127}$"
    disk_encryption_set     = "^[-\\w]{1,80}$"
    consumption_budget      = "^[-\\w]{1,63}$"
    traffic_manager_profile = "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
    ai_services             = "^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$"
  }
  # Types whose names take letters and digits only: the template's hyphens go.
  alphanumeric_types = ["container_registry"]

  # Every name asked for - the caller's (var.names) and this module's own below - as the type's
  # template with the placeholders filled in, runs of hyphens (an empty placeholder's) made one and
  # trimmed off both ends.
  requests = merge(var.names, var.environment == null ? {} : merge(
    { "conventions/shared-ratify" = { type = "user_assigned_identity", name = "shared-ratify", domain = "" } },
    { for namespace in var.key_vault_namespaces : "conventions/shared-kv/${namespace}" => { type = "user_assigned_identity", name = "shared-kv-${namespace}", domain = "" } },
  ))
  filled = {
    for key, request in local.requests : key => replace(replace(replace(replace(replace(replace(
      lookup(local.templates, request.type, ""),
      "{environment}", coalesce(var.environment, "-")),
      "{exposure}", coalesce(var.exposure, "-")),
      "{location_code}", coalesce(local.location_code, "-")),
      "{location}", var.location),
      "{domain}", replace(coalesce(request.domain, "-"), ".", "-")),
    "{name}", coalesce(request.name, "-"))
  }
  all_names = {
    for key, request in local.requests : key => (
      contains(local.alphanumeric_types, request.type)
      ? replace(local.filled[key], "/[^a-zA-Z0-9]/", "")
      : trim(replace(local.filled[key], "/-{2,}/", "-"), "-")
    )
  }
  names = { for key in keys(var.names) : key => local.all_names[key] }

  # What is wrong with the policy itself: a type it does not know, a placeholder it does not fill, a
  # region code that cannot be part of a name. The caller refuses the plan on any (module preconditions
  # cannot be tested for, a caller's can).
  policy_errors = concat(
    [for type in keys(var.naming.templates) : "unknown resource type ${type}" if !contains(keys(local.default_templates), type)],
    [for key, request in var.names : "unknown resource type ${request.type} (${key})" if !contains(keys(local.default_templates), request.type)],
    flatten([for type, template in var.naming.templates : [
      for placeholder in regexall("\\{[^}]*\\}", replace(template, "/\\{(environment|exposure|location|location_code|name|domain)\\}/", "")) :
      "unknown placeholder ${placeholder} in the template of ${type}"
    ]]),
    [for location, code in var.naming.location_codes : "location code ${code} of ${location}: 1 to 6 lowercase letters and digits" if !can(regex("^[a-z0-9]{1,6}$", code))],
  )

  # The names that break their type's rules, and the ones that need a region code there is none of.
  invalid_names = [
    for key, name in local.all_names : "${name} (${local.requests[key].type})"
    if !can(regex(lookup(local.name_rules, local.requests[key].type, "^$"), name)) && contains(keys(local.name_rules), local.requests[key].type)
  ]
  names_without_location_code = local.location_code != "" ? [] : [
    for key, request in local.requests : trimspace("${request.type} ${request.name}") if strcontains(lookup(local.templates, request.type, ""), "{location_code}")
  ]

  # The identities a namespace reads the environment's shared Key Vault as - shared by every cluster
  # of the environment, created by shared/ and looked up by each cluster: by default
  # `id-<region code>-<environment>-shared-kv-<namespace>`. `shared` where a cluster's identity has
  # the cluster's own name, so the two never mix in a listing of the resource group.
  shared_key_vault_identity_names = var.environment == null ? {} : {
    for namespace in var.key_vault_namespaces : namespace => local.all_names["conventions/shared-kv/${namespace}"]
  }

  # The identity the image signature verifier (Ratify, of AKS Image Integrity) reads the registry and
  # the signing certificate as, shared by every cluster of the environment like the ones above.
  image_verification_identity_name = var.environment == null ? null : local.all_names["conventions/shared-ratify"]

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
  # is the point (soft multi-tenancy, OneK8s design section 2.5): no namespace learns the names of
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

  # What a namespace's `edit` group may do to the namespace's secrets (OneK8s design section 2.6, D51):
  # write and update them, and read their attributes, never their value - Kubernetes' `edit` writes a
  # Secret, and a person who may write a secret need not read the one already there. No delete,
  # purge, backup or restore: those stay with `admin` (`Key Vault Secrets Officer`). A custom role -
  # Azure has no built-in one without `getSecret` - held to the namespace's secrets by the write
  # condition key_vault_edit_conditions; its `readMetadata` is by name, so it lists nothing.
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

  # The same for the `edit` groups' Secrets Editor role: Azure refuses a condition that names an
  # action the role does not have, so this one names only the role's own - an existing secret's
  # attributes and update by its name, a new one by the name in the request. Listing is refused.
  key_vault_edit_conditions = {
    for namespace, prefix in local.key_vault_secret_prefixes : namespace => <<-CONDITION
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/update/action'})
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
       )
       OR
       (
        @Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
    CONDITION
  }
}
