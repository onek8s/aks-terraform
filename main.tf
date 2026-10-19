data "azurerm_client_config" "current" {}

module "conventions" {
  source = "./modules/conventions"

  location             = var.location
  environment          = local.environment
  exposure             = var.exposure
  naming               = var.naming
  key_vault_namespaces = local.key_vault_namespaces
  # The cluster's own resources' names (naming policy, var.naming): its identity - the cluster's name
  # without the environment, which the template puts back where it wants it - and its disk encryption set.
  names = {
    identity            = { type = "user_assigned_identity", name = local.identity_name_part }
    disk_encryption_set = { type = "disk_encryption_set", name = var.name }
  }
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# The cell's network and the system pool's subnet, created by shared/ and looked up here.
data "azurerm_virtual_network" "this" {
  name                = var.virtual_network_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "node" {
  name                 = var.node_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

# The one zone the Gateway's hostnames are published in: public, in Azure DNS, or private, in Azure
# Private DNS (dns_zone_private) - for a domain that only resolves inside the networks the zone is
# linked to. It exists already - shared/ creates it, or it was provisioned outside Terraform - and the
# cluster is only given access to it.
data "azurerm_dns_zone" "this" {
  count = var.dns_zone_name != null && !var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = local.dns_zone_resource_group_name
}

data "azurerm_private_dns_zone" "zone" {
  count = var.dns_zone_name != null && var.dns_zone_private ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = local.dns_zone_resource_group_name
}

# Cluster tags are maintained outside Terraform, by the automation running against the cluster. They
# are read back here and handed to the module unchanged, so that Terraform leaves them alone. Without
# that every plan proposes deleting them, and the resulting update turns every computed cluster
# attribute - FQDN, node resource group, OIDC issuer URL - unknown again. The cluster is listed
# rather than looked up directly, because it does not exist yet on the first apply and a lookup of a
# missing resource is an error.
data "azapi_resource_list" "managed_clusters" {
  parent_id = data.azurerm_resource_group.this.id
  type      = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  response_export_values = {
    tags = "value[?name=='${var.name}'] | [0].tags"
  }
}

# AKS needs an identity that already exists when the cluster is created, so that it can be granted
# access to the network before the first node joins it. A system assigned identity only comes into
# existence together with the cluster.
resource "azurerm_user_assigned_identity" "this" {
  location            = var.location
  name                = local.managed_identity_name
  resource_group_name = var.resource_group_name

  # An identity cannot be renamed in place, so a new name replaces it. Building the replacement
  # first means the cluster is updated from one live identity to another, rather than losing the
  # one it has while the new one is created - which would leave a running cluster unable to reach
  # the network it is attached to. The two names differ, so nothing collides while both exist.
  lifecycle {
    create_before_destroy = true
  }
}

# Lets the cluster join nodes and load balancers to the network: the whole virtual network for a cell
# with zones (their node pools), the system pool's node and pod subnets alone for a cluster without zones - and the route tables of a cell routed through the hub's firewall.
resource "azurerm_role_assignment" "network_contributor" {
  for_each = local.network_role_assignment_scopes

  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  scope                            = each.value
  role_definition_name             = "Network Contributor"
  skip_service_principal_aad_check = true
}

# Azure RBAC is eventually consistent: an assignment can be returned as created and still not be in
# effect when the cluster is created seconds later, which fails the apply with an authorization error
# on the subnet. Waiting once on creation is cheaper than a half-created cluster.
resource "time_sleep" "role_assignment_propagation" {
  create_duration = local.role_assignment_propagation_delay
  triggers = {
    network_contributor = join(",", [for assignment in azurerm_role_assignment.network_contributor : assignment.id])
  }
}

module "aks" {
  # The Azure Verified Module. Image Integrity and KMS data encryption, which it has no inputs for, are
  # set beside it - see image_integrity.tf and kms.tf.
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.5"

  location  = var.location
  name      = var.name
  parent_id = data.azurerm_resource_group.this.id
  # Microsoft Entra ID authentication with Azure RBAC: every call to the Kubernetes API is decided
  # from Azure role assignments on the cluster (entra_admin_group_object_ids and the rest below). The
  # profile's own admin groups are not honored in this mode, which is also what Azure reports for such
  # a cluster: `"adminGroupObjectIds": null`.
  aad_profile = {
    admin_group_object_ids = null
    enable_azure_rbac      = true
    managed                = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
  }
  # Gatekeeper, so that Azure Policy definitions are actually enforced inside the cluster.
  addon_profile_azure_policy = {
    enabled = var.azure_policy_enabled
  }
  # Container Insights stays off: node and pod telemetry is collected by the third party agent that
  # runs inside the cluster. It goes through `addon_profiles_extra` because `addon_profile_oms_agent`
  # insists on a workspace to name even when the add-on is being turned off.
  addon_profiles_extra = {
    omsagent = {
      enabled = false
    }
    # The Secrets Store CSI driver is never used: secrets reach pods only as Kubernetes Secrets
    # written by External Secrets Operator (OneK8s design section 2.5). Stated, so that the add-on
    # cannot be switched on beside Terraform without showing up in the plan.
    azureKeyvaultSecretsProvider = {
      enabled = false
    }
  }
  # A private API server (design D58): over Private Link, with its endpoint in the system pool's subnet.
  api_server_access_profile = {
    enable_private_cluster             = true
    enable_private_cluster_public_fqdn = var.private_cluster_public_fqdn_enabled
    private_dns_zone                   = var.private_dns_zone_mode
  }
  # Azure Monitor managed Prometheus, replaced by the same third party metrics pipeline.
  azure_monitor_profile = {
    metrics = {
      enabled = false
    }
  }
  # The AzAPI provider's 30 minutes are regularly exceeded by a cluster create; Terraform then reports
  # a timeout while Azure carries on, and the cluster is left in `Creating` with nothing in state.
  cluster_timeouts = {
    create = "90m"
    delete = "90m"
    read   = "10m"
    update = "90m"
  }
  default_agent_pool = local.default_agent_pool
  # The zones' classic node pools and their cluster autoscaler - a pod-subnet cell's (zones.tf)
  agent_pools         = local.zone_agent_pools
  auto_scaler_profile = local.auto_scaler_profile
  # Every node's OS disk with the cluster's own key - see encryption.tf.
  disk_encryption_set_id = local.disk_encryption_set_id
  dns_prefix             = var.name
  # Ingress is the Kubernetes Gateway API: AKS installs the managed Gateway API CRDs (standard
  # channel) and, with gateway_implementation = "approuting-istio", App Routing's Gateway API
  # implementation - a sidecar-less Istio control plane serving the GatewayClass `approuting-istio`, no
  # service mesh. With "traefik" it stays off and Traefik is deployed through Flux (traefik.tf). The
  # Gateways themselves, their listeners, load balancers and certificates are deployed through Flux.
  #
  # Every other managed ingress AKS offers stays off: the Application Gateway for Containers ALB
  # Controller add-on and App Routing's NGINX controller. All of it is stated rather than left out,
  # because a cluster that had the ALB Controller add-on only loses it when told to, and because the
  # module cannot validate a partially filled ingress_profile: it reads through the nested objects and
  # fails on the ones left null. Stating the add-on keeps the module on a preview cluster API
  # (2026-03-02-preview), which knows both it and App Routing Istio.
  ingress_profile = {
    application_load_balancer = {
      enabled = false
    }
    gateway_api = {
      installation = "Standard"
    }
    web_app_routing = {
      enabled = false
      gateway_api_implementations = {
        app_routing_istio = {
          mode = var.gateway_implementation == "approuting-istio" ? "Enabled" : "Disabled"
        }
      }
      nginx = {
        default_ingress_controller_type = "None"
      }
    }
  }
  kubernetes_version = var.kubernetes_version
  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = [azurerm_user_assigned_identity.this.id]
  }
  # The AKS cost analysis add-on is not used (design D46): cost per namespace comes from OpenCost.
  # Stated, so that it cannot be switched on beside Terraform without showing up in the plan.
  metrics_profile = {
    cost_analysis = {
      enabled = false
    }
  }
  network_profile = local.network_profile
  sku = {
    name = "Base"
    tier = var.sku_tier
  }
  # Persistent storage, or a stateless cluster without any - see persistent_storage_enabled. The
  # Azure Disk and Azure Files CSI drivers and the snapshot controller are stated either way, so
  # turning storage back on is a change Terraform sees. The Azure Blob driver, off unless asked for,
  # is only turned off explicitly on a stateless cluster and otherwise left to AKS.
  storage_profile = {
    blob_csi_driver = var.persistent_storage_enabled ? null : {
      enabled = false
    }
    disk_csi_driver = {
      enabled = var.persistent_storage_enabled
    }
    file_csi_driver = {
      enabled = var.persistent_storage_enabled
    }
    snapshot_controller = {
      enabled = var.persistent_storage_enabled
    }
  }
  tags = local.cluster_tags
  # The Vertical Pod Autoscaler add-on - see vertical_pod_autoscaler_enabled. KEDA is left to AKS.
  workload_auto_scaler_profile = {
    vertical_pod_autoscaler = {
      enabled = var.vertical_pod_autoscaler_enabled
    }
  }

  disable_local_accounts = true
  # Workload identity federates Kubernetes service accounts with Entra ID, which only works when the
  # cluster publishes an OIDC issuer. Azure rejects the one without the other, and the
  # `oidc_issuer_url` output stays null until the issuer is on.
  oidc_issuer_profile = {
    enabled = true
  }
  security_profile = {
    # KMS: the Kubernetes secrets in etcd encrypted with the cluster's own key - see encryption.tf.
    azure_key_vault_kms = local.azure_key_vault_kms
    # Defender for Containers is off, like the rest of the Azure monitoring stack. Stated rather
    # than left out, because a subscription with the Defender for Containers plan and its
    # auto-provisioning on turns the agent on by itself.
    defender = {
      security_monitoring = {
        enabled = false
      }
    }
    image_cleaner = {
      enabled        = true
      interval_hours = 168
    }
    # Federates Kubernetes service accounts with Entra ID. External Secrets Operator and external-dns
    # authenticate to Azure this way - see the identities below.
    workload_identity = {
      enabled = true
    }
  }

  auto_upgrade_profile = {
    node_os_upgrade_channel = var.auto_upgrade.node_os_channel
    upgrade_channel         = var.auto_upgrade.kubernetes_channel
  }
  depends_on = [
    azurerm_role_assignment.network_contributor,
    time_sleep.role_assignment_propagation,
    azurerm_role_assignment.disk_encryption_set_key,
    azurerm_role_assignment.cluster_customer_managed_keys,
    time_sleep.customer_managed_keys_propagation,
  ]
}

# Cluster admin for the Entra ID groups that are meant to have it. `Azure Kubernetes Service RBAC
# Cluster Admin` is the Azure role that answers to `cluster-admin` inside the cluster. It does not let
# anyone download a kubeconfig: that takes `Azure Kubernetes Service Cluster User Role` on the cluster,
# which is a control plane role and is not created here.
resource "azurerm_role_assignment" "entra_cluster_admin" {
  for_each = toset(var.entra_admin_group_object_ids)

  principal_id         = each.value
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  # Stated, so that Azure takes the object ID as given rather than looking the principal up: a group
  # created moments ago has not replicated everywhere yet, and the assignment fails on a principal
  # Azure cannot find.
  principal_type = "Group"
}

# Read-only access for the Entra ID groups that only need to look. `Azure Kubernetes Service RBAC
# Reader` reads most objects in every namespace, but not `Secrets` - reading those is a way to act
# as any service account in the namespace - and not roles or role bindings.
resource "azurerm_role_assignment" "entra_reader" {
  for_each = toset(var.entra_reader_group_object_ids)

  principal_id         = each.value
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_type       = "Group"
}

# The identity external-dns publishes the Gateway's hostnames as, federated with the Kubernetes
# service account that acts as it (local.external_dns_service_account). Named after the cluster
# identity with what it does appended, and created only for a zone that is named. The identities
# that read Key Vault, one per namespace, are in key_vault.tf.
#
# external-dns keeps an A record in each zone for every hostname a Gateway listener serves in it.
resource "azurerm_user_assigned_identity" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  location            = var.location
  name                = "${local.managed_identity_name}-dns"
  resource_group_name = var.resource_group_name
}

resource "azurerm_federated_identity_credential" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name                      = "aks-${var.name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.external_dns[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = local.external_dns_service_account
}

resource "azurerm_role_assignment" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
  scope                = local.dns_zone_id
  role_definition_name = var.dns_zone_private ? "Private DNS Zone Contributor" : "DNS Zone Contributor"
  principal_type       = "ServicePrincipal"
}

# Portable disks: the platform's `portable-disk` StorageClass creates its disks in resource_group_name
# rather than in the node resource group AKS deletes with the cluster, so a disk outlives the cluster
# and can be attached to the next one in the environment. The Azure Disk CSI driver acts as the
# cluster identity, which AKS grants what it needs in the node resource group only.
#
# The grant here is a role of the cluster's own that covers disks and snapshots and nothing else:
# resource_group_name holds the environment's other cluster too, its identities and the shared Key
# Vault, and Contributor - what Microsoft documents for a disk outside the node resource group -
# would let one cluster change all of them. Attaching a disk is a write on the node's VM, which AKS
# has granted already.
resource "azurerm_role_definition" "portable_disks" {
  count = var.portable_disks_enabled ? 1 : 0

  name        = "Portable disks (${var.name})"
  scope       = data.azurerm_resource_group.this.id
  description = "Lets the Azure Disk CSI driver of ${var.name} create, attach, snapshot and delete the disks of persistent volumes in ${var.resource_group_name}."

  permissions {
    actions = [
      "Microsoft.Compute/disks/*",
      "Microsoft.Compute/snapshots/*",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]
  }

  assignable_scopes = [data.azurerm_resource_group.this.id]
}

resource "azurerm_role_assignment" "portable_disks" {
  count = var.portable_disks_enabled ? 1 : 0

  principal_id       = azurerm_user_assigned_identity.this.principal_id
  scope              = data.azurerm_resource_group.this.id
  role_definition_id = azurerm_role_definition.portable_disks[0].role_definition_resource_id
  principal_type     = "ServicePrincipal"
}

# Pods and services on a range that also belongs to the cell's network have nowhere to route to.
# Azure creates the cluster regardless and the damage only shows once something tries to talk across
# it, so this is checked before the apply rather than discovered afterwards. The ranges cannot be
# changed after the cluster is created.
check "cluster_cidrs_do_not_overlap_the_network" {
  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "The cluster-internal ranges of ${var.name} collide with the address space of ${var.virtual_network_name}: ${join(", ", local.overlapping_cluster_cidrs)}. Move network_profile.service_cidr out of the way."
  }
}

# A managed namespace that restricts ingress or egress writes a Kubernetes `NetworkPolicy`, and a
# `NetworkPolicy` in a cluster with nothing to enforce it is an object nobody reads: the namespace
# looks closed in Azure and every pod in the cluster can still reach into it. Terraform warns rather
# than refuses, because a cluster can legitimately run its own policy engine - Cilium installed by
# hand, say - which `network_profile.network_policy` knows nothing about.
check "managed_namespaces_have_something_enforcing_their_network_policies" {
  assert {
    condition     = var.network_profile.network_policy != "none" || length(local.managed_namespaces_relying_on_network_policy) == 0
    error_message = "${var.name} has network_profile.network_policy = \"none\", so nothing in it enforces a Kubernetes NetworkPolicy - and the restricted default policies of ${join(", ", local.managed_namespaces_relying_on_network_policy)} are written but never applied. Set network_profile.network_policy to \"cilium\", \"azure\" or \"calico\", or set network_policy = { egress = \"AllowAll\", ingress = \"AllowAll\" } on those namespaces to say that the boundary is drawn somewhere else."
  }
}

# An exception to the estate-wide Pod Security Standard is a normal thing to need - a monitoring
# agent wants the host network, a build runner wants a privileged container - and stating it on the
# namespace is how it is meant to be done. Turning off `audit` and `warn` along with `enforce` is
# what this warns about: the namespace then runs whatever it likes, nothing is refused, and nothing
# anywhere records that it happened. Leave one of the two at the estate standard and the exception
# stays visible in the audit log without blocking the workload.
check "pod_security_exceptions_stay_on_the_record" {
  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "${join(", ", local.managed_namespaces_with_silent_pod_security_exceptions)} of ${var.name} enforce${length(local.managed_namespaces_with_silent_pod_security_exceptions) == 1 ? "s" : ""} a weaker Pod Security Standard than managed_namespace_defaults.pod_security.enforce (${var.managed_namespace_defaults.pod_security.enforce}) and audit or warn nothing at that standard either, so a pod that breaks it is neither refused nor recorded. Leave pod_security.audit or pod_security.warn at \"${var.managed_namespace_defaults.pod_security.enforce}\" on those namespaces."
  }
}

# The role bindings of managed_namespaces[*].groups live inside the cluster and are applied by the
# cluster's Flux configuration; a cluster without one gets the namespaces and no bindings in them.
check "namespace_groups_need_flux" {
  assert {
    condition     = local.flux_enabled || length(local.managed_namespace_role_bindings) == 0
    error_message = "${var.name} has no flux_git_repository, so the ${length(local.managed_namespace_role_bindings)} role binding(s) of managed_namespaces[*].groups are not applied: they are delivered by the cluster's Flux configuration. Set flux_git_repository, or bind those groups inside the cluster some other way."
  }
}

# The Flux webhook's Receiver is reconciled by the cluster's Flux repository, reads its token from the
# vault and is reached by GitHub through the platform gateway.
check "flux_github_webhook_has_a_repository_a_vault_and_a_gateway" {
  assert {
    condition     = !var.flux_github_webhook || (local.flux_github_webhook_enabled && var.gateway_implementation != null)
    error_message = "${var.name} asks for a Flux GitHub webhook, but it has ${!local.flux_enabled ? "no flux_git_repository to reconcile" : !local.key_vault_enabled ? "no key_vault_name to read its token from" : "no gateway_implementation for the platform gateway GitHub reaches it through"}."
  }
}

# The upgrade windows. Azure fixes the three names: `default` covers the weekly AKS release of the
# control plane and add-ons, `aksManagedAutoUpgradeSchedule` the Kubernetes version upgrade driven by
# `upgrade_channel`, and `aksManagedNodeOSUpgradeSchedule` the node image patching driven by
# `node_os_upgrade_channel`. The windows are identical and therefore overlap, which is allowed - AKS
# picks the order it runs them in.
#
# These are written directly instead of through the module, because the module always sends a
# `startDate` - null when it is not set - while Azure answers with the date the configuration was
# created. That difference turns up as an update in every subsequent plan, and Azure rejects a
# request carrying a startDate that has since fallen into the past, so the value cannot simply be
# pinned either. AzAPI only tracks the properties the body declares, so leaving startDate out keeps
# it entirely server-side: the window activates immediately, which is what an unset startDate means.
resource "azapi_resource" "maintenance_configuration" {
  for_each = toset(["aksManagedAutoUpgradeSchedule", "aksManagedNodeOSUpgradeSchedule", "default"])

  name      = each.key
  parent_id = module.aks.resource_id
  type      = "Microsoft.ContainerService/managedClusters/maintenanceConfigurations@${local.aks_api_version}"
  body = {
    properties = {
      maintenanceWindow = {
        durationHours = var.maintenance_window.duration_hours
        schedule = {
          weekly = {
            dayOfWeek     = var.maintenance_window.day_of_week
            intervalWeeks = var.maintenance_window.interval_weeks
          }
        }
        startTime = var.maintenance_window.start_time
        utcOffset = var.maintenance_window.utc_offset
      }
    }
  }
  # AzAPI's embedded AKS schema does not cover that API version yet. Azure still validates it.
  schema_validation_enabled = false

  # After the whole module, like the Flux extension: AKS runs one operation on a cluster at a time.
  depends_on = [module.aks]
}

# GitOps through Flux, for a cluster that names a repository in flux_git_repository, or a managed
# namespace that names one in `flux`. The extension installs the Flux controllers into `flux-system`
# and keeps them on the newest minor version of the stable release train; the configuration points
# them at the repository and reconciles the one Kustomization the cluster's main configuration lives in.
#
# The module has no input for cluster extensions, so both are written here with AzAPI, like the
# upgrade windows and the namespaces.
resource "azapi_resource" "flux_extension" {
  count = local.flux_extension_enabled ? 1 : 0

  name      = "flux"
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/extensions@${local.kubernetes_configuration_api_version}"
  body = {
    properties = merge({
      autoUpgradeMinorVersion = true
      extensionType           = "microsoft.flux"
      releaseTrain            = "Stable"
      scope = {
        cluster = {
          releaseNamespace = "flux-system"
        }
      }
      },
      # On a system pool tainted CriticalAddonsOnly, the Flux controllers tolerate it - they belong to
      # the platform and run there, never on an isolation zone's nodes.
      local.system_pool_critical_addons_only ? {
        configurationSettings = {
          "toleration-keys" = "CriticalAddonsOnly"
        }
    } : {})
  }

  # AKS runs one operation on a cluster at a time and refuses the next with "Another operation is
  # in progress". parent_id waits only for the cluster itself, not for what the module does to it
  # afterwards - its update of the system node pool - so on a new cluster the two ran at once and
  # the pool's update failed. Waiting for the whole module keeps them apart.
  depends_on = [module.aks]
}

# The platform's repositories are public: no credential is sent. `prune` lets Flux delete what was
# removed from the repository, so the cluster follows the repository rather than accumulating
# everything it ever contained.
resource "azapi_resource" "flux_configuration" {
  count = local.flux_enabled ? 1 : 0

  name      = "platform"
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = local.flux_configuration_body

  depends_on = [azapi_resource.flux_extension]
}

# The role bindings of a managed namespace's groups - see managed_namespace_access_flux_configurations.
# Named `<namespace>-access`; its Kustomizations are `<namespace>-access-<role>` in flux-system.
resource "azapi_resource" "managed_namespace_access_flux_configuration" {
  for_each = local.managed_namespace_access_flux_configurations

  name      = "${each.key}-access"
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = each.value

  # The namespace is there before a binding is put into it.
  depends_on = [azapi_resource.flux_extension, azapi_resource.managed_namespace]
}

# A tenant: a managed namespace that deploys itself from a repository of its own - see
# managed_namespace_flux_configurations. One configuration per namespace, so each team's sync status
# is a resource of its own in the portal's GitOps view rather than buried in the platform's.
resource "azapi_resource" "managed_namespace_flux_configuration" {
  for_each = local.managed_namespace_flux_configurations

  name      = each.key
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = each.value

  # The namespace is AKS's to create, with its quota and default policies, before Flux puts anything
  # in it.
  depends_on = [azapi_resource.flux_extension, azapi_resource.managed_namespace]
}

# The namespaces AKS creates and keeps inside the cluster. A managed namespace is an Azure resource
# rather than a `kubectl apply`: AKS reconciles the Kubernetes namespace, the default `NetworkPolicy`
# and the default `ResourceQuota` from it, so a namespace survives being deleted by hand inside the
# cluster and Azure RBAC can be scoped to it. That is why they are here rather than left to whatever
# deploys workloads: the boundary a namespace draws is set up before anything lands in it.
#
# Every namespace closes ingress to its own namespace and leaves egress open unless it says
# otherwise - see managed_namespace_defaults. These are the *default* policies of the namespace, not
# a ceiling: Kubernetes network policies are additive, so a policy applied inside the namespace can
# only widen what these permit.
#
# Written with AzAPI rather than through the module's own namespace submodule for the same reason
# the upgrade windows are: that submodule writes every property into the body, including the ones a
# namespace does not set, while AzAPI tracks only what the body declares - so a namespace that sets
# no labels or annotations sends none rather than sending null and differing from whatever Azure
# answers with. The quota is not one of those: Azure requires it on every managed namespace, which
# is why one is always sent - see managed_namespace_resource_quota_inputs.
resource "azapi_resource" "managed_namespace" {
  for_each = local.managed_namespace_properties

  location  = var.location
  name      = each.key
  parent_id = module.aks.resource_id
  type      = "Microsoft.ContainerService/managedClusters/managedNamespaces@${local.aks_api_version}"
  body = {
    properties = each.value
  }
  # AzAPI's embedded AKS schema does not cover that API version yet. Azure still validates it.
  schema_validation_enabled = false

  # After the whole module, like the Flux extension: AKS runs one operation on a cluster at a time.
  depends_on = [module.aks]
}

# A kubeconfig for the namespace alone, for the groups of `managed_namespaces[*].groups`: `Azure
# Kubernetes Service Namespace User` on the namespace resource lets a member run `az aks namespace
# get-credentials` and reach that one namespace, with the rights the group's RoleBinding gives it there
# - no cluster-wide grant at all, which is the point of managing namespaces here.
resource "azurerm_role_assignment" "managed_namespace" {
  for_each = local.managed_namespace_user_grants

  principal_id         = each.value.group_object_id
  scope                = azapi_resource.managed_namespace[each.value.namespace].id
  role_definition_name = "Azure Kubernetes Service Namespace User"
  # Stated for the same reason it is on the cluster grants: a group created moments ago has not
  # replicated everywhere yet, and Azure fails an assignment to a principal it cannot look up.
  principal_type = "Group"
}
