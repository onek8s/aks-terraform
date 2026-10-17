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
    groups = optional(object({
      view  = optional(string)
      edit  = optional(string)
      admin = optional(string)
    }), {})
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

`groups` are the namespace's Entra ID groups of the clusters' `managed_namespaces.<ns>.groups` - the
same object IDs - granted on the share what their Kubernetes role grants on Secrets (OneK8s design
section 8): `admin` manages the namespace's secrets like `writers` (`Key Vault Secrets Officer`
under the namespace's condition: its own secrets, by name); `edit` writes and updates them and reads
their attributes, never a value (the custom role `OneK8s Key Vault Secrets Editor (<resource
group>)`, same condition); `view` gets nothing. Nobody
with a share lists the vault - see platform_viewer_group_object_ids. The Isolation tests check that
the two lists agree.
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
      for namespace in values(var.key_vault_namespaces) : [
        for group in [namespace.groups.view, namespace.groups.edit, namespace.groups.admin] :
        group == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", coalesce(group, "-")))
      ]
    ]))
    error_message = "key_vault_namespaces[*].groups.view, .edit and .admin must each be the object ID of an Entra ID group, or left unset."
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
Signing of the registry's images (OneK8s design section 9): a self-signed code signing certificate
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
    zone        = optional(string)
  }))
  default     = {}
  description = <<DESCRIPTION
Hostnames in dns_zone_name that every listed cluster serves at once, keyed by the name below the zone
(`hello` for hello.onek8s.lol): an Azure Traffic Manager profile each, weighting the `endpoints` -
each cluster's own public hostname, such as `public-aks-dev-ext-stateless-az1.onek8s.lol` - alike and
leaving out one whose probe of `health_path` fails, and a CNAME of the hostname to it. The clusters'
external-dns have to leave the hostname alone.

`zone` names the external isolation zone that serves the hostname: no profile is made while that
zone is not deployed - not in isolation_zones, disabled, or the resources serve the internal
exposure - nor for any hostname when exposure is `int`.
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
One Key Vault per isolation zone - OneK8s design section 7 - keyed by the zone (`int-fi`): the
secrets of the zone's applications. A namespace's share is in its zone's vault (key_vault_namespaces,
`zone`). Key Vault names are global.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for name in values(var.zone_key_vault_names) : can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", name)) && length(name) >= 3 && length(name) <= 24])
    error_message = "A zone vault's name must be 3 to 24 letters, digits and single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "exposure" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The exposure these shared resources serve - OneK8s design decision D52: `int` or `ext`. Internal and
external workloads have a subscription and clusters each, so one apply of this configuration serves
the clusters of one exposure in its subscription: every isolation zone is of that exposure, only an
external one publishes global_hostnames (Traffic Manager: an internal one creates none of them), only an
internal one has internal_dns_zones. Null checks nothing.
DESCRIPTION

  validation {
    condition     = var.exposure == null || contains(["int", "ext"], coalesce(var.exposure, "-"))
    error_message = "exposure must be int or ext."
  }
  validation {
    condition     = var.exposure == null || alltrue([for zone in values(var.isolation_zones) : zone.exposure == var.exposure])
    error_message = "Every isolation zone must be of the exposure these resources serve: internal and external zones never share a subscription or a cluster (design decision D52)."
  }
  validation {
    condition     = var.exposure != "ext" || length(var.internal_dns_zones) == 0
    error_message = "The external exposure has no internal zones' private DNS (design decision D52)."
  }
}

variable "isolation_zones" {
  type = map(object({
    exposure = string
    index    = number
    enabled  = optional(bool, true)
  }))
  default     = {}
  description = <<DESCRIPTION
The isolation zones - OneK8s design, "Isolation zone" - keyed by name (`int-fi`, `ext-se`):
`exposure` `int` (reached from the corporate network) or `ext` (from the internet), and `index`, the
zone's /24 in each cell's address space (1 to 14; 0 is the system pool's, 15 the API server's). A zone's index never
changes once it is in use - a new country's zones take new ones.

`enabled = false` disables a country's zone without giving up its index: no subnets, NSGs or private
DNS for it in any cell, and no Traffic Manager profile for its global hostnames. Its vault
(zone_key_vault_names) and namespaces (key_vault_namespaces) are left out by not listing them, as
are the zone in the clusters' tfvars, the fleet's zones.yaml and the landing zone's policies.
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
    address_space     = string
    enabled           = optional(bool, true)
    api_server_subnet = optional(bool, false)
    pod_network       = optional(string, "overlay")
  }))
  default     = {}
  description = <<DESCRIPTION
The stateless cells' networks, keyed by the cell (`dev-int-stateless-az2`, the cluster's name without
`aks-`): `vnet-<cell>` with `address_space`, a /16 to /20, laid out as cells.tf describes - `snet-system`
for the system pool, and per isolation zone `snet-<zone>-nodes` and `snet-<zone>-ilb`, each sized from
the address space (a /20 gives a zone a /25 of nodes, a /16 a /21).

`enabled = false` keeps a cell in the specification - its address space stays reserved - without
building its network: no VNet, subnets, NSGs, route table, hub peering or DNS links. Its cluster
cannot be deployed while it is disabled.

`api_server_subnet = true` adds `snet-apiserver`, delegated to AKS for API Server VNet Integration
(design section 4). Azure refuses that integration on an encrypted network with v4 and newer VM sizes
(`VNetEncryptionNotCompatibleWithAPIServerVNetIntegration`), and every cell network here is encrypted
(section 15), so it stays off until that changes; a private cluster then uses Private Link instead.

`pod_network` is where the cell's cluster gives its pods their addresses: `overlay` (Azure CNI Overlay,
the default - the pods' range is `cell_pod_cidr`, translated to the node's address when it leaves the
node) or `subnet` (Azure CNI node subnet, no overlay - every pod has an address of its node's subnet,
which it keeps up to the hub's firewall: the firewall sees which zone, and which pod, a flow comes from,
design D59). A `subnet` cell needs room for the pods, so its address space is a /16 of the shared
address space 100.64.0.0/10 (RFC 6598), never routed outside the landing zone - the firewall translates
every flow that leaves it. The cell's cluster says the same in its network_profile.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for cell in values(var.cells) : can(cidrsubnet(cell.address_space, 4, 15)) && tonumber(split("/", cell.address_space)[1]) >= 16 && tonumber(split("/", cell.address_space)[1]) <= 20])
    error_message = "A cell's address_space must be a /16 to /20."
  }
  validation {
    condition     = alltrue([for cell in values(var.cells) : contains(["overlay", "subnet"], cell.pod_network)])
    error_message = "A cell's pod_network must be \"overlay\" or \"subnet\"."
  }
  validation {
    condition = alltrue([
      for cell in values(var.cells) : cell.pod_network == "overlay" || (
        cidrsubnet("${cidrhost(cell.address_space, 0)}/10", 0, 0) == "100.64.0.0/10" && tonumber(split("/", cell.address_space)[1]) == 16
      )
    ])
    error_message = "A cell with pod_network = \"subnet\" takes a /16 of 100.64.0.0/10 (RFC 6598), for example 100.64.0.0/16."
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
Name of the environment's Log Analytics workspace, created here (OneK8s design section 21,
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

variable "monthly_budget" {
  type = object({
    amount         = number
    start_date     = string
    contact_roles  = optional(list(string), ["Owner"])
    contact_emails = optional(list(string), [])
  })
  default     = null
  description = <<DESCRIPTION
The environment subscription's monthly budget, in the billing account's currency: Azure Cost
Management notifies `contact_roles` (the subscription's Owners by default) and `contact_emails` when
the month's actual cost passes 80 % and 100 % of `amount`, and when its forecast passes 100 %.
`start_date` is the first day of a month, `2026-10-01T00:00:00Z`, and stays put once set: Azure
refuses a start date in the past on a new budget, not on an existing one. Null for none.
DESCRIPTION

  validation {
    condition     = var.monthly_budget == null || try(var.monthly_budget.amount > 0 && can(regex("^[0-9]{4}-[0-9]{2}-01T00:00:00Z$", var.monthly_budget.start_date)), false)
    error_message = "monthly_budget.amount must be positive and start_date the first of a month, e.g. 2026-10-01T00:00:00Z."
  }
}

variable "platform_viewer_group_object_ids" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Entra ID groups that list the namespaces of the environment's clusters and the secrets of its Key
Vaults - names and attributes, no workload and no secret value (OneK8s design section 8, "Soft
multi-tenancy"). The namespaces' own groups see only their namespace and their own secrets, so this
is what the Azure portal's Kubernetes views need to offer a namespace to pick. Granted a custom role
defined and assigned at the resource group - see platform_viewers.tf.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for group in var.platform_viewer_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", group))])
    error_message = "platform_viewer_group_object_ids must be Entra ID group object IDs."
  }
}

variable "key_vault_secrets_editor_role_name" {
  type        = string
  default     = null
  description = "Name of the namespace `edit` groups' custom Key Vault role. Unique in the tenant; defaults to `OneK8s Key Vault Secrets Editor (<resource group>)`."
}

variable "platform_viewer_role_name" {
  type        = string
  default     = null
  description = "Name of the platform viewers' custom role. Unique in the tenant; defaults to `OneK8s Platform Viewer (<resource group>)`."
}

variable "hub" {
  type = object({
    virtual_network_id = string
    next_hop_ip        = string
    dns_servers        = optional(list(string), [])
  })
  default     = null
  description = <<DESCRIPTION
The landing zone's hub, for cells routed through its firewall (OneK8s design sections 6 and 10;
azure-landing-zone network modes `firewall` and `labfw`): every cell's network is peered with the hub
VNet `virtual_network_id` (in the connectivity subscription - the deploying identity needs the
landing zone's `AKS spoke peering` role on it), every node subnet sends 0.0.0.0/0 to `next_hop_ip` (the
Azure Firewall's or labfw's private address; the clusters then use AKS outbound type
`userDefinedRouting`), the cells use `dns_servers` (the firewall's DNS proxy; empty keeps Azure DNS),
and the internal zones' private DNS zones are linked to the hub as well, so the DNS proxy resolves
them. Null: each cell is a network of its own with load balancer egress (network mode `sandbox`).
DESCRIPTION

  validation {
    condition     = var.hub == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", try(var.hub.virtual_network_id, "")))
    error_message = "hub.virtual_network_id must be a virtual network's resource ID."
  }
  validation {
    condition     = var.hub == null || can(cidrhost("${try(var.hub.next_hop_ip, "")}/32", 0))
    error_message = "hub.next_hop_ip must be an IPv4 address."
  }
}

variable "private_endpoints" {
  type = object({
    subnet_name    = optional(string, "snet-shared-pe")
    address_prefix = string
    # The resource group of the landing zone's private link DNS zones (privatelink.vaultcore.azure.net,
    # privatelink.azurecr.io, the Foundry and blob zones), in the hub's subscription
    dns_zone_resource_group_id = string
    # The Terraform state account (Deploy's TF_STATE_STORAGE_ACCOUNT): a private endpoint, Entra ID only
    state_storage_account_id = optional(string)
    # false: no public network access to the vaults, the registry (Premium: prd), Foundry, the state account and
    # the Log Analytics workspace (in the landing zone's Azure Monitor Private Link scope)
    public_network_access = optional(bool, true)
  })
  default     = null
  description = <<DESCRIPTION
Private endpoints for the environment's services - the platform vault, every zone vault, on a
Premium registry only (prd by default - container_registry_sku; Azure offers none below it) the
container registry, the agents' Foundry resource (ai_foundry) and the Terraform state account (`state_storage_account_id`) - in a subnet
`subnet_name` with `address_prefix` of the environment network virtual_network_create creates, registered in the
landing zone's private link DNS zones in `dns_zone_resource_group_id` (the deploying identity needs
Private DNS Zone Contributor there). With `hub`, that network is peered with the hub.
`public_network_access = false` turns the services' public network access off (Azure's trusted services excepted).
Null for none.
DESCRIPTION

  validation {
    condition     = var.private_endpoints == null || can(cidrhost(try(var.private_endpoints.address_prefix, ""), 0))
    error_message = "private_endpoints.address_prefix must be a CIDR range."
  }
}

variable "container_registry_sku" {
  type        = string
  default     = null
  description = <<DESCRIPTION
SKU of the environment's container registry: Basic, Standard or Premium. Null, the default, follows
the environment (design D62): Premium in `prd` - a private endpoint (private_endpoints, with a
dedicated data endpoint so the image layers come through it too) and no public network access -
and Basic in every other environment, on its public endpoint with Entra ID authentication only
(admin user off). Azure offers private endpoints on Premium alone, and a Premium registry costs
about eight times a Basic one, so the non-production registries stay public.
DESCRIPTION

  validation {
    condition     = var.container_registry_sku == null || contains(["Basic", "Standard", "Premium"], coalesce(var.container_registry_sku, "-"))
    error_message = "container_registry_sku must be Basic, Standard or Premium."
  }
}

variable "ai_foundry" {
  type = object({
    name          = string
    location      = string
    model         = optional(string, "claude-sonnet-5-5")
    model_version = optional(string, "1")
    capacity      = optional(number, 50)
    # OpenAI models on the same resource, by model name: version, capacity (thousands of tokens a minute), content
    # filter, and import = true for one created outside Terraform
    openai_deployments = optional(map(object({
      version         = string
      capacity        = optional(number, 10)
      rai_policy_name = optional(string, "Microsoft.DefaultV2")
      import          = optional(bool, false)
    })), {})
    # The deployment needs Foundry quota for the model (Tokens Per Minute, per subscription and region); false
    # keeps the attestation below but makes no deployment until the quota is granted
    deploy = optional(bool, true)
    # Who deploys Anthropic's model: sent to Anthropic, and the Marketplace offer is signed in this name. Null: the
    # Foundry resource without a deployment.
    model_provider = optional(object({
      organization_name = string
      country_code      = string # ISO 3166 alpha-2, e.g. FI
      industry          = optional(string, "technology")
    }))
  })
  default     = null
  description = <<DESCRIPTION
The AI agents' model endpoint (onek8s/aks-ai-agents, `model.provider: foundry`): a Microsoft Foundry (AI Services)
resource `name` in `location` - a region that offers Anthropic's models - with one GlobalStandard deployment of
`model`, named like the model, once `model_provider` names the organisation that deploys it (Anthropic's terms are
accepted in its name, and its name, country and industry go to Anthropic with every request). Entra ID only (no
keys); the identity that applies this stack, which also runs the agent workflows, gets `Cognitive Services User`.
Null for none.
DESCRIPTION
}
