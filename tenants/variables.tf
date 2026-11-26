variable "subscription_id" {
  type        = string
  default     = null
  description = "The environment's subscription, where its cells, vaults and identities are. Null: the one the Azure CLI or the ARM_SUBSCRIPTION_ID variable names."
}

variable "location" {
  type        = string
  description = "The environment's Azure region: its managed namespaces' location and the region code of the identities' names."
  nullable    = false
}

variable "resource_group_name" {
  type        = string
  description = "The environment's resource group: its cells, the zones' Key Vaults and the namespaces' identities (shared/)."
  nullable    = false
}

variable "environment" {
  type        = string
  description = "The environment, such as `dev`, for the names of its shared identities (modules/conventions)."
  nullable    = false
}

variable "naming" {
  type = object({
    templates      = optional(map(string), {})
    location_codes = optional(map(string), {})
  })
  default     = {}
  description = "The estate's naming policy, as in the cells and shared/ (modules/conventions): Deploy writes it from the `dev` environment's secret NAMING_POLICY."
  nullable    = false
}

variable "catalogue_dir" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The environment's tenant catalogue, relative to this directory: one `<namespace>.yaml` per application
namespace (`<zone>-<app>`), in the shape of `tenants` - see the README, "Tenants". shared/ reads the same
files for the namespaces' identities and vault grants. Null: `tenants` alone.
DESCRIPTION
}

variable "tenants" {
  type        = any
  default     = {}
  description = <<DESCRIPTION
Tenants on top of the catalogue's, keyed by namespace, in the same shape as a catalogue file
(tenants/schema): `zone`, and optionally `cells`, `owner`, `groups`, `labels`, `annotations`,
`network_policy`, `pod_security`, `resource_quota`, `adoption_policy`, `delete_policy`,
`dedicated_node_pool`, `flux`. For tests; an environment keeps its tenants in the catalogue.
DESCRIPTION
  nullable    = false
}

variable "cells" {
  type = map(object({
    zones = list(string)
  }))
  description = <<DESCRIPTION
The environment's cells, keyed by cluster name, with the isolation zones each holds. A tenant goes to
every cell that holds its zone (design section 3.3: every cell of a zone runs the same tenants), unless it
names its `cells`. Every cell must exist and run the platform's Flux configuration (`platform`): its
tenants' platform configurations read the same repository and branch.
DESCRIPTION
  nullable    = false
}

variable "zone_key_vault_names" {
  type        = map(string)
  default     = {}
  description = "A zone's vault where it is not the naming policy's `key_vault` named after the zone - as shared/'s zone_key_vault_names."
  nullable    = false
}

variable "namespace_defaults" {
  type = object({
    adoption_policy = optional(string, "Never")
    annotations     = optional(map(string), {})
    delete_policy   = optional(string, "Keep")
    labels          = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string, "AllowSameNamespace")
      ingress = optional(string, "AllowSameNamespace")
    }), {})
    pod_security = optional(object({
      audit   = optional(string, "restricted")
      enforce = optional(string, "restricted")
      version = optional(string, "latest")
      warn    = optional(string, "restricted")
    }), {})
    resource_quota = optional(object({
      cpu_limit      = optional(string, "2000m")
      cpu_request    = optional(string, "500m")
      memory_limit   = optional(string, "4Gi")
      memory_request = optional(string, "1Gi")
    }), {})
  })
  default     = {}
  description = <<DESCRIPTION
What every tenant gets unless it says otherwise: the default `NetworkPolicy` (`ingress` and `egress`
`AllowSameNamespace`: no traffic between namespaces; each `AllowAll`, `AllowSameNamespace` or `DenyAll` -
Kubernetes network policies are additive, so a policy in the namespace can only widen these), the Pod
Security Standard (`enforce`, `audit` and `warn`: `restricted`, `baseline`, `privileged` or `none`;
`version` `latest` or `v1.NN`), the `ResourceQuota` Azure requires on every managed namespace (CPU in
Kubernetes units, sent as milliCPU; memory as `Mi`/`Gi`), `adoption_policy` (`Never`, `IfIdentical`,
`Always`), `delete_policy` (`Keep`, `Delete`), and `labels` and `annotations` for all.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Always", "IfIdentical", "Never"], var.namespace_defaults.adoption_policy)
    error_message = "namespace_defaults.adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\"."
  }
  validation {
    condition     = contains(["Delete", "Keep"], var.namespace_defaults.delete_policy)
    error_message = "namespace_defaults.delete_policy must be either \"Delete\" or \"Keep\"."
  }
  validation {
    condition = alltrue([
      for rule in [var.namespace_defaults.network_policy.egress, var.namespace_defaults.network_policy.ingress] :
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], rule)
    ])
    error_message = "namespace_defaults.network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\"."
  }
  validation {
    condition = alltrue([
      for level in [var.namespace_defaults.pod_security.audit, var.namespace_defaults.pod_security.enforce, var.namespace_defaults.pod_security.warn] :
      contains(["baseline", "none", "privileged", "restricted"], level)
    ])
    error_message = "namespace_defaults.pod_security.audit, .enforce and .warn must each be one of \"restricted\", \"baseline\", \"privileged\" or \"none\"."
  }
  validation {
    condition     = can(regex("^(latest|v[0-9]+\\.[0-9]+)$", var.namespace_defaults.pod_security.version))
    error_message = "namespace_defaults.pod_security.version must be \"latest\" or a pinned Kubernetes minor version such as \"v1.31\"."
  }
  validation {
    condition     = alltrue([for key in keys(var.namespace_defaults.labels) : !startswith(key, "pod-security.kubernetes.io/")])
    error_message = "namespace_defaults.labels must not set a pod-security.kubernetes.io/* label. Use namespace_defaults.pod_security, which is where the Pod Security Standard is decided."
  }
  validation {
    condition = alltrue([
      for quantity in [var.namespace_defaults.resource_quota.cpu_limit, var.namespace_defaults.resource_quota.cpu_request] :
      can(regex("^([0-9]+(\\.[0-9]{1,3})?|[0-9]+m)$", quantity)) && try(tonumber(trimsuffix(quantity, "m")) > 0, false)
    ])
    error_message = "namespace_defaults.resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities of at least 1 milliCPU, for example \"500m\", \"0.5\" or \"2\"."
  }
  validation {
    condition = alltrue([
      for quantity in [var.namespace_defaults.resource_quota.memory_limit, var.namespace_defaults.resource_quota.memory_request] :
      can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", quantity))
    ])
    error_message = "namespace_defaults.resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
  }
}

variable "namespace_access_path" {
  type        = string
  default     = "./infrastructure/namespace-access"
  description = <<DESCRIPTION
The directory of the platform's Flux repository with one subdirectory per role - `view`, `edit`,
`admin` - holding the `RoleBinding` a tenant's group of that role is made from (`$${namespace}`,
`$${role}`, `$${group_object_id}`). Azure refuses two Kustomizations of one Flux configuration on the
same path, hence a directory per role.
DESCRIPTION
  nullable    = false

  validation {
    condition     = startswith(var.namespace_access_path, "./")
    error_message = "namespace_access_path must be a path in the repository starting with ./."
  }
}

variable "tenant_path" {
  type        = string
  default     = "./infrastructure/tenant"
  description = <<DESCRIPTION
The directory of the platform's Flux repository with what the platform puts into every tenant
namespace: its `default` ServiceAccount without a token, and the `key-vault` ServiceAccount and
SecretStore of its share of the zone's vault (`$${namespace}`, `$${zone}`, `$${key_vault_url}`,
`$${key_vault_client_id}`, `$${azure_tenant_id}`).
DESCRIPTION
  nullable    = false

  validation {
    condition     = startswith(var.tenant_path, "./")
    error_message = "tenant_path must be a path in the repository starting with ./."
  }
}
