variable "environment" {
  type        = string
  description = <<DESCRIPTION
The environment these resources are shared by, such as `dev`: the clusters named
`aks-<environment>-<which one>`. Part of the shared identities' names, which the clusters work out
from their own names - see modules/conventions.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.environment))
    error_message = "environment must be lowercase letters and digits: it is one segment of a cluster name."
  }
}

variable "location" {
  type        = string
  description = "Azure region of the shared resources - the clusters' region."
  nullable    = false
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the shared resources are created in - the clusters' resource group. It exists already, unless resource_group_create."
  nullable    = false
}

variable "resource_group_create" {
  type        = bool
  default     = false
  description = "Whether to create resource_group_name here - for an environment that starts from an empty subscription."
  nullable    = false
}

variable "virtual_network_create" {
  type        = bool
  default     = false
  description = "Whether to create the clusters' network, virtual_network_name, here in resource_group_name - with virtual_network_address_space and the subnets of `subnets`. Otherwise it exists already."
  nullable    = false
}

variable "virtual_network_address_space" {
  type        = list(string)
  default     = []
  description = "Address space of the network virtual_network_create creates."
  nullable    = false
}

variable "subnets" {
  type        = map(string)
  default     = {}
  description = "The subnets of the network virtual_network_create creates: name => address prefix. The clusters name theirs in node_subnet_name."
  nullable    = false
}

variable "key_vault_name" {
  type        = string
  description = <<DESCRIPTION
Name of the environment's shared Key Vault, which the clusters name in their `key_vault_name` with
`key_vault_create = false`. Key Vault names are global: 3 to 24 letters, digits and single hyphens,
starting with a letter.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", var.key_vault_name)) && length(var.key_vault_name) >= 3 && length(var.key_vault_name) <= 24
    error_message = "key_vault_name must be 3 to 24 letters, digits and single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "key_vault_namespaces" {
  type = map(object({
    writers = optional(list(object({
      principal_id   = string
      principal_type = optional(string, "Group")
    })), [])
  }))
  description = <<DESCRIPTION
The namespaces with a share of the vault, in any cluster of the environment: each owns the secrets
named `<namespace>--<name>`, and reads them as the identity `id-<region>-<environment>-shared-kv-
<namespace>`, granted `Key Vault Secrets User` under an ABAC condition that holds it to them. A
cluster federates the identity with its namespace's `key-vault` service account - so a namespace
with a share in a cluster has to be listed here.

`writers` manage the namespace's secrets and no others: `Key Vault Secrets Officer` under the same
condition. Object IDs, not names.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for namespace in keys(var.key_vault_namespaces) : !strcontains(namespace, "--")])
    error_message = "A namespace owns the secrets named `<namespace>--...`, so a namespace name with `--` in it would overlap with another namespace's."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.key_vault_namespaces) : [for writer in namespace.writers : contains(["Group", "ServicePrincipal", "User"], writer.principal_type)]
    ]))
    error_message = "A writer's principal_type must be Group, ServicePrincipal or User."
  }
}

variable "key_vault_admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Entra ID groups that run the whole vault as `Key Vault Administrator`, certificates included."
  nullable    = false
}

variable "flux_github_webhook" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether to generate the token GitHub signs Flux webhook deliveries with, as
`flux-system--github-webhook-token`. Every cluster's Receiver reads the same token, so each answers
on the same path. `flux-system` needs a share in `key_vault_namespaces` to read it.
DESCRIPTION
  nullable    = false
}

variable "flux_github_webhook_namespaces" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Team namespaces whose own Flux Receiver reconciles the team's repository on a GitHub push: the same
token is put in each one's share of the vault as `<namespace>--github-webhook-token`. Each needs a
share in `key_vault_namespaces`; `flux_github_webhook` has to be on.
DESCRIPTION
  nullable    = false
}

variable "dns_zone_name" {
  type        = string
  default     = null
  description = "The DNS zone every cluster of the environment publishes its hostnames in - public, or private with dns_zone_private. Null for none."
}

variable "dns_zone_private" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether dns_zone_name is an Azure Private DNS zone, whose names resolve only in the clusters' network
it is linked to, rather than a public Azure DNS zone. The one switch between the two: the clusters
say the same in their own `dns_zone_private`. global_hostnames and the Let's Encrypt DNS-01 challenge
need a public zone.
DESCRIPTION
  nullable    = false
}

variable "dns_zone_create" {
  type        = bool
  default     = true
  description = "Whether to create dns_zone_name here - a private zone together with its link to virtual_network_name. False looks up a zone that exists already: one created outside Terraform, so that its name servers outlive every state."
  nullable    = false
}

variable "dns_zone_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the zone. Defaults to `resource_group_name`."
}

variable "virtual_network_name" {
  type        = string
  default     = null
  description = "Name of the clusters' network, created here with virtual_network_create."
}

variable "create_role_assignments" {
  type        = bool
  default     = true
  description = "Whether to grant the identities and the people their access to the vault here, or leave it to whoever manages the estate's role assignments."
  nullable    = false
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Subscription to deploy into. Defaults to the one the Azure CLI or the ARM_SUBSCRIPTION_ID environment variable points at."
}

variable "container_registry_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the environment's Azure Container Registry, created here: the images the clusters run, which
each cluster pulls as its kubelet identity - nothing is stored to read it with. The images get there
through container_registry_builds. Registry names are
global, 5 to 50 letters and digits. Null for none.
DESCRIPTION

  validation {
    condition     = var.container_registry_name == null || can(regex("^[a-zA-Z0-9]{5,50}$", coalesce(var.container_registry_name, "-")))
    error_message = "container_registry_name must be 5 to 50 letters and digits."
  }
}

variable "container_registry_builds" {
  type = map(object({
    repository   = string
    commit       = string
    dockerfile   = optional(string, "Dockerfile")
    folder       = optional(string)
    architecture = optional(string, "amd64")
  }))
  default     = {}
  description = <<DESCRIPTION
Images the registry builds itself, keyed by `<repository>:<tag>` in the registry: the Git `repository`
it reads anonymously - a public one - at `commit`, with `dockerfile` in `folder` (the root by
default), for the `architecture` of the nodes that run it - `amd64` by default, or `arm64`. A build
runs when its entry is added or changed, so releasing is adding a tag.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for build in values(var.container_registry_builds) : can(regex("^[0-9a-f]{40}$", build.commit))])
    error_message = "A build's commit must be a full 40-character commit ID, so a tag always means the same source."
  }

  validation {
    condition     = alltrue([for build in values(var.container_registry_builds) : contains(["amd64", "arm64"], build.architecture)])
    error_message = "A build's architecture must be amd64 or arm64."
  }
}

variable "global_hostnames" {
  type = map(object({
    endpoints   = list(string)
    health_path = optional(string, "/")
    ttl         = optional(number, 10)
  }))
  default     = {}
  description = <<DESCRIPTION
Hostnames in dns_zone_name that every listed cluster serves at once, keyed by the name below the zone
(`hello` for hello.onek8s.lol): an Azure Traffic Manager profile each, weighting the `endpoints` -
each cluster's own public hostname, such as `public-aks-dev-stateless-az1.onek8s.lol` - alike and
leaving out one whose probe of `health_path` fails, and a CNAME of the hostname to it. The clusters'
external-dns have to leave the hostname alone.
DESCRIPTION
  nullable    = false
}
