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
    zone = optional(string)
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

`zone` puts the namespace's share in that isolation zone's vault (zone_key_vault_names) - an
application's namespace, or its zone's gateway; without one it is in key_vault_name, the platform
vault - `flux-system`, say.

`writers` manage the namespace's secrets and no others: `Key Vault Secrets Officer` under the same
condition. Object IDs, not names.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for share in values(var.key_vault_namespaces) : share.zone == null || contains(keys(var.zone_key_vault_names), coalesce(share.zone, "-"))])
    error_message = "A namespace's zone must be one of zone_key_vault_names."
  }

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
default), for the `architecture` of the nodes that run it - `amd64` by default, or `arm64`. The
registry always builds on amd64, so an arm64 image needs a `dockerfile` that cross-compiles for it.
A build runs when its entry is added or changed, so releasing is adding a tag.
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

variable "image_signing" {
  type = object({
    subject            = string
    validity_in_months = optional(number, 12)
  })
  default     = null
  description = <<DESCRIPTION
Signing of the registry's images (OneK8s design section 14): a self-signed code signing certificate
in the platform vault, `image-signing`, with this `subject` - Notation wants it to name a country
(`C`), a state (`ST`) and an organisation (`O`) - valid for `validity_in_months`, and the identity the
clusters' image signature verifier (Ratify, AKS Image Integrity) reads the registry and the
certificate as. Needs container_registry_name. Null for none.
DESCRIPTION

  validation {
    condition = var.image_signing == null || alltrue([
      for part in ["C", "ST", "O"] : can(regex("(^|,)\\s*${part}=[^,]+", try(var.image_signing.subject, "")))
    ])
    error_message = "image_signing.subject must name a country (C=), a state (ST=) and an organisation (O=), as Notation requires of a signing certificate."
  }

  validation {
    condition     = var.image_signing == null || var.container_registry_name != null
    error_message = "image_signing signs the images of the environment's registry, and container_registry_name names none."
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

variable "key_vault_purge_protection_enabled" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether key_vault_name has purge protection. Needed once the vault holds the clusters'
customer-managed keys: Azure refuses a disk encryption set over a key from a vault without it. A
vault with it cannot be purged, so its name stays taken for 90 days after it is deleted - Terraform
recovers it instead when it is created again.
DESCRIPTION
  nullable    = false
}

variable "zone_key_vault_names" {
  type        = map(string)
  default     = {}
  description = <<DESCRIPTION
One Key Vault per isolation zone - OneK8s design section 6 - keyed by the zone (`int-fi`): the
secrets of the zone's applications. A namespace's share is in its zone's vault (key_vault_namespaces,
`zone`). Key Vault names are global.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for name in values(var.zone_key_vault_names) : can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", name)) && length(name) >= 3 && length(name) <= 24])
    error_message = "A zone vault's name must be 3 to 24 letters, digits and single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "isolation_zones" {
  type = map(object({
    exposure = string
    index    = number
  }))
  default     = {}
  description = <<DESCRIPTION
The isolation zones - OneK8s design, "Isolation zone" - keyed by name (`int-fi`, `ext-se`):
`exposure` `int` (reached from the corporate network) or `ext` (from the internet), and `index`, the
zone's /24 in each cell's address space (1 to 15; 0 is the system pool's). A zone's index never
changes once it is in use - a new country's zones take new ones.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for zone in values(var.isolation_zones) : contains(["int", "ext"], zone.exposure)])
    error_message = "An isolation zone's exposure must be int or ext."
  }
  validation {
    condition     = length(distinct([for zone in values(var.isolation_zones) : zone.index])) == length(var.isolation_zones)
    error_message = "Two isolation zones cannot share an index."
  }
}

variable "cells" {
  type = map(object({
    address_space = string
  }))
  default     = {}
  description = <<DESCRIPTION
The stateless cells' networks, keyed by the cell (`dev-stateless-az1`, the cluster's name without
`aks-`): `vnet-<cell>` with `address_space`, a /20, laid out as cells.tf describes - `snet-system`
for the system pool, and per isolation zone `snet-<zone>-nodes` and `snet-<zone>-ilb`.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for cell in values(var.cells) : can(cidrsubnet(cell.address_space, 4, 15)) && tonumber(split("/", cell.address_space)[1]) == 20])
    error_message = "A cell's address_space must be a /20."
  }
}

variable "cell_pod_cidr" {
  type        = string
  default     = "100.201.0.0/16"
  description = "The clusters' overlay pod range (their network_profile.pod_cidr), which the cells' NSGs let in between nodes."
  nullable    = false
}

variable "internal_dns_zones" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Azure Private DNS zones for the internal zones' names - `int-fi.dev.onek8s.lol` - created here and
linked to every cell's network, so they resolve inside the cells and nowhere else.
DESCRIPTION
  nullable    = false
}

variable "log_analytics_workspace_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the environment's Log Analytics workspace, created here (OneK8s design section 19,
`log-<env>-platform`): the Kubernetes audit logs of every cluster of the environment, which each
cluster sends to it by naming it in its own log_analytics_workspace_name. Null for none.
DESCRIPTION
}

variable "log_analytics_retention_in_days" {
  type        = number
  default     = 30
  description = "Days the workspace keeps its data: 30 to 730."
  nullable    = false

  validation {
    condition     = var.log_analytics_retention_in_days >= 30 && var.log_analytics_retention_in_days <= 730
    error_message = "log_analytics_retention_in_days must be from 30 to 730."
  }
}

variable "log_analytics_daily_quota_gb" {
  type        = number
  default     = 1
  description = "The workspace's daily ingestion cap in GB, -1 for none."
  nullable    = false
}
