variable "location" {
  type        = string
  description = "Azure region, for its short code."
  nullable    = false
}

variable "key_vault_namespaces" {
  type        = set(string)
  default     = []
  description = "The namespaces with a share of the Key Vault: each owns the secrets named `<namespace>--<name>`."
  nullable    = false
}

variable "environment" {
  type        = string
  default     = null
  description = "The environment, such as `dev`, for the names of its shared resources. Null for none."
}

variable "exposure" {
  type        = string
  default     = null
  description = "The exposure, `int` or `ext` (OneK8s design D52), for the names that carry it. Null for none: the `{exposure}` placeholder is then empty."
}

variable "naming" {
  type = object({
    templates      = optional(map(string), {})
    location_codes = optional(map(string), {})
  })
  default     = {}
  description = <<DESCRIPTION
The estate's naming policy: per resource type a template, and the regions' short codes. Both merge
over the defaults (local.default_templates, local.location_codes), which are the lab's names - so a
policy states only where it departs from them. A template is a resource name with placeholders:

  `{environment}`   the environment (`dev`)
  `{exposure}`      the exposure (`int`, `ext`), empty without one
  `{location}`      the Azure region (`germanywestcentral`)
  `{location_code}` the region's short code (`gwc`, from location_codes)
  `{name}`          what tells this resource from the others of its type (`platform`, a zone, a cell)
  `{domain}`        the DNS zone, dots as hyphens (Traffic Manager profiles only)

An empty placeholder leaves no stray hyphen: runs of hyphens become one and none is left at either end.
A type whose names allow no hyphens (`container_registry`) loses every character but letters and
digits. Every name is checked against its type's Azure rules at plan time.

A real estate's policy is not kept in this repository: some of these names are global - Key Vault,
container registry, AI Services subdomain, Traffic Manager - and a published convention lets anyone
take the next one first. Pass it as a variables file outside Git (`naming.auto.tfvars.json`, ignored
here) or, in the Deploy workflow, as the `dev` environment's secret NAMING_POLICY - see the README,
"Naming policy".
DESCRIPTION
  nullable    = false
}

variable "names" {
  type = map(object({
    type   = string
    name   = optional(string, "")
    domain = optional(string, "")
  }))
  default     = {}
  description = "The names the caller needs, by a key of its own: each a resource `type` of the policy, with its `{name}` (and `{domain}`). The `names` output answers with the same keys."
  nullable    = false
}
