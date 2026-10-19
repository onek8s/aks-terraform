variable "location" {
  type        = string
  description = "Azure region of the cluster. Must match the region of the existing virtual network."
  nullable    = false

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "name" {
  type        = string
  description = "Name of the AKS cluster."
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,61}[a-zA-Z0-9]$", var.name))
    error_message = "name must be 2 to 63 characters of letters, digits, underscores and hyphens, starting and ending with a letter or digit."
  }
}

variable "environment" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The environment the cluster belongs to (`dev`), for the names of the environment's shared resources
it looks up and of its own (naming). Null: the second segment of the cluster's name -
`aks-<environment>-<which one>` - or the whole name if it has one segment. State it when the naming
policy names clusters some other way.
DESCRIPTION

  validation {
    condition     = var.environment == null || can(regex("^[a-z0-9]+$", coalesce(var.environment, "-")))
    error_message = "environment must be lowercase letters and digits."
  }
}

variable "naming" {
  type = object({
    templates      = optional(map(string), {})
    location_codes = optional(map(string), {})
  })
  default     = {}
  description = <<DESCRIPTION
The estate's naming policy (modules/conventions, variable `naming`) - the same as shared/'s, so the
cluster finds the environment's shared identities under the names shared/ gave them: a template per
resource type with the placeholders `{environment}`, `{exposure}`, `{location}`, `{location_code}`,
`{name}` and `{domain}`, merged over the defaults (the lab's names), and the regions' short codes. Here
it names the cluster's identities (`user_assigned_identity`; the namespaces' and external-dns's
add `-kv-<namespace>` and `-dns`) and its disk encryption set. The cluster's own name and the names of
what it looks up are stated in their variables. A real estate's policy stays out of the repository -
see the README, "Naming policy".
DESCRIPTION
  nullable    = false
}

variable "node_subnet_name" {
  type        = string
  description = "Name of the subnet of `virtual_network_name` the system pool's nodes are placed in - the cell's `snet-system`, created by shared/."
  nullable    = false

  validation {
    condition     = length(trimspace(var.node_subnet_name)) > 0
    error_message = "node_subnet_name must not be empty."
  }
}

variable "pod_subnet_name" {
  type        = string
  description = "Name of the subnet of `virtual_network_name` the system pool's pods take their addresses from (Azure CNI Pod Subnet with dynamic IP allocation) - the cell's `snet-system-pods`, created by shared/. Cannot change on a running pool."
  nullable    = false

  validation {
    condition     = length(trimspace(var.pod_subnet_name)) > 0
    error_message = "pod_subnet_name must not be empty."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group the cluster is deployed into."
  nullable    = false

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "virtual_network_name" {
  type        = string
  description = "Name of the cluster's virtual network in `resource_group_name` - the cell's, created by shared/ (`cells`)."
  nullable    = false

  validation {
    condition     = length(trimspace(var.virtual_network_name)) > 0
    error_message = "virtual_network_name must not be empty."
  }
}

variable "auto_upgrade" {
  type = object({
    kubernetes_channel = optional(string, "stable")
    node_os_channel    = optional(string, "NodeImage")
  })
  default     = {}
  description = <<DESCRIPTION
How the cluster upgrades itself. Both run inside the `maintenance_window`.

- `kubernetes_channel` - Kubernetes version upgrades. `stable` follows the second newest minor
  version AKS offers, `rapid` the newest, `patch` stays on the current minor version and takes its
  patches, `node-image` upgrades only the node image, and `none` leaves every upgrade to you.
- `node_os_channel` - Node OS patching. `NodeImage` rolls the nodes onto the weekly AKS node image,
  `SecurityPatch` applies security updates to the running image between those, `None` and
  `Unmanaged` leave the OS to you and to the distribution respectively.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["node-image", "none", "patch", "rapid", "stable"], var.auto_upgrade.kubernetes_channel)
    error_message = "auto_upgrade.kubernetes_channel must be one of \"none\", \"patch\", \"stable\", \"rapid\" or \"node-image\"."
  }
  validation {
    condition     = contains(["NodeImage", "None", "SecurityPatch", "Unmanaged"], var.auto_upgrade.node_os_channel)
    error_message = "auto_upgrade.node_os_channel must be one of \"NodeImage\", \"SecurityPatch\", \"None\" or \"Unmanaged\"."
  }
  # A pinned version and a channel that moves past it fight each other: AKS upgrades the cluster,
  # Terraform writes the pinned version back, and Azure refuses the downgrade.
  validation {
    condition = var.kubernetes_version == null || contains(
      length(split(".", coalesce(var.kubernetes_version, "0.0"))) > 2 ? ["node-image", "none"] : ["node-image", "none", "patch"],
      var.auto_upgrade.kubernetes_channel
    )
    error_message = "A pinned kubernetes_version needs auto_upgrade.kubernetes_channel to be \"none\" or \"node-image\", or \"patch\" when only the minor version is pinned. Any other channel upgrades the cluster past the pin, and Terraform cannot put it back."
  }
}

variable "azure_policy_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether to install the Azure Policy add-on, which enforces Azure Policy definitions inside the
cluster through Gatekeeper.
DESCRIPTION
  nullable    = false
}

variable "gateway_implementation" {
  type        = string
  default     = "approuting-istio"
  description = <<DESCRIPTION
The Gateway API implementation that serves the cluster's Gateways, one per isolation zone, deployed by the
Flux repository (design section 4.1): `approuting-istio` (the default, production: App Routing's Gateway
API, the Azure standard offering, upgraded by AKS - D55) or `traefik` (Traefik Proxy, one small Deployment
per Gateway from this repository's `gateways/traefik`, a non-production cost saving: istiod's untunable
1 CPU and 4 GiB, Azure/AKS#5939, is what it saves); null for a cluster without Gateways (the stateful
cluster, R9a). The Flux repository is told each Gateway's class as `gateway_class_name_<zone>`; switching
re-creates the Gateways. See the README, "Ingress through the Gateway API".
DESCRIPTION

  validation {
    condition     = var.gateway_implementation == null || contains(["traefik", "approuting-istio"], coalesce(var.gateway_implementation, "-"))
    error_message = "gateway_implementation must be traefik, approuting-istio or null."
  }
}

variable "traefik_flux_repository" {
  type = object({
    url                   = optional(string, "https://github.com/onek8s/aks-terraform")
    branch                = optional(string, "main")
    path                  = optional(string, "./gateways/traefik")
    sync_interval_seconds = optional(number, 300)
  })
  default     = {}
  description = <<DESCRIPTION
Where the Flux configurations of `gateway_implementation = "traefik"` read Traefik's manifests:
this repository's `gateways/traefik` on `main` by default, so the Gateway implementation is under
this repository's control rather than the Flux repository's. A public repository: no credential is
sent.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^https://", var.traefik_flux_repository.url)) && startswith(var.traefik_flux_repository.path, "./")
    error_message = "traefik_flux_repository.url must start with https:// and its path with ./."
  }
  validation {
    condition     = var.traefik_flux_repository.sync_interval_seconds >= 60
    error_message = "traefik_flux_repository.sync_interval_seconds must be at least 60."
  }
}

variable "image_integrity_enabled" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether AKS runs [Image Integrity][ii] (preview): Ratify, which checks each image's Notation
signature for the Azure Policy add-on, so that the assignment "Kubernetes cluster containers should
only use images that are signed with Notation" reports unsigned images (OneK8s design section 2.7;
audit only while in preview). Ratify reads the signatures in `container_registry_name` and the
signing certificate in the environment's shared platform vault as the shared identity shared/ creates
with its image_signing, through a federated credential added here for Ratify's service account; Flux
gets the rest (`image_verification_client_id`, `image_signing_certificate_name`,
`image_signing_subject`, `container_registry_login_server`) and applies Ratify's configuration. Needs the subscription's
`Microsoft.ContainerService/EnableImageIntegrityPreview` feature (the Deploy workflow registers it),
the Azure Policy add-on, the shared vault and the registry.

[ii]: https://learn.microsoft.com/en-us/azure/aks/image-integrity
DESCRIPTION
  nullable    = false

  validation {
    condition     = !var.image_integrity_enabled || (var.azure_policy_enabled && var.key_vault_name != null && var.container_registry_name != null)
    error_message = "image_integrity_enabled needs the Azure Policy add-on, the environment's platform Key Vault (key_vault_name) and container_registry_name."
  }
}

variable "image_integrity_service_account" {
  type        = string
  default     = "gatekeeper-system/ratify-admin"
  description = "`<namespace>/<name>` of the service account the Image Integrity add-on runs Ratify as - the subject of its federated credential."
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9-]+/[a-z0-9-]+$", var.image_integrity_service_account))
    error_message = "image_integrity_service_account is <namespace>/<name>."
  }
}

variable "default_node_pool" {
  type = object({
    name                = optional(string, "system")
    vm_size             = optional(string, "Standard_D4ds_v5")
    node_count          = optional(number, 2)
    enable_auto_scaling = optional(bool, false)
    min_count           = optional(number, 1)
    max_count           = optional(number, 1)
    max_pods            = optional(number)
    os_disk_size_gb     = optional(number)
    os_disk_type        = optional(string)
    availability_zones  = optional(list(string))

    max_surge                  = optional(string, "10%")
    drain_timeout_minutes      = optional(number)
    node_soak_duration_minutes = optional(number)

    os_sku             = optional(string, "AzureLinux")
    encryption_at_host = optional(bool)
    ssh_access         = optional(string)
    node_taints        = optional(list(string))
  })
  default     = {}
  description = <<DESCRIPTION
The system node pool. The defaults are the production setting (design section 2.3): two `Standard_D4ds_v5`
nodes on Azure Linux 3.0; the dev lab's one 8 GiB node is a cost saving (README, "Production defaults and
non-production cost savings"). `os_disk_type` `Ephemeral` or `Managed` (null: AKS chooses),
`encryption_at_host`, `ssh_access` (`Disabled`, `LocalUser`, `EntraId`), `node_taints`
(`CriticalAddonsOnly=true:NoSchedule` keeps every pod but the platform's off it), `max_pods`, and the upgrade roll: `max_surge`, `drain_timeout_minutes`,
`node_soak_duration_minutes` (README, "Node pool upgrades"). The size, OS and disk type
cannot change on a running pool.
DESCRIPTION
  nullable    = false

  validation {
    condition     = var.default_node_pool.ssh_access == null || contains(["Disabled", "LocalUser", "EntraId"], coalesce(var.default_node_pool.ssh_access, "-"))
    error_message = "default_node_pool.ssh_access must be Disabled, LocalUser or EntraId, or left unset."
  }
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,11}$", var.default_node_pool.name))
    error_message = "default_node_pool.name must be 1 to 12 lowercase letters and digits, starting with a letter."
  }
  validation {
    condition     = var.default_node_pool.node_count >= 1
    error_message = "default_node_pool.node_count must be at least 1. A system pool cannot be empty."
  }
  validation {
    condition     = !var.default_node_pool.enable_auto_scaling || var.default_node_pool.min_count <= var.default_node_pool.max_count
    error_message = "default_node_pool.min_count must not exceed default_node_pool.max_count."
  }
  validation {
    condition     = !var.default_node_pool.enable_auto_scaling || (var.default_node_pool.node_count >= var.default_node_pool.min_count && var.default_node_pool.node_count <= var.default_node_pool.max_count)
    error_message = "default_node_pool.node_count must be between min_count and max_count while autoscaling is enabled."
  }
  validation {
    condition     = var.default_node_pool.os_disk_type == null || contains(["Ephemeral", "Managed"], coalesce(var.default_node_pool.os_disk_type, "-"))
    error_message = "default_node_pool.os_disk_type must be Ephemeral or Managed, or left unset."
  }
  validation {
    condition     = var.default_node_pool.os_disk_size_gb == null || try(var.default_node_pool.os_disk_size_gb >= 30, false)
    error_message = "default_node_pool.os_disk_size_gb must be at least 30."
  }
  validation {
    condition     = var.default_node_pool.max_pods == null || try(var.default_node_pool.max_pods >= 10, false)
    error_message = "default_node_pool.max_pods must be at least 10."
  }
  validation {
    condition     = can(regex("^[1-9][0-9]*%?$", var.default_node_pool.max_surge))
    error_message = "default_node_pool.max_surge must be a node count or a percentage, for example \"2\" or \"10%\"."
  }
  validation {
    condition     = var.default_node_pool.drain_timeout_minutes == null || try(var.default_node_pool.drain_timeout_minutes >= 1 && var.default_node_pool.drain_timeout_minutes <= 1440, false)
    error_message = "default_node_pool.drain_timeout_minutes must be between 1 and 1440."
  }
  validation {
    condition     = var.default_node_pool.node_soak_duration_minutes == null || try(var.default_node_pool.node_soak_duration_minutes >= 0 && var.default_node_pool.node_soak_duration_minutes <= 30, false)
    error_message = "default_node_pool.node_soak_duration_minutes must be between 0 and 30."
  }
}

variable "dns_zone_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the DNS zone the cluster publishes its Gateway hostnames in, for example `contoso.com` - a
public Azure DNS zone, or an Azure Private DNS zone with `dns_zone_private`; one that exists already
(shared/ creates it, or it was provisioned outside Terraform). external-dns, deployed through Flux, keeps a record in it for every
hostname a Gateway listener serves, pointing at the address of the Gateway's load balancer
- a public one for a public zone, an internal one for a private zone. An identity is created for it
here, federated with its Kubernetes service account and granted on the zone. Leave it unset and
nothing is published.
DESCRIPTION
}

variable "dns_zone_private" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether the zone of `dns_zone_name` is an Azure Private DNS zone - a domain that resolves only inside
the networks the zone is linked to - rather than a public Azure DNS zone: the one switch between the
two, set alike here and in shared/, which creates a private zone and links it to the clusters'
network. external-dns writes it with its `azure-private-dns` provider instead of `azure`, and is
granted `Private DNS Zone Contributor` instead of `DNS Zone Contributor`; the Gateway's load balancer is
internal. The Flux repository is told which (`dns_zone_private`, `dns_provider`).
DESCRIPTION
  nullable    = false
}

variable "dns_zone_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the DNS zone. Defaults to `resource_group_name`."
}

variable "entra_admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Object IDs of the Microsoft Entra ID groups granted cluster admin: each is assigned `Azure Kubernetes
Service RBAC Cluster Admin` on the cluster, the Azure role that answers to `cluster-admin` inside it.

Members still need `Azure Kubernetes Service Cluster User Role` on the cluster to download a
kubeconfig at all; that one is not created here.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for id in var.entra_admin_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_admin_group_object_ids must contain group object IDs as GUIDs, not group names."
  }
}

variable "entra_reader_group_object_ids" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Object IDs of the Microsoft Entra ID groups granted read-only access to the cluster, by assigning
them `Azure Kubernetes Service RBAC Reader` on it. That role reads most objects in every namespace,
but not `Secrets` and not roles or role bindings.

Members still need `Azure Kubernetes Service Cluster User Role` on the cluster to download a
kubeconfig at all; that one is not created here.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for id in var.entra_reader_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_reader_group_object_ids must contain group object IDs as GUIDs, not group names."
  }
}

variable "flux_git_repository" {
  type = object({
    url                   = string
    branch                = optional(string, "main")
    path                  = optional(string, "./")
    sync_interval_seconds = optional(number, 300)
  })
  default     = null
  description = <<DESCRIPTION
The one Git repository the cluster syncs its main configuration from through Flux: a public one, read
without a credential. Setting it installs the Flux cluster extension and creates a Flux configuration
named `platform` that reconciles the Kustomization at `path` on `branch`. Leave it unset and Flux is
not installed.
DESCRIPTION

  validation {
    condition     = var.flux_git_repository == null || can(regex("^https://", var.flux_git_repository.url))
    error_message = "flux_git_repository.url must start with https://."
  }
  validation {
    condition     = var.flux_git_repository == null || try(trimspace(var.flux_git_repository.branch) != "", false)
    error_message = "flux_git_repository.branch must not be empty."
  }
  validation {
    condition     = var.flux_git_repository == null || try(var.flux_git_repository.sync_interval_seconds >= 60, false)
    error_message = "flux_git_repository.sync_interval_seconds must be at least 60."
  }
}

variable "namespace_access_path" {
  type        = string
  default     = "./infrastructure/namespace-access"
  description = <<DESCRIPTION
The directory of `flux_git_repository` with one subdirectory per role - `view`, `edit`, `admin` -
that holds the `RoleBinding` a `managed_namespaces[*].groups` entry of that role is made from:
`$${namespace}`, `$${role}` (also the ClusterRole bound) and `$${group_object_id}` are filled in per
binding. Azure refuses two Kustomizations of one Flux configuration on the same path, hence a
directory per role.
DESCRIPTION
  nullable    = false

  validation {
    condition     = startswith(var.namespace_access_path, "./")
    error_message = "namespace_access_path must be a path in the repository starting with ./, for example \"./infrastructure/namespace-access\"."
  }
}

variable "flux_github_webhook" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether a GitHub push reaches the cluster at once rather than at the next poll: the cluster gets the
platform's Gateway, `platform` in `platform-gateway` - a public load balancer for Flux's webhook
receivers - and `flux-system` a share of the vault to read the token shared/ keeps there
(`flux-system--github-webhook-token`, its `flux_github_webhook`). Only for a cell with a public entry
point: behind the hub's firewall a public load balancer cannot answer, so an internal cell polls.
Needs `flux_git_repository`, `key_vault_name` and a `gateway_implementation`; the Flux webhooks
workflow points the repositories' webhooks at it.
DESCRIPTION
  nullable    = false
}

variable "key_vault_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the environment's platform Key Vault in `resource_group_name`, created by shared/ with the
namespaces' identities and every grant on it, and looked up here. Leave it unset and nothing is synced
from a vault.

A namespace owns the secrets named `<namespace>--<name>`. Each namespace in `key_vault_namespaces` and
`managed_namespaces` reads its share as the environment's shared identity for it, which the cluster
federates with the namespace's `key-vault` service account - an application namespace's share is in its
zone's vault (`key_vault_namespace_vaults`). Every namespace with a share here needs one in shared/ too.
DESCRIPTION

  validation {
    condition     = var.key_vault_name == null || can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", var.key_vault_name)) && try(length(var.key_vault_name) >= 3 && length(var.key_vault_name) <= 24, false)
    error_message = "key_vault_name must be 3 to 24 letters, digits and single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "key_vault_namespaces" {
  type        = set(string)
  default     = []
  description = <<DESCRIPTION
Namespaces that are not in `managed_namespaces` and still get a share of the platform vault: the ones
the Flux repository creates for the platform itself - each zone's `<zone>-gateway`, whose listener
certificate is `<zone>-gateway--wildcard`, and `flux-system`. Every managed namespace gets one anyway.
Nothing is created for them without a `key_vault_name`.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for name in var.key_vault_namespaces : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))])
    error_message = "Every entry of key_vault_namespaces must be a Kubernetes namespace name: 1 to 63 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes minor version, for example `1.32`. Defaults to the AKS default version."

  validation {
    condition     = var.kubernetes_version == null || can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be of the form 1.32 or 1.32.4, without a leading \"v\"."
  }
}

variable "maintenance_window" {
  type = object({
    day_of_week    = optional(string, "Tuesday")
    start_time     = optional(string, "22:00")
    duration_hours = optional(number, 8)
    interval_weeks = optional(number, 1)
    utc_offset     = optional(string, "+00:00")
  })
  default     = {}
  description = <<DESCRIPTION
Weekly window the cluster is allowed to upgrade itself in. Defaults to the night between Tuesday and
Wednesday, 22:00 - 06:00 UTC. A window that runs past midnight simply continues into the next day.

- `day_of_week` - Day the window opens on, `Monday` through `Sunday`.
- `start_time` - Time the window opens as `HH:MM`, in the time zone given by `utc_offset`.
- `duration_hours` - Length of the window. Azure allows 4 to 24 hours, and needs at least 4 for an
  upgrade to be attempted at all.
- `interval_weeks` - Weeks between windows. `1` opens one every week.
- `utc_offset` - Time zone of `start_time` as `+/-HH:MM`, for example `+03:00` for Finnish summer
  time. Note that Azure does not follow daylight saving time, so a fixed offset shifts by an hour
  relative to local time for part of the year.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Friday", "Monday", "Saturday", "Sunday", "Thursday", "Tuesday", "Wednesday"], var.maintenance_window.day_of_week)
    error_message = "maintenance_window.day_of_week must be an English weekday name, for example \"Tuesday\"."
  }
  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_window.start_time))
    error_message = "maintenance_window.start_time must be of the form HH:MM, between \"00:00\" and \"23:59\"."
  }
  validation {
    condition     = var.maintenance_window.duration_hours >= 4 && var.maintenance_window.duration_hours <= 24
    error_message = "maintenance_window.duration_hours must be between 4 and 24."
  }
  validation {
    condition     = var.maintenance_window.interval_weeks >= 1
    error_message = "maintenance_window.interval_weeks must be at least 1."
  }
  validation {
    condition     = can(regex("^[-+][0-9]{2}:[0-9]{2}$", var.maintenance_window.utc_offset))
    error_message = "maintenance_window.utc_offset must be of the form +HH:MM or -HH:MM."
  }
}

variable "managed_namespace_defaults" {
  type = object({
    adoption_policy = optional(string, "Never")
    annotations     = optional(map(string), {})
    delete_policy   = optional(string, "Keep")
    labels          = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string, "AllowAll")
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
What every entry in `managed_namespaces` gets unless it says otherwise: the default `NetworkPolicy`
(`ingress` `AllowSameNamespace`, `egress` `AllowAll`; each `AllowAll`, `AllowSameNamespace` or `DenyAll` -
Kubernetes network policies are additive, so a policy in the namespace can only widen these), the Pod
Security Standard (`enforce`, `audit` and `warn`: `restricted`, `baseline`, `privileged` or `none`; `version`
`latest` or `v1.NN`), the `ResourceQuota` Azure requires on every managed namespace (CPU in Kubernetes
units, sent as milliCPU; memory as `Mi`/`Gi`), `adoption_policy` (`Never`, `IfIdentical`, `Always`),
`delete_policy` (`Keep`, `Delete`), and `labels` and `annotations` for all. See the README, "Managed
namespaces".
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Always", "IfIdentical", "Never"], var.managed_namespace_defaults.adoption_policy)
    error_message = "managed_namespace_defaults.adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\"."
  }
  validation {
    condition     = contains(["Delete", "Keep"], var.managed_namespace_defaults.delete_policy)
    error_message = "managed_namespace_defaults.delete_policy must be either \"Delete\" or \"Keep\"."
  }
  validation {
    condition = alltrue([
      for rule in [var.managed_namespace_defaults.network_policy.egress, var.managed_namespace_defaults.network_policy.ingress] :
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], rule)
    ])
    error_message = "managed_namespace_defaults.network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\"."
  }
  validation {
    condition = alltrue([
      for level in [var.managed_namespace_defaults.pod_security.audit, var.managed_namespace_defaults.pod_security.enforce, var.managed_namespace_defaults.pod_security.warn] :
      contains(["baseline", "none", "privileged", "restricted"], level)
    ])
    error_message = "managed_namespace_defaults.pod_security.audit, .enforce and .warn must each be one of \"restricted\", \"baseline\", \"privileged\" or \"none\"."
  }
  validation {
    condition     = can(regex("^(latest|v[0-9]+\\.[0-9]+)$", var.managed_namespace_defaults.pod_security.version))
    error_message = "managed_namespace_defaults.pod_security.version must be \"latest\" or a pinned Kubernetes minor version such as \"v1.31\"."
  }
  validation {
    condition     = alltrue([for key in keys(var.managed_namespace_defaults.labels) : !startswith(key, "pod-security.kubernetes.io/")])
    error_message = "managed_namespace_defaults.labels must not set a pod-security.kubernetes.io/* label. Use managed_namespace_defaults.pod_security, which is where the Pod Security Standard is decided."
  }
  validation {
    condition = alltrue([
      for quantity in [var.managed_namespace_defaults.resource_quota.cpu_limit, var.managed_namespace_defaults.resource_quota.cpu_request] :
      quantity == null || (
        can(regex("^([0-9]+(\\.[0-9]{1,3})?|[0-9]+m)$", quantity))
        && try(tonumber(trimsuffix(quantity, "m")) > 0, false)
      )
    ])
    error_message = "managed_namespace_defaults.resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities of at least 1 milliCPU, for example \"500m\", \"0.5\" or \"2\". Azure takes the figures in milliCPU, so nothing finer than a milliCPU can be asked for."
  }
  validation {
    condition = alltrue([
      for quantity in [var.managed_namespace_defaults.resource_quota.memory_limit, var.managed_namespace_defaults.resource_quota.memory_request] :
      quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", quantity))
    ])
    error_message = "managed_namespace_defaults.resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
  }
}

variable "managed_namespaces" {
  type = map(object({
    adoption_policy = optional(string)
    annotations     = optional(map(string), {})
    delete_policy   = optional(string)
    flux = optional(object({
      url                   = string
      branch                = optional(string, "main")
      path                  = optional(string, "./")
      secret_name           = optional(string)
      sync_interval_seconds = optional(number, 300)
      substitute            = optional(map(string), {})
    }))
    groups = optional(object({
      view  = optional(string)
      edit  = optional(string)
      admin = optional(string)
    }), {})
    labels = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string)
      ingress = optional(string)
    }), {})
    owner = optional(object({
      team        = string
      cost_center = string
      contact     = string
    }))
    pod_security = optional(object({
      audit   = optional(string)
      enforce = optional(string)
      version = optional(string)
      warn    = optional(string)
    }), {})
    resource_quota = optional(object({
      cpu_limit      = optional(string)
      cpu_request    = optional(string)
      memory_limit   = optional(string)
      memory_request = optional(string)
    }), {})
  }))
  default     = {}
  description = <<DESCRIPTION
Namespaces AKS creates and keeps inside the cluster, keyed by namespace name - Azure resources, so a
namespace survives being deleted by hand and `groups` can be granted on it. Each entry overrides only
what it names of `managed_namespace_defaults`; `labels` and `annotations` merge with the defaults.

- `owner` - who runs the application and pays for it: labels `platform/team` and `platform/cost-center`,
  annotation `platform/contact` (design section 2.6; Azure Policy `namespace-ownership` requires them).
- `groups` - an Entra ID group (object ID) per Kubernetes role, `view`, `edit` and `admin`: a RoleBinding
  `platform-<role>` applied by the cluster's Flux configuration (`<namespace>-access`, one Kustomization
  per role from `namespace_access_path`), and `Azure Kubernetes Service Namespace User` on the namespace
  for a kubeconfig of its own. The same groups get the matching rights on the namespace's secrets in
  shared/.
- `flux` - a tenant: a namespace-scoped Flux configuration named after the namespace syncs `path` on
  `branch` of the public `url` every `sync_interval_seconds` (at least 60) with `substitute` as post-build
  variables (`cluster_name` is always there); `secret_name` names a Secret in the namespace for a
  private repository, synced from the namespace's share of the vault.
- `pod_security` - the Pod Security Standard the namespace is held to where it departs from the defaults;
  `labels` must not set `pod-security.kubernetes.io/*` keys itself.
- `network_policy`, `resource_quota`, `adoption_policy`, `delete_policy` - as in `managed_namespace_defaults`.

See the README, "Managed namespaces".
DESCRIPTION
  nullable    = false

  validation {
    condition = alltrue([
      for namespace in var.managed_namespaces : namespace.owner == null || (
        can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", namespace.owner.team))
        && can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", namespace.owner.cost_center))
        && trimspace(namespace.owner.contact) != ""
      )
    ])
    error_message = "managed_namespaces[*].owner.team and .cost_center must be Kubernetes label values (1 to 63 letters, digits, '-', '_' or '.', starting and ending with a letter or digit), and .contact must not be empty."
  }
  validation {
    condition = alltrue([
      for namespace in var.managed_namespaces : namespace.owner == null || length(setintersection(keys(namespace.labels), ["platform/team", "platform/cost-center"])) == 0
    ])
    error_message = "managed_namespaces[*].labels must not set platform/team or platform/cost-center; owner is where they are set."
  }
  validation {
    condition = alltrue([
      for name in keys(var.managed_namespaces) : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))
    ])
    error_message = "Every key of managed_namespaces must be a Kubernetes namespace name: 1 to 63 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
  # Microsoft documents system namespaces as not on-boardable at all - `kube-system`,
  # `gatekeeper-system`, `istio-system`, `app-routing-system` and the rest. The list is open-ended,
  # so this catches the named ones and the `kube-` prefix Kubernetes reserves; anything else
  # Microsoft adds to it is refused by Azure rather than here.
  validation {
    condition = alltrue([
      for name in keys(var.managed_namespaces) :
      !startswith(name, "kube-") && !contains(["app-routing-system", "gatekeeper-system", "istio-system"], name)
    ])
    error_message = "managed_namespaces names a system namespace. AKS does not allow one to be on-boarded as a managed namespace: not kube-system or anything else starting with \"kube-\", and not app-routing-system, gatekeeper-system or istio-system."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for level in [namespace.pod_security.audit, namespace.pod_security.enforce, namespace.pod_security.warn] :
        level == null || contains(["baseline", "none", "privileged", "restricted"], coalesce(level, ""))
      ]
    ]))
    error_message = "managed_namespaces[*].pod_security.audit, .enforce and .warn must each be one of \"restricted\", \"baseline\", \"privileged\" or \"none\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.pod_security.version == null || can(regex("^(latest|v[0-9]+\\.[0-9]+)$", namespace.pod_security.version))
    ])
    error_message = "managed_namespaces[*].pod_security.version must be \"latest\" or a pinned Kubernetes minor version such as \"v1.31\"."
  }
  # The pod security labels come from pod_security, so that there is one place they are decided and
  # a namespace cannot end up with an enforce label that contradicts what it asked for.
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for key in keys(namespace.labels) : !startswith(key, "pod-security.kubernetes.io/")
      ]
    ]))
    error_message = "managed_namespaces[*].labels must not set a pod-security.kubernetes.io/* label. Use pod_security, which is where the Pod Security Standard of a namespace is decided."
  }
  # The group's object ID is the Kubernetes group name AKS gives its members - not its display name.
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for group in [namespace.groups.view, namespace.groups.edit, namespace.groups.admin] :
        group == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", coalesce(group, "-")))
      ]
    ]))
    error_message = "managed_namespaces[*].groups.view, .edit and .admin must each be the object ID of an Entra ID group, for example \"00000000-0000-0000-0000-000000000000\", or left unset."
  }
  # Each binding is a Flux Kustomization `<namespace>-access-<role>`, and Flux labels what it applies
  # with that name: a label value, 63 characters at most.
  validation {
    condition = alltrue([
      for name, namespace in var.managed_namespaces :
      length(name) <= 48 || alltrue([for group in [namespace.groups.view, namespace.groups.edit, namespace.groups.admin] : group == null])
    ])
    error_message = "A managed namespace with groups must have a name of at most 48 characters: its role bindings are applied by Flux Kustomizations named <namespace>-access-<role>, which Flux uses as a label value."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.adoption_policy == null || contains(["Always", "IfIdentical", "Never"], coalesce(namespace.adoption_policy, ""))
    ])
    error_message = "managed_namespaces[*].adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.delete_policy == null || contains(["Delete", "Keep"], coalesce(namespace.delete_policy, ""))
    ])
    error_message = "managed_namespaces[*].delete_policy must be either \"Delete\" or \"Keep\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.flux == null || can(regex("^https://", namespace.flux.url))
    ])
    error_message = "managed_namespaces[*].flux.url must start with https://."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.flux == null || try(trimspace(namespace.flux.branch) != "", false)
    ])
    error_message = "managed_namespaces[*].flux.branch must not be empty."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.flux == null || try(namespace.flux.sync_interval_seconds >= 60, false)
    ])
    error_message = "managed_namespaces[*].flux.sync_interval_seconds must be at least 60."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.flux == null || try(namespace.flux.secret_name == null || can(regex("^[a-z0-9]([-.a-z0-9]{0,251}[a-z0-9])?$", namespace.flux.secret_name)), false)
    ])
    error_message = "managed_namespaces[*].flux.secret_name must be the name of a Kubernetes Secret: lowercase letters, digits, hyphens and dots, starting and ending with a letter or digit."
  }
  # The tenant's Flux configuration is named after the namespace, next to the cluster's own
  # `platform` - and Azure has one name space for both.
  validation {
    condition     = !contains([for name, namespace in var.managed_namespaces : name if namespace.flux != null], "platform")
    error_message = "managed_namespaces.platform cannot set flux: its Flux configuration would be named `platform`, which is the cluster's own. Name the namespace something else."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for rule in [namespace.network_policy.egress, namespace.network_policy.ingress] :
        rule == null || contains(["AllowAll", "AllowSameNamespace", "DenyAll"], coalesce(rule, ""))
      ]
    ]))
    error_message = "managed_namespaces[*].network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for quantity in [namespace.resource_quota.cpu_limit, namespace.resource_quota.cpu_request] :
        quantity == null || (
          can(regex("^([0-9]+(\\.[0-9]{1,3})?|[0-9]+m)$", quantity))
          && try(tonumber(trimsuffix(quantity, "m")) > 0, false)
        )
      ]
    ]))
    error_message = "managed_namespaces[*].resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities of at least 1 milliCPU, for example \"500m\", \"0.5\" or \"2\". Azure takes the figures in milliCPU, so nothing finer than a milliCPU can be asked for."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for quantity in [namespace.resource_quota.memory_limit, namespace.resource_quota.memory_request] :
        quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", quantity))
      ]
    ]))
    error_message = "managed_namespaces[*].resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
  }
}

variable "network_profile" {
  type = object({
    network_plugin    = optional(string, "azure")
    network_policy    = optional(string, "cilium")
    network_dataplane = optional(string, "cilium")
    load_balancer_sku = optional(string)
    outbound_type     = optional(string, "loadBalancer")
    service_cidr      = optional(string, "100.202.0.0/16")
    dns_service_ip    = optional(string, "100.202.0.10")
  })
  default     = {}
  description = <<DESCRIPTION
Cluster network configuration. Every pod takes a VNet address of its pool's pod subnet (Azure CNI Pod
Subnet with dynamic IP allocation: `pod_subnet_name` and the zones' `pod_subnet_name`). `service_cidr` and
`dns_service_ip` are cluster-internal and must not overlap the cell's address space.
`outbound_type = "userDefinedRouting"` when the cell's subnets route egress through the hub firewall - no
public load balancer is then created.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["azure", "kubenet", "none"], var.network_profile.network_plugin)
    error_message = "network_profile.network_plugin must be one of \"azure\", \"kubenet\" or \"none\"."
  }
  validation {
    condition     = contains(["azure", "calico", "cilium", "none"], var.network_profile.network_policy)
    error_message = "network_profile.network_policy must be one of \"azure\", \"calico\", \"cilium\" or \"none\"."
  }
  validation {
    condition     = contains(["azure", "cilium"], var.network_profile.network_dataplane)
    error_message = "network_profile.network_dataplane must be either \"azure\" or \"cilium\"."
  }
  validation {
    condition     = var.network_profile.network_policy != "cilium" || var.network_profile.network_dataplane == "cilium"
    error_message = "network_profile.network_policy = \"cilium\" requires network_dataplane = \"cilium\"."
  }
  validation {
    condition     = contains(["loadBalancer", "managedNATGateway", "userAssignedNATGateway", "userDefinedRouting"], var.network_profile.outbound_type)
    error_message = "network_profile.outbound_type must be one of \"loadBalancer\", \"managedNATGateway\", \"userAssignedNATGateway\" or \"userDefinedRouting\"."
  }
  validation {
    condition     = var.network_profile.load_balancer_sku == null || contains(["basic", "standard"], coalesce(var.network_profile.load_balancer_sku, "standard"))
    error_message = "network_profile.load_balancer_sku must be either \"basic\" or \"standard\"."
  }
  validation {
    condition     = can(cidrhost(var.network_profile.service_cidr, 0))
    error_message = "network_profile.service_cidr must be a CIDR range, for example \"100.202.0.0/16\"."
  }
  validation {
    condition     = can(cidrhost("${var.network_profile.dns_service_ip}/32", 0))
    error_message = "network_profile.dns_service_ip must be an IPv4 address."
  }
  validation {
    condition = try(
      cidrhost("${var.network_profile.dns_service_ip}/${split("/", var.network_profile.service_cidr)[1]}", 0) == cidrhost(var.network_profile.service_cidr, 0),
      false
    )
    error_message = "network_profile.dns_service_ip must fall inside network_profile.service_cidr."
  }
}

variable "container_registry_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of an existing Azure Container Registry the cluster pulls its images from - an environment's
shared one, see shared/. The kubelet identity is granted `AcrPull` on it, so pods need no image pull
secret. Null for none.
DESCRIPTION
}

variable "persistent_storage_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether the cluster has persistent storage at all. Set to `false` for a stateless cluster: AKS runs
none of its CSI drivers - Azure Disk, Azure Files, Azure Blob - nor the snapshot controller, so the
cluster has no StorageClass and a PersistentVolumeClaim has nothing to be provisioned from. Pods
keep `emptyDir` and the other volumes that live and die with them. Cannot be combined with
`portable_disks_enabled`.
DESCRIPTION
  nullable    = false
}

variable "portable_disks_enabled" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether the platform's `portable-disk` StorageClass creates its disks here, in `resource_group_name`,
rather than in the node resource group AKS deletes with the cluster - so that a disk outlives the
cluster and can be attached to the next one. The cluster identity is granted a role of its own on
`resource_group_name` that covers disks and snapshots and nothing else, and the Flux repository is
told the group as `portable_disk_resource_group_name`.
DESCRIPTION
  nullable    = false

  validation {
    condition     = !var.portable_disks_enabled || var.persistent_storage_enabled
    error_message = "portable_disks_enabled needs persistent_storage_enabled: a cluster without the Azure Disk CSI driver creates no disks."
  }
}

variable "private_cluster_public_fqdn_enabled" {
  type        = bool
  default     = false
  description = "Whether the private API server also gets a public FQDN resolving to its private address."
  nullable    = false
}

variable "private_dns_zone_mode" {
  type        = string
  default     = "system"
  description = <<DESCRIPTION
How the private API server's name resolves (design D58): `system` - an AKS-managed private DNS zone,
linked to the cluster's network only; `none` - no private zone, the public FQDN (`private_cluster_public_fqdn_enabled = true`) resolves to the private address
from anywhere, which suits a network that resolves through a DNS server elsewhere, such as the hub
firewall's DNS proxy (the dev lab behind labfw).
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["system", "none"], var.private_dns_zone_mode)
    error_message = "private_dns_zone_mode must be \"system\" or \"none\"."
  }
  validation {
    condition     = var.private_dns_zone_mode != "none" || var.private_cluster_public_fqdn_enabled
    error_message = "private_dns_zone_mode = \"none\" leaves the API server only its public FQDN to be found by: set private_cluster_public_fqdn_enabled = true."
  }
}

variable "sku_tier" {
  type        = string
  default     = "Standard"
  description = <<DESCRIPTION
Managed cluster SKU tier: `Free`, `Standard` or `Premium`. Defaults to `Standard`, the production
setting (OneK8s design D31): the uptime SLA and API server scaling. `Free` is a non-production
cost saving only - no SLA, the dev lab's choice (see "Non-production cost savings" in its tfvars).
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Free", "Premium", "Standard"], var.sku_tier)
    error_message = "sku_tier must be one of \"Free\", \"Standard\" or \"Premium\"."
  }
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Target subscription. Falls back to `ARM_SUBSCRIPTION_ID` or the current Azure CLI subscription."

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", coalesce(var.subscription_id, "")))
    error_message = "subscription_id must be a GUID."
  }
}

variable "vertical_pod_autoscaler_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether AKS runs the [Vertical Pod Autoscaler][vpa] add-on (`--enable-vpa`): its recommender,
updater and admission controller, and the `VerticalPodAutoscaler` CRD. On in every cluster (OneK8s
design section 2.3, pod right-sizing): each application's `VerticalPodAutoscaler` in its own
repository resizes its pods in place (`updateMode: InPlaceOrRecreate`, Kubernetes 1.35+), within
the bounds stated there. Turning it off removes the add-on and with it every resize; the
`VerticalPodAutoscaler` objects then do nothing.
On is the production setting; off is a non-production cost saving (its components request ~2.4 GiB
on the system pool).

[vpa]: https://learn.microsoft.com/en-us/azure/aks/vertical-pod-autoscaler
DESCRIPTION
  nullable    = false
}

variable "advanced_networking" {
  type = object({
    observability     = optional(bool, true)
    fqdn_policies     = optional(bool, true)
    ebpf_host_routing = optional(bool, true)
  })
  default     = null
  description = <<DESCRIPTION
Advanced Container Networking Services (ACNS) on Azure CNI powered by Cilium. Off by default: OneK8s
does not use ACNS (design D80) - the hub firewall decides egress, Cilium keeps the in-cluster rules at
layers 3 and 4. Each part is an option kept open with a measured trigger (design section 7.4); an
object turns ACNS on with the parts it names (each on unless set to false). eBPF host routing is
decided when the cluster is created.

- `observability` - Hubble flow logs and metrics.
- `fqdn_policies` - Cilium network policies with `toFQDNs` and DNS rules, resolved by the ACNS DNS
  proxy. Without it the fleet's Cilium policies may not use either.
- `ebpf_host_routing` - eBPF host routing (`accelerationMode: BpfVeth`): no iptables in the node's
  network namespace. Every node has to run Azure Linux 3.0 or Ubuntu 24.04 on Kubernetes 1.33 or
  later - set default_node_pool.os_sku.
DESCRIPTION

  validation {
    condition     = var.advanced_networking == null || var.network_profile.network_dataplane == "cilium"
    error_message = "advanced_networking needs network_profile.network_dataplane = \"cilium\". Set advanced_networking = null for another dataplane."
  }
}

variable "customer_managed_keys" {
  type = object({
    key_vault_name                = string
    key_vault_resource_group_name = optional(string)
    key_vault_network_access      = optional(string, "Public")
    # AKS's KMS data encryption (preview, Kubernetes 1.33+): `Private` then needs no API Server VNet
    # Integration - AKS reaches a vault without public network access as a trusted service
    kms_data_encryption = optional(bool, false)
  })
  default     = null
  description = <<DESCRIPTION
Encryption at rest with customer-managed keys - OneK8s design section 18. Two keys of the cluster's
own are created in the vault: `key-<cluster>-kms`, with which the control plane encrypts the
Kubernetes secrets in etcd (KMS), and `key-<cluster>-disk`, the key of a disk encryption set for the
OS disks of every node - the system pool and the zones' pools. Null leaves both to platform-managed keys.

The vault - the environment's platform vault, with purge protection, which a disk encryption set
needs - is reached `Public`ly or `Private`ly. Classic KMS reaches a private vault only with API Server
VNet Integration (which Azure refuses on an encrypted network with v4+ VM sizes, design D58);
`kms_data_encryption = true` turns on AKS's newer KMS data encryption instead (kms.tf), which reaches a
vault without public network access through its trusted services exception. Both settings take
effect only on a new cluster: a cluster created without a disk encryption set has to be built again.
DESCRIPTION

  validation {
    condition     = var.customer_managed_keys == null || contains(["Public", "Private"], try(var.customer_managed_keys.key_vault_network_access, ""))
    error_message = "customer_managed_keys.key_vault_network_access must be Public or Private."
  }
}

variable "exposure" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The cluster's exposure - OneK8s design decision D52: `int` for internal workloads, `ext` for external
ones. Internal and external workloads never share a cluster (or a subscription), so every isolation
zone of the cluster is one of its exposure (`<exposure>-<country>`), an application namespace's
`platform/zone` label names one of them, and only an internal cluster keeps records in the internal
zones' private DNS (internal_dns_zone_names). Told to the Flux repository as `cluster_exposure`.
Null states no exposure and checks nothing (a cluster outside the zone layout).
DESCRIPTION

  validation {
    condition     = var.exposure == null || contains(["int", "ext"], coalesce(var.exposure, "-"))
    error_message = "exposure must be int or ext."
  }
  validation {
    condition     = var.exposure == null || alltrue([for zone in keys(var.isolation_zones) : startswith(zone, "${coalesce(var.exposure, "-")}-")])
    error_message = "Every isolation zone of the cluster must be of its exposure (`<exposure>-<country>`): internal and external zones never share a cluster (design decision D52)."
  }
  validation {
    condition = var.exposure == null || alltrue([
      for namespace in values(var.managed_namespaces) : startswith(lookup(namespace.labels, "platform/zone", "${coalesce(var.exposure, "-")}-"), "${coalesce(var.exposure, "-")}-")
    ])
    error_message = "A managed namespace's platform/zone must be a zone of the cluster's exposure (design decision D52)."
  }
  validation {
    condition     = var.exposure != "ext" || length(var.internal_dns_zone_names) == 0
    error_message = "An external cluster keeps no records in the internal zones' private DNS (design decision D52)."
  }
}

variable "isolation_zones" {
  type = map(object({
    node_subnet_name = string
    pod_subnet_name  = string
  }))
  default     = {}
  description = <<DESCRIPTION
The isolation zones of a stateless cell - OneK8s design section 2.3 - keyed by zone (`ext-fi`): the
subnet of virtual_network_name each zone's node pools (zone_node_pools) join, and the one their pods take
addresses of (shared/'s `snet-<zone>-nodes` and `snet-<zone>-pods`). The cluster is granted the whole
virtual network. All of one exposure (`exposure`).
DESCRIPTION
  nullable    = false
}

variable "zone_node_pools" {
  type = object({
    amd64_vm_size   = optional(string, "Standard_D2alds_v6")
    arm64_vm_size   = optional(string, "Standard_D2pds_v6")
    max_count       = optional(number, 3)
    spot_max_count  = optional(number, 1)
    max_pods        = optional(number, 250)
    os_disk_type    = optional(string, "Ephemeral")
    os_disk_size_gb = optional(number, 64)
  })
  default     = null
  description = <<DESCRIPTION
Classic node pools for the isolation zones, scaled by the cluster autoscaler (node auto provisioning does
not support a pod subnet): per zone `<zone>`, `<zone>spot`, `<zone>arm`
and `<zone>armspot` (the zone without its hyphen), each from 0 to `max_count` (`spot_max_count` for spot)
nodes in the system pool's availability zone, labelled `platform/zone` (and `platform/capacity=spot`) and
tainted alike. The priority expander (the Flux repository's ConfigMap) takes the spot pools first. Null for
a cluster without zones. See the README, "Zone node pools".
DESCRIPTION

  validation {
    condition     = var.zone_node_pools == null || try(var.zone_node_pools.max_count >= 1 && var.zone_node_pools.spot_max_count >= 1, false)
    error_message = "zone_node_pools.max_count and spot_max_count must be at least 1: a pool scales from 0 to them."
  }
  validation {
    condition     = var.zone_node_pools == null || contains(["Ephemeral", "Managed"], try(var.zone_node_pools.os_disk_type, "-"))
    error_message = "zone_node_pools.os_disk_type must be Ephemeral or Managed."
  }
}

variable "key_vault_namespace_vaults" {
  type        = map(string)
  default     = {}
  description = <<DESCRIPTION
The namespaces whose share is in another of the environment's vaults than key_vault_name - an application namespace's in its isolation zone's vault -
keyed by namespace, the vault's name as the value. shared/ makes the grants; the cluster looks the
vault up, federates the namespace's identity, and tells the Flux repository the vault's URL as
`key_vault_url_<namespace>` (hyphens as underscores) - every namespace gets that variable, the ones
in key_vault_name too.
DESCRIPTION
  nullable    = false
}

variable "internal_dns_zone_names" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Azure Private DNS zones in resource_group_name - the internal isolation zones' names, created by
shared/ - in which the cluster's external-dns keeps the records of its internal gateways.
Its identity is granted Private DNS Zone Contributor on each; the Flux repository is told their
resource group as `internal_dns_resource_group_name`.
DESCRIPTION
  nullable    = false
}

variable "log_analytics_workspace_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the environment's Log Analytics workspace (created by shared/, `log-<env>-platform`), where the
cluster sends its Kubernetes audit log through a diagnostic setting - the categories in
audit_log_categories (OneK8s design section 6.2, CIS AKS Benchmark 2.1.1). Null for none.
DESCRIPTION
}

variable "audit_log_categories" {
  type        = list(string)
  default     = ["kube-audit-admin", "guard"]
  description = <<DESCRIPTION
The cluster's resource log categories sent to log_analytics_workspace_name: by default
`kube-audit-admin` (every request that is not a get, list or watch) and `guard` (Entra ID and Azure
RBAC decisions). `kube-audit` adds the reads, at many times the volume.
DESCRIPTION
  nullable    = false

  validation {
    condition     = length(var.audit_log_categories) > 0 && alltrue([for c in var.audit_log_categories : contains(["kube-audit", "kube-audit-admin", "guard", "kube-apiserver", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "cloud-controller-manager", "csi-azuredisk-controller", "csi-azurefile-controller", "csi-snapshot-controller", "fleet-member-agent", "fleet-member-net-controller-manager", "fleet-mcs-controller-manager"], c)])
    error_message = "audit_log_categories must name at least one AKS resource log category, such as kube-audit-admin or guard."
  }
}
