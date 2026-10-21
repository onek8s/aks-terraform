# Plan-time behaviour of the root module, exercised without touching Azure: the providers are
# mocked, so `terraform test` needs no subscription and no credentials.
#
#   terraform test

# The mocked IDs have to look real: the azurerm provider parses them while it builds the plan and
# rejects the random strings a bare mock hands it.
mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      address_space = ["172.19.0.0/16"]
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
    }
  }
  mock_data "azurerm_subnet" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-nodes"
      address_prefixes = ["172.19.0.0/24"]
    }
  }
  mock_data "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.azmk8s.io"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "66666666-6666-6666-6666-666666666666"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-aks-test"
      vault_uri = "https://kv-aks-test.vault.azure.net/"
    }
  }
  mock_data "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-sec-test-shared"
      vault_uri = "https://kv-sec-test-shared.vault.azure.net/"
    }
  }
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example"
      principal_id = "77777777-7777-7777-7777-777777777777"
      client_id    = "88888888-8888-8888-8888-888888888888"
    }
  }
  mock_data "azurerm_dns_zone" {
    defaults = {
      id = "/subscriptions/55555555-5555-5555-5555-555555555555/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/contoso.com"
    }
  }
  mock_resource "azurerm_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/dnsZones/contoso.com"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/privateDnsZones/internal.contoso.com"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-test-identity"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}
mock_provider "azapi" {}
mock_provider "time" {}

# The cluster module brings its own providers and its own registry lookups; none of that is under
# test here, so it is replaced by the outputs the root module reads back.
override_module {
  target = module.aks
  outputs = {
    kubelet_identity = {
      clientId   = "77777777-7777-7777-7777-777777777777"
      objectId   = "88888888-8888-8888-8888-888888888888"
      resourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mc_rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-test-agentpool"
    }
    resource_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    oidc_issuer_profile_issuer_url = "https://swedencentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
  }
}

variables {
  location             = "swedencentral"
  name                 = "aks-test"
  node_subnet_name     = "snet-aks-nodes"
  pod_subnet_name      = "snet-system-pods"
  resource_group_name  = "rg-aks-test"
  virtual_network_name = "vnet-aks-test"
}

# ----------------------------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------------------------

run "default_cluster_is_private_and_scoped_to_its_node_subnet" {
  command = plan

  assert {
    condition     = sort(keys(azurerm_role_assignment.network_contributor)) == tolist(["node_subnet", "pod_subnet"])
    error_message = "A cluster without zones should get Network Contributor on its node and pod subnets alone."
  }
  assert {
    condition     = azurerm_role_assignment.network_contributor["node_subnet"].scope == data.azurerm_subnet.node.id
    error_message = "The assignment should be scoped to the node subnet, not to the virtual network."
  }
  assert {
    condition     = time_sleep.role_assignment_propagation.create_duration == "60s"
    error_message = "Creating role assignments should also wait for them to propagate."
  }
}

# id-<region code>-<environment>-<function>, worked out rather than stated: the environment is
# lifted out of the cluster name and put in front of what the cluster is.
run "the_identity_name_is_built_from_the_cluster_name_and_the_region" {
  command = plan

  variables {
    name = "aks-prototype-a"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prototype-aks-a"
    error_message = "aks-prototype-a in swedencentral should be run by id-sec-prototype-aks-a."
  }
}

run "a_cluster_is_named_apart_from_its_sibling" {
  command = plan

  variables {
    name = "aks-prototype-stateful"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prototype-aks-stateful"
    error_message = "Two clusters in one environment must not end up sharing an identity name."
  }
}

run "a_cluster_name_with_nothing_after_the_environment_keeps_the_short_form" {
  command = plan

  variables {
    name = "aks-prod"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prod-aks"
    error_message = "A name with no distinguishing tail should stop after the function."
  }
}

run "a_cluster_name_with_nothing_to_split_has_no_environment_to_lift" {
  command = plan

  variables {
    name = "cluster"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-cluster"
    error_message = "A single segment name has no environment, so the name follows the region directly."
  }
}

run "the_region_follows_the_location" {
  command = plan

  variables {
    location = "westeurope"
    name     = "aks-prod-main"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-euw-prod-aks-main"
    error_message = "The region code should come from location, not from swedencentral by habit."
  }
}

# The estate's naming policy (modules/conventions) names the cluster's own resources; the defaults
# above are the lab's.
run "the_naming_policy_names_the_identity_and_the_disk_encryption_set" {
  command = plan

  variables {
    name = "aks-prototype-a"
    naming = {
      location_codes = { swedencentral = "se1" }
      templates = {
        user_assigned_identity = "mi-{location_code}-{environment}-{name}"
        disk_encryption_set    = "des-{location_code}-{environment}-{name}"
      }
    }
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "mi-se1-prototype-aks-a" && output.names.disk_encryption_set == "des-se1-prototype-aks-prototype-a"
    error_message = "The policy's templates and region codes should name the cluster's identity and disk encryption set."
  }
}

# A naming policy may name clusters without the environment in the second segment: then the
# environment is stated, and the whole cluster name is the identity's `{name}`.
run "an_environment_stated_apart_from_the_cluster_name" {
  command = plan

  variables {
    name        = "k8s-weu-p-01"
    environment = "prd"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prd-k8s-weu-p-01"
    error_message = "A stated environment goes into the names; the cluster name stays whole."
  }
}

run "refuses_a_naming_policy_with_an_unknown_placeholder" {
  command = plan

  variables {
    naming = { templates = { traffic_manager_profile = "tm-{region}" } }
  }

  expect_failures = [output.names]
}

# Guessing a code for an unknown region would put an off-convention name on a real identity.
run "refuses_a_region_with_no_short_code" {
  command = plan

  variables {
    location = "moonbase1"
  }

  expect_failures = [output.names]
}

run "base_keeps_the_subnet_scoped_assignments" {
  command = plan

  assert {
    condition     = sort(keys(azurerm_role_assignment.network_contributor)) == tolist(["node_subnet", "pod_subnet"])
    error_message = "A cluster without zones should keep the least privilege subnet assignment."
  }
}

run "base_keeps_its_node_pool_settings" {
  command = plan

  variables {
    default_node_pool = {
      vm_size             = "Standard_B2s"
      enable_auto_scaling = false
      node_count          = 1
    }
  }

  assert {
    condition = alltrue([
      local.default_agent_pool.vm_size == "Standard_B2s",
      local.default_agent_pool.count_of == 1,
      local.default_agent_pool.enable_auto_scaling == false,
      local.default_agent_pool.type == "VirtualMachineScaleSets",
      local.default_agent_pool.upgrade_settings.max_surge == "10%",
    ])
    error_message = "The cluster should be sent the node pool it asked for."
  }
}

# Pod right-sizing (OneK8s design section 2.3): the VPA add-on is on unless a cluster says otherwise,
# so the applications' VerticalPodAutoscalers in InPlaceOrRecreate mode have something to act on.
run "the_vpa_add_on_is_on_by_default" {
  command = plan

  assert {
    condition     = var.vertical_pod_autoscaler_enabled
    error_message = "Every cluster should run the VPA add-on unless told otherwise."
  }
}

run "the_vpa_add_on_can_be_turned_off" {
  command = plan

  variables {
    vertical_pod_autoscaler_enabled = false
  }

  assert {
    condition     = var.vertical_pod_autoscaler_enabled == false
    error_message = "vertical_pod_autoscaler_enabled = false should be sent, so AKS removes the add-on."
  }
}

run "the_cluster_ranges_are_the_configured_ones" {
  command = plan

  assert {
    condition     = local.cluster_cidrs == ["100.202.0.0/16"]
    error_message = "The cluster is sent the network profile it asked for."
  }
}

run "an_address_space_clear_of_the_cluster_ranges_raises_nothing" {
  command = plan

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "100.202.0.0/16 does not overlap 172.19.0.0/16."
  }
}

# A shorter prefix on either side still counts as an overlap.
run "warns_when_a_supernet_of_the_cluster_ranges_is_in_use" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.this
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["100.200.0.0/14"]
    }
  }

  expect_failures = [check.cluster_cidrs_do_not_overlap_the_network]
}

# An IPv6 range is skipped rather than compared against an IPv4 one.
run "an_ipv6_address_space_is_not_compared_against_the_ipv4_ranges" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.this
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["fd00::/48", "172.19.0.0/16"]
    }
  }

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "An IPv6 range should neither match an IPv4 one nor break the comparison."
  }
}

# ----------------------------------------------------------------------------------------------
# Upgrade windows
# ----------------------------------------------------------------------------------------------

run "upgrade_windows_cover_all_three_schedules_and_send_no_start_date" {
  command = plan

  assert {
    condition = toset(keys(azapi_resource.maintenance_configuration)) == toset([
      "aksManagedAutoUpgradeSchedule",
      "aksManagedNodeOSUpgradeSchedule",
      "default",
    ])
    error_message = "Azure fixes the three maintenance configuration names; all three should be managed."
  }
  assert {
    condition = alltrue([
      for configuration in azapi_resource.maintenance_configuration :
      !contains(keys(configuration.body.properties.maintenanceWindow), "startDate")
    ])
    error_message = "Sending a startDate makes every later plan propose an update, so it must stay out of the body."
  }
  assert {
    condition     = azapi_resource.maintenance_configuration["default"].body.properties.maintenanceWindow.durationHours == 8
    error_message = "The window should carry the configured duration."
  }
}

# ----------------------------------------------------------------------------------------------
# Flux
# ----------------------------------------------------------------------------------------------

run "a_cluster_without_a_flux_repository_gets_no_flux" {
  command = plan

  assert {
    condition     = length(azapi_resource.flux_extension) + length(azapi_resource.flux_configuration) == 0
    error_message = "Flux should only be installed when flux_git_repository is set."
  }
}

run "a_flux_repository_installs_flux_and_syncs_it" {
  command = plan

  variables {
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition     = azapi_resource.flux_extension[0].body.properties.extensionType == "microsoft.flux"
    error_message = "The extension should be Flux."
  }
  assert {
    condition     = azapi_resource.flux_extension[0].body.properties.scope.cluster.releaseNamespace == "flux-system"
    error_message = "Flux should be installed cluster-wide into flux-system."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.gitRepository.url == "https://github.com/example/cluster-config"
    error_message = "The configuration should sync the configured repository."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.gitRepository.repositoryRef.branch == "main"
    error_message = "The branch should default to main."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.path == "./clusters/aks-test"
    error_message = "The Kustomization should reconcile the configured path."
  }
}

run "the_flux_repository_is_read_without_a_credential" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = !contains(keys(azapi_resource.flux_configuration[0].body.properties.gitRepository), "httpsUser") && azapi_resource.flux_configuration[0].sensitive_body == null
    error_message = "The platform's repositories are public: no user and no protected settings are sent."
  }
}

run "rejects_a_flux_repository_url_without_a_scheme" {
  command = plan

  variables {
    flux_git_repository = {
      url = "github.com/example/cluster-config"
    }
  }

  expect_failures = [var.flux_git_repository]
}

run "the_entra_groups_are_granted_on_the_cluster" {
  command = plan

  variables {
    entra_admin_group_object_ids  = ["22222222-2222-2222-2222-222222222222"]
    entra_reader_group_object_ids = ["33333333-3333-3333-3333-333333333333"]
  }

  assert {
    condition     = keys(azurerm_role_assignment.entra_cluster_admin) == ["22222222-2222-2222-2222-222222222222"]
    error_message = "Each admin group should get an assignment of its own."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin"
    error_message = "Cluster admin under Azure RBAC is the Azure Kubernetes Service RBAC Cluster Admin role."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    error_message = "The grant belongs on the cluster, not on the resource group around it."
  }
  assert {
    condition     = azurerm_role_assignment.entra_reader["33333333-3333-3333-3333-333333333333"].role_definition_name == "Azure Kubernetes Service RBAC Reader"
    error_message = "Read-only access under Azure RBAC is the Azure Kubernetes Service RBAC Reader role."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].principal_type == "Group"
    error_message = "The principal is a group, and saying so keeps Azure from looking one up that has not replicated yet."
  }
}

run "a_cluster_with_no_entra_groups_grants_nothing" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0 && length(azurerm_role_assignment.entra_reader) == 0
    error_message = "Nothing should be granted to groups that were never named."
  }
}

run "rejects_a_cluster_name_azure_would_refuse" {
  command = plan

  variables {
    name = "aks_test!"
  }

  expect_failures = [var.name]
}

run "rejects_a_dns_service_ip_outside_the_service_cidr" {
  command = plan

  variables {
    network_profile = {
      service_cidr   = "100.202.0.0/16"
      dns_service_ip = "100.203.0.10"
    }
  }

  expect_failures = [var.network_profile]
}

run "rejects_cilium_network_policy_on_the_azure_dataplane" {
  command = plan

  variables {
    advanced_networking = null
    network_profile = {
      network_policy    = "cilium"
      network_dataplane = "azure"
    }
  }

  expect_failures = [var.network_profile]
}

run "rejects_an_entra_group_name_where_an_object_id_belongs" {
  command = plan

  variables {
    entra_admin_group_object_ids = ["aks-admins"]
  }

  expect_failures = [var.entra_admin_group_object_ids]
}

run "rejects_an_entra_reader_group_name_where_an_object_id_belongs" {
  command = plan

  variables {
    entra_reader_group_object_ids = ["aks-readers"]
  }

  expect_failures = [var.entra_reader_group_object_ids]
}

run "rejects_a_max_surge_azure_cannot_read" {
  command = plan

  variables {
    default_node_pool = {
      max_surge = "10 percent"
    }
  }

  expect_failures = [var.default_node_pool]
}

run "rejects_a_pinned_version_the_upgrade_channel_would_move_past" {
  command = plan

  variables {
    kubernetes_version = "1.32"
    auto_upgrade = {
      kubernetes_channel = "stable"
    }
  }

  expect_failures = [var.auto_upgrade]
}

run "rejects_patch_upgrades_of_an_exactly_pinned_version" {
  command = plan

  variables {
    kubernetes_version = "1.32.4"
    auto_upgrade = {
      kubernetes_channel = "patch"
    }
  }

  expect_failures = [var.auto_upgrade]
}

run "accepts_patch_upgrades_of_a_minor_version_pin" {
  command = plan

  variables {
    kubernetes_version = "1.32"
    auto_upgrade = {
      kubernetes_channel = "patch"
    }
  }
}

run "rejects_a_kubernetes_version_with_a_leading_v" {
  command = plan

  variables {
    kubernetes_version = "v1.32"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_a_maintenance_window_too_short_to_upgrade_in" {
  command = plan

  variables {
    maintenance_window = {
      duration_hours = 2
    }
  }

  expect_failures = [var.maintenance_window]
}

# A bring-your-own private DNS zone is still reachable without a network of your own - it is the
# private cluster that needs it, not the subnets - so the grant on the zone survives.
run "a_private_cluster_without_a_private_dns_zone_resolves_by_its_public_fqdn" {
  command = plan

  variables {
    private_dns_zone_mode               = "none"
    private_cluster_public_fqdn_enabled = true
  }

  assert {
    condition     = var.private_dns_zone_mode == "none" && var.private_cluster_public_fqdn_enabled
    error_message = "private_dns_zone_mode none hands AKS \"none\" and the public FQDN names the private address."
  }
}

run "no_private_dns_zone_needs_the_public_fqdn" {
  command = plan

  variables {
    private_dns_zone_mode               = "none"
    private_cluster_public_fqdn_enabled = false
  }

  expect_failures = [var.private_dns_zone_mode]
}

run "a_cluster_with_no_managed_namespaces_creates_none" {
  command = plan

  assert {
    condition     = length(azapi_resource.managed_namespace) == 0
    error_message = "Namespaces are opt-in; an environment that lists none should get none."
  }
}

# Listing the names is the whole of it: everything else comes from managed_namespace_defaults.
run "a_namespace_closes_ingress_to_itself_and_leaves_egress_open" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
      team-search   = {}
    }
  }

  assert {
    condition     = toset(keys(azapi_resource.managed_namespace)) == toset(["team-payments", "team-search"])
    error_message = "Every name listed in managed_namespaces should get a namespace of its own."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].name == "team-payments"
    error_message = "The namespace is named by the key, not by anything derived from it."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].parent_id == module.aks.resource_id
    error_message = "A managed namespace belongs to the cluster."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].type == "Microsoft.ContainerService/managedClusters/managedNamespaces@2026-05-02-preview"
    error_message = "The namespace should use the same AKS API version as everything else written directly."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    ])
    error_message = "By default only pods of the same namespace should be able to reach into it."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.defaultNetworkPolicy.egress == "AllowSameNamespace"
    ])
    error_message = "By default a workload should reach nothing in another namespace."
  }
}

# What a namespace says nothing about is left out of the body rather than sent as null: AzAPI tracks
# only the keys the body declares, and a key sent as null differs from whatever Azure answers with.
# The quota is the exception - Azure requires one - and has a run of its own further down.
run "a_namespace_nobody_gave_labels_to_is_sent_none" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  # The pod security labels are always there - a namespace is held to the estate standard whether or
  # not it says anything - so what is checked here is that nothing else came along with them.
  assert {
    condition = toset(keys(azapi_resource.managed_namespace["team-payments"].body.properties.labels)) == toset([
      "pod-security.kubernetes.io/audit",
      "pod-security.kubernetes.io/audit-version",
      "pod-security.kubernetes.io/enforce",
      "pod-security.kubernetes.io/enforce-version",
      "pod-security.kubernetes.io/warn",
      "pod-security.kubernetes.io/warn-version",
    ])
    error_message = "No labels were asked for, so only the pod security ones should be sent."
  }
  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.annotations)
    error_message = "No annotations were asked for, so none should be sent."
  }
}

# Nothing is deleted or taken over behind anyone's back: an existing namespace of the same name
# fails the apply, and dropping the entry again leaves the Kubernetes namespace standing.
run "a_namespace_neither_adopts_nor_deletes_by_default" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.adoptionPolicy == "Never"
    error_message = "A namespace that already exists should stop the apply rather than be taken over."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.deletePolicy == "Keep"
    error_message = "Dropping a line from a variables file should not delete a running workload."
  }
}

run "a_namespace_overrides_only_the_defaults_it_names" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        network_policy = { ingress = "AllowAll" }
      }
      team-search = {
        network_policy = { egress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowAll"
    error_message = "A namespace that opens ingress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.egress == "AllowSameNamespace"
    error_message = "Overriding ingress should leave egress on the default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "A namespace that opens egress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Overriding egress should leave ingress on the default."
  }
}

# One place to move a whole cluster at once, rather than repeating the same override per namespace.
run "the_estate_wide_defaults_move_every_namespace_that_says_nothing" {
  command = plan

  variables {
    managed_namespace_defaults = {
      adoption_policy = "IfIdentical"
      delete_policy   = "Delete"
      network_policy  = { egress = "DenyAll" }
      resource_quota  = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    managed_namespaces = {
      team-payments = {}
      team-search = {
        network_policy = { egress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.egress == "DenyAll"
    error_message = "A namespace that says nothing should follow the estate-wide default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "A namespace that says otherwise should still win over the default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Changing the default egress should leave the default ingress alone."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.adoptionPolicy == "IfIdentical" && namespace.body.properties.deletePolicy == "Delete"
    ])
    error_message = "The adoption and delete policies should follow the defaults as well."
  }
  assert {
    condition     = keys(azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "The default quota should reach every namespace, all four figures of it."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
    ])
    error_message = "The figures the defaults do name should reach the namespace, the CPU one as milliCPU."
  }
}

run "a_namespace_takes_the_quota_figures_it_names_and_the_defaults_for_the_rest" {
  command = plan

  variables {
    managed_namespace_defaults = {
      resource_quota = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    managed_namespaces = {
      team-search = {
        resource_quota = { cpu_limit = "8", memory_request = "1Gi" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuRequest == "500m"
    error_message = "Neither side named a CPU request, so the built-in default should fill it in - Azure takes no namespace without one."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuLimit == "8000m",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
    ])
    error_message = "A namespace should override the figures it names and inherit the ones it does not."
  }
}

# Azure requires the quota on a managed namespace even though the API spec marks it optional: a
# namespace that arrives without one is refused with "The managed namespace CPU request number is
# not valid". A namespace that names nothing at all still has to carry all four figures.
run "a_namespace_that_names_no_quota_still_gets_a_whole_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = keys(azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "A namespace with no quota of its own should still be sent all four figures."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
    ])
    error_message = "The built-in quota should be the documented one, with the CPU figures in milliCPU."
  }
}

# Azure refuses a quota that states CPU in anything but milliCPU, while a manifest writes the same
# figure either way. Whichever form the variables name it in, what leaves here is milliCPU.
run "cpu_quota_figures_reach_azure_as_millicpu" {
  command = plan

  variables {
    managed_namespace_defaults = {
      resource_quota = { cpu_request = "0.5" }
    }
    managed_namespaces = {
      team-payments = {
        resource_quota = { cpu_limit = "2" }
      }
      # Named in milliCPU on both sides, which is the form Azure takes.
      team-search = {
        resource_quota = { cpu_limit = "1500m", cpu_request = "0.125" }
      }
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
    ])
    error_message = "Whole and fractional cores should be sent as the milliCPU figure they mean."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuLimit == "1500m",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuRequest == "125m",
    ])
    error_message = "A figure already written in milliCPU should be sent as it stands."
  }
}

# Labels and annotations are added to rather than replaced, so an estate-wide set survives a
# namespace adding one of its own.
run "namespace_labels_and_annotations_merge_with_the_defaults" {
  command = plan

  variables {
    managed_namespace_defaults = {
      annotations = { "estate" = "prototype" }
      labels      = { "cost-centre" = "platform", "tier" = "shared" }
    }
    managed_namespaces = {
      team-search = {
        annotations = { "owner" = "search" }
        labels      = { "tier" = "dedicated" }
      }
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-search"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "tier"                                       = "dedicated"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "A namespace should add to the default labels and win on the keys it repeats."
  }
  assert {
    condition = azapi_resource.managed_namespace["team-search"].body.properties.annotations == tomap({
      "estate" = "prototype"
      "owner"  = "search"
    })
    error_message = "Annotations should merge the same way the labels do."
  }
}

# A NetworkPolicy in a cluster with nothing to enforce it is an object nobody reads: the namespace
# looks closed in Azure and every pod in the cluster can still reach into it.
run "warns_about_restricted_namespaces_with_no_network_policy_engine" {
  command = plan

  variables {
    advanced_networking = null
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  expect_failures = [check.managed_namespaces_have_something_enforcing_their_network_policies]
}

run "a_namespace_open_in_both_directions_needs_no_engine_to_enforce_it" {
  command = plan

  variables {
    advanced_networking = null
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
    }
    managed_namespaces = {
      team-payments = {
        network_policy = { egress = "AllowAll", ingress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_relying_on_network_policy) == 0
    error_message = "A namespace that restricts nothing has nothing for an engine to enforce."
  }
}

run "rejects_a_namespace_name_kubernetes_reserves" {
  command = plan

  variables {
    managed_namespaces = {
      kube-payments = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_system_namespace_aks_will_not_hand_over" {
  command = plan

  variables {
    managed_namespaces = {
      gatekeeper-system = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_name_kubernetes_would_refuse" {
  command = plan

  variables {
    managed_namespaces = {
      Team_Payments = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_network_policy_rule_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        network_policy = { ingress = "AllowSameCluster" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_delete_policy_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        delete_policy = "Retain"
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_quota_that_is_not_a_kubernetes_quantity" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        resource_quota = { memory_limit = "4GB" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_cpu_quota_azure_cannot_hold" {
  command = plan

  variables {
    managed_namespaces = {
      # Finer than the milliCPU Azure counts in, which would otherwise be quietly rounded away.
      team-payments = {
        resource_quota = { cpu_limit = "0.0005" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_cpu_quota_of_nothing_at_all" {
  command = plan

  variables {
    managed_namespace_defaults = {
      # Azure takes nothing below 1m, and a quota of zero CPU is not what anybody meant by it.
      resource_quota = { cpu_request = "0" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

run "rejects_estate_wide_defaults_azure_does_not_have" {
  command = plan

  variables {
    managed_namespace_defaults = {
      network_policy = { egress = "AllowSameCluster" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

# ----------------------------------------------------------------------------------------------
# Tenant Flux configurations
# ----------------------------------------------------------------------------------------------

run "a_namespace_deploys_nothing_unless_it_names_a_repository" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = length(azapi_resource.managed_namespace_flux_configuration) == 0
    error_message = "A managed namespace without flux should get no Flux configuration."
  }
  assert {
    condition     = length(azapi_resource.flux_extension) == 0
    error_message = "Nothing asks for Flux, so the extension should not be installed."
  }
}

run "a_tenant_syncs_its_own_repository_into_its_own_namespace" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = {
          url         = "https://github.com/contoso/team-payments-deploy"
          path        = "./apps"
          secret_name = "team-payments-deploy-git"
        }
      }
      team-search = {}
    }
  }

  assert {
    condition     = keys(azapi_resource.managed_namespace_flux_configuration) == ["team-payments"]
    error_message = "Only the namespace that names a repository should get a Flux configuration."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].name == "team-payments"
    error_message = "The configuration should be named after its namespace."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].type == "Microsoft.KubernetesConfiguration/fluxConfigurations@2024-11-01"
    error_message = "The configuration should be a Flux configuration of the same API version as the platform's."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].parent_id == module.aks.resource_id
    error_message = "The configuration should belong to the cluster."
  }
  assert {
    condition = (
      azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.scope == "namespace"
      && azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.namespace == "team-payments"
    )
    error_message = "The configuration should be namespace-scoped, in the tenant's own namespace."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository.url == "https://github.com/contoso/team-payments-deploy"
    error_message = "The configuration should sync the tenant's repository."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository.repositoryRef.branch == "main"
    error_message = "The branch should default to main."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository.localAuthRef == "team-payments-deploy-git"
    error_message = "A private repository should be read with the Secret already in the namespace."
  }
  assert {
    condition     = !contains(keys(azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties), "configurationProtectedSettings")
    error_message = "No credential should pass through Terraform or Azure."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.path == "./apps"
    error_message = "The Kustomization should apply the configured path."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.postBuild.substitute == { cluster_name = var.name }
    error_message = "The team's manifests should get the cluster's name, and nothing else, as a post-build variable."
  }
  assert {
    condition = (
      azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.prune
      && azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.wait
    )
    error_message = "The Kustomization should prune what leaves the repository and wait for what it applied."
  }
  assert {
    condition = (
      azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository.syncIntervalInSeconds == 300
      && azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.syncIntervalInSeconds == 300
      && azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.retryIntervalInSeconds == 300
    )
    error_message = "The repository should be read, applied and retried every five minutes by default."
  }
}

# A tenant needs the extension, not the platform's own repository.
run "a_tenant_alone_installs_flux" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = { url = "https://github.com/contoso/team-payments-deploy" }
      }
    }
  }

  assert {
    condition     = length(azapi_resource.flux_extension) == 1
    error_message = "A tenant's Flux configuration should install the extension it runs on."
  }
  assert {
    condition     = length(azapi_resource.flux_configuration) == 0
    error_message = "Without flux_git_repository there is no platform configuration."
  }
}

run "a_public_tenant_repository_is_read_with_no_secret" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = {
          url                   = "https://github.com/contoso/team-payments-deploy"
          branch                = "release"
          sync_interval_seconds = 60
        }
      }
    }
  }

  assert {
    condition     = !contains(keys(azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository), "localAuthRef")
    error_message = "A public repository should name no Secret."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.gitRepository.repositoryRef.branch == "release"
    error_message = "The configured branch should be synced."
  }
  assert {
    condition     = azapi_resource.managed_namespace_flux_configuration["team-payments"].body.properties.kustomizations.apps.retryIntervalInSeconds == 60
    error_message = "A failed apply should be retried as often as the repository is read."
  }
}

run "rejects_a_tenant_repository_url_flux_cannot_read" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = { url = "github.com/contoso/team-payments-deploy" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_tenant_sync_interval_under_a_minute" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = {
          url                   = "https://github.com/contoso/team-payments-deploy"
          sync_interval_seconds = 30
        }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_tenant_secret_name_kubernetes_would_refuse" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        flux = {
          url         = "https://github.com/contoso/team-payments-deploy"
          secret_name = "Team_Payments_Git"
        }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_tenant_named_after_the_platform_configuration" {
  command = plan

  variables {
    managed_namespaces = {
      platform = {
        flux = { url = "https://github.com/contoso/platform-deploy" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# ----------------------------------------------------------------------------------------------
# Namespace-scoped access
# ----------------------------------------------------------------------------------------------

run "a_namespace_grants_nothing_unless_it_is_asked_to" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 0
    error_message = "A namespace with no access listed should hand nobody anything."
  }
}

# The labels the API server's Pod Security Admission controller reads. Nothing else is involved:
# admission is built into the API server, so a labelled namespace is an enforced one.
run "a_namespace_is_held_to_the_restricted_standard_by_default" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-payments"].body.properties.labels == tomap({
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "A namespace that says nothing should enforce, audit and warn at restricted."
  }
}

# Relaxing enforce is the exception; audit and warn stay put, so the pods that break the standard
# are still recorded and still warn whoever applies them.
run "an_exception_relaxes_only_what_it_names" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "privileged"
    error_message = "A namespace that cannot meet the standard should be able to say so."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
      azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/warn"] == "restricted",
    ])
    error_message = "An exception should stay visible: relaxing enforce must not drag audit and warn down with it."
  }
  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "An exception that is still audited is not a silent one."
  }
}

run "a_mode_set_to_none_leaves_its_label_off_entirely" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { warn = "none" }
      }
    }
  }

  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"])
    error_message = "A mode nobody wants should leave no label rather than an empty one."
  }
  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn-version"])
    error_message = "The version label goes with the mode it belongs to."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Turning off the warning should leave enforcement alone."
  }
}

# `latest` follows the cluster, so an upgrade can tighten the standard under a running workload.
run "the_standard_can_be_pinned_to_a_kubernetes_version" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { version = "v1.31" }
    }
    managed_namespaces = {
      team-payments = {}
      team-search = {
        pod_security = { version = "v1.30" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.31"
    error_message = "A pinned estate-wide version should reach every namespace."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.30"
    error_message = "A namespace should be able to hold a version of its own."
  }
}

run "the_estate_wide_standard_can_be_lowered_for_a_whole_cluster" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { audit = "restricted", enforce = "baseline", warn = "baseline" }
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "baseline",
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"] == "baseline",
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
    ])
    error_message = "One place should move the standard for the whole cluster."
  }
}

# The labels sit alongside whatever else the namespace carries, rather than replacing it.
run "pod_security_labels_join_the_labels_a_namespace_already_has" {
  command = plan

  variables {
    managed_namespace_defaults = {
      labels = { "cost-centre" = "platform" }
    }
    managed_namespaces = {
      team-payments = {
        labels = { "team" = "payments" }
      }
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-payments"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "team"                                       = "payments"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "The pod security labels should be added to the namespace labels, not replace them."
  }
}

# An exception is fine. An exception nobody can see is what this warns about.
run "warns_about_an_exception_that_is_neither_enforced_nor_recorded" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { audit = "none", enforce = "privileged", warn = "none" }
      }
    }
  }

  expect_failures = [check.pod_security_exceptions_stay_on_the_record]
}

run "an_exception_recorded_by_warn_alone_is_not_warned_about" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { audit = "none", enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "Either audit or warn at the estate standard is enough to keep an exception visible."
  }
}

# Nothing was relaxed, so there is no exception to record - even with audit and warn turned off.
run "a_namespace_at_the_estate_standard_needs_no_record_of_an_exception" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { audit = "none", warn = "none" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "A namespace that still enforces the estate standard has made no exception."
  }
}

run "rejects_a_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { enforce = "hardened" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_pod_security_version_that_is_not_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { version = "1.31" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# One place decides the standard, so a hand-written label cannot contradict pod_security.
run "rejects_a_pod_security_label_written_by_hand" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_pod_security_label_written_by_hand_in_the_defaults" {
  command = plan

  variables {
    managed_namespace_defaults = {
      labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

run "rejects_an_estate_wide_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { enforce = "hardened" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

run "flux_is_told_nothing_it_has_no_value_for" {
  command = plan

  variables {
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_url"),
      !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "dns_zone_name"),
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.cluster_name == "aks-test",
    ])
    error_message = "A variable the cluster has no value for should be left out, and the ones it does have still sent."
  }
}

# ----------------------------------------------------------------------------------------------
# Listener certificates from Key Vault, hostnames in Azure DNS
# ----------------------------------------------------------------------------------------------

run "the_platform_namespaces_can_be_changed" {
  command = plan

  variables {
    key_vault_name       = "kv-aks-test"
    key_vault_namespaces = ["int-fi-gateway"]
  }

  assert {
    condition     = keys(data.azurerm_user_assigned_identity.key_vault) == ["int-fi-gateway"] && keys(azurerm_federated_identity_credential.key_vault) == ["int-fi-gateway"]
    error_message = "Only the namespaces key_vault_namespaces names should get a share, with no managed namespaces."
  }
}

run "rejects_a_namespace_whose_share_would_overlap_another" {
  command = plan

  variables {
    key_vault_name = "kv-aks-test"
    managed_namespaces = {
      "team--a" = {}
    }
  }

  expect_failures = [azurerm_federated_identity_credential.key_vault]
}

run "rejects_a_vault_name_azure_would_refuse" {
  command = plan

  variables {
    key_vault_name = "kv--aks-test"
  }

  expect_failures = [var.key_vault_name]
}

run "external_dns_writes_the_zone_as_its_service_account" {
  command = plan

  variables {
    dns_zone_name = "contoso.com"
  }

  assert {
    condition = alltrue([
      azurerm_user_assigned_identity.external_dns[0].name == "id-sec-test-aks-dns",
      azurerm_federated_identity_credential.external_dns[0].subject == "system:serviceaccount:external-dns:external-dns",
      azurerm_role_assignment.external_dns[0].role_definition_name == "DNS Zone Contributor",
      azurerm_role_assignment.external_dns[0].scope == data.azurerm_dns_zone.this[0].id,
      data.azurerm_dns_zone.this[0].resource_group_name == "rg-aks-test",
    ])
    error_message = "external-dns should be federated with its own service account and contribute to the zone, which defaults to the cluster's resource group."
  }
}

run "flux_is_told_where_the_vault_and_the_zone_are" {
  command = plan

  variables {
    key_vault_name       = "kv-sec-test-shared"
    key_vault_namespaces = ["int-fi-gateway"]
    dns_zone_name        = "contoso.com"
    managed_namespaces = {
      example = {}
    }
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-sec-test-shared.vault.azure.net/",
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_example"),
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_int_fi_gateway"),
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_name == "contoso.com",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_resource_group_name == "rg-aks-test",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_subscription_id == "55555555-5555-5555-5555-555555555555",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_provider == "azure",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_private == "false",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.quote == "\"",
    ])
    error_message = "The platform Kustomization should be told the vault URL, each namespace's identity and where the zone is."
  }
}

run "without_portable_disks_nothing_is_granted_for_them" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_role_definition.portable_disks) == 0,
      length(azurerm_role_assignment.portable_disks) == 0,
      !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "portable_disk_resource_group_name"),
    ])
    error_message = "Without portable_disks_enabled nothing is granted for disks or handed to Flux."
  }
}

run "portable_disks_get_a_role_for_disks_only" {
  command = plan

  variables {
    portable_disks_enabled = true
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      azurerm_role_definition.portable_disks[0].name == "Portable disks (aks-test)",
      azurerm_role_definition.portable_disks[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test",
      azurerm_role_definition.portable_disks[0].permissions[0].actions == tolist([
        "Microsoft.Compute/disks/*",
        "Microsoft.Compute/snapshots/*",
        "Microsoft.Resources/subscriptions/resourceGroups/read",
      ]),
      azurerm_role_assignment.portable_disks[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test",
    ])
    error_message = "The cluster identity should get a role of its own on the resource group that covers disks and snapshots only."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.portable_disk_resource_group_name == "rg-aks-test"
    error_message = "The Flux repository should be told where the portable disks go."
  }
}

run "a_stateless_cluster_plans" {
  command = plan

  variables {
    persistent_storage_enabled = false
  }
}

run "portable_disks_need_persistent_storage" {
  command = plan

  variables {
    persistent_storage_enabled = false
    portable_disks_enabled     = true
  }

  expect_failures = [var.portable_disks_enabled]
}

run "a_cluster_federates_the_shared_identities_and_grants_nothing" {
  command = plan

  variables {
    name                         = "aks-test-a"
    key_vault_name               = "kv-sec-test-shared"
    key_vault_namespaces         = ["flux-system", "int-fi-gateway"]
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
    managed_namespaces = {
      example = {
        groups = { admin = "33333333-3333-3333-3333-333333333333" }
      }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      data.azurerm_key_vault.this[0].name == "kv-sec-test-shared",
      data.azurerm_key_vault.this[0].resource_group_name == "rg-aks-test",
    ])
    error_message = "A cluster on the shared vault should look it up, not create it."
  }
  assert {
    condition = alltrue([
      keys(data.azurerm_user_assigned_identity.key_vault) == ["example", "flux-system", "int-fi-gateway"],
      data.azurerm_user_assigned_identity.key_vault["example"].name == "id-sec-test-shared-kv-example",
      data.azurerm_user_assigned_identity.key_vault["int-fi-gateway"].name == "id-sec-test-shared-kv-int-fi-gateway",
      data.azurerm_user_assigned_identity.key_vault["example"].resource_group_name == "rg-aks-test",
    ])
    error_message = "The namespaces' identities should be the environment's shared ones, looked up by their conventional names."
  }
  assert {
    condition = alltrue([
      keys(azurerm_federated_identity_credential.key_vault) == ["example", "flux-system", "int-fi-gateway"],
      azurerm_federated_identity_credential.key_vault["example"].name == "aks-aks-test-a",
      azurerm_federated_identity_credential.key_vault["example"].user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example",
      azurerm_federated_identity_credential.key_vault["example"].subject == "system:serviceaccount:example:key-vault",
    ])
    error_message = "The cluster should add a credential of its own to each shared identity."
  }
  assert {
    condition     = sort(keys(azurerm_role_assignment.network_contributor)) == tolist(["node_subnet", "pod_subnet"]) && keys(azurerm_role_assignment.managed_namespace) == ["example/namespace_user/33333333-3333-3333-3333-333333333333"]
    error_message = "The cluster's own grants are the network's and the namespace's kubeconfig; every grant on the vaults is shared/'s."
  }
  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-sec-test-shared.vault.azure.net/",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_client_id_example == "88888888-8888-8888-8888-888888888888",
    ])
    error_message = "The Flux repository should be told the shared vault and the shared identities' client IDs."
  }
}

run "without_a_registry_nothing_is_granted_on_one" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.kubelet_container_registry_pull) == 0
    error_message = "Without container_registry_name the cluster should be granted nothing on a registry."
  }
}

run "the_kubelet_pulls_from_the_registry" {
  command = plan

  variables {
    container_registry_name = "acrtest"
  }

  override_data {
    target = data.azurerm_container_registry.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerRegistry/registries/acrtest"
    }
  }

  assert {
    condition = alltrue([
      azurerm_role_assignment.kubelet_container_registry_pull[0].principal_id == "88888888-8888-8888-8888-888888888888",
      azurerm_role_assignment.kubelet_container_registry_pull[0].role_definition_name == "AcrPull",
    ])
    error_message = "The kubelet identity should get AcrPull on the registry."
  }
}

run "a_private_zone_is_looked_up_and_written_with_the_private_provider" {
  command = plan

  variables {
    dns_zone_name    = "contoso.com"
    dns_zone_private = true
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      length(data.azurerm_dns_zone.this) == 0,
      length(data.azurerm_private_dns_zone.zone) == 1,
      azurerm_role_assignment.external_dns[0].role_definition_name == "Private DNS Zone Contributor",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_provider == "azure-private-dns",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_private == "true",
    ])
    error_message = "A private zone should be looked up in Azure Private DNS, granted as Private DNS Zone Contributor, and Flux told to use the azure-private-dns provider."
  }
}

run "acns_can_be_turned_on_with_fqdn_policies_and_ebpf_host_routing" {
  command = plan

  variables {
    advanced_networking = {}
    default_node_pool = {
      os_sku = "AzureLinux"
    }
  }

  assert {
    condition = (
      local.network_profile.advanced_networking.enabled &&
      local.network_profile.advanced_networking.observability.enabled &&
      local.network_profile.advanced_networking.security.advanced_network_policies == "FQDN"
    )
    error_message = "ACNS should be on, with Hubble and FQDN policies."
  }
  assert {
    condition     = local.network_profile.advanced_networking.performance.acceleration_mode == "BpfVeth"
    error_message = "eBPF host routing should be in the cluster's create request."
  }
}

run "acns_is_off_when_turned_off" {
  command = plan

  variables {
    advanced_networking = null
  }

  assert {
    condition     = !can(local.network_profile.advanced_networking)
    error_message = "No ACNS and no eBPF host routing with advanced_networking = null."
  }
}

# The defaults are the production settings; the dev lab's tfvars turn the cost savings on by name.
run "defaults_are_production_settings" {
  command = plan

  assert {
    condition     = var.sku_tier == "Standard"
    error_message = "The default tier should be Standard (uptime SLA, design D31)."
  }
  assert {
    condition     = var.default_node_pool.node_count == 2 && var.default_node_pool.vm_size == "Standard_D4ds_v5" && var.default_node_pool.os_sku == "AzureLinux"
    error_message = "The default system pool should be two Standard_D4ds_v5 nodes on Azure Linux."
  }
  assert {
    condition     = var.gateway_implementation == "approuting-istio"
    error_message = "The default Gateway API implementation should be App Routing (D55)."
  }
  assert {
    condition     = var.vertical_pod_autoscaler_enabled
    error_message = "The VPA add-on should be on by default."
  }
  assert {
    condition     = var.auto_upgrade.kubernetes_channel == "none" && var.auto_upgrade.node_os_channel == "None"
    error_message = "AKS should upgrade nothing by itself (design section 3.5)."
  }
  assert {
    condition     = var.private_dns_zone_mode == "none" && var.private_cluster_public_fqdn_enabled
    error_message = "The private API server should resolve by its public FQDN, without an AKS-managed private zone (design section 2.2)."
  }
  assert {
    condition = (
      local.default_agent_pool.enable_encryption_at_host &&
      local.default_agent_pool.security_profile.ssh_access == "Disabled" &&
      local.default_agent_pool.node_taints == tolist(["CriticalAddonsOnly=true:NoSchedule"]) &&
      local.default_agent_pool.local_dns_profile.mode == "Disabled"
    )
    error_message = "The system pool should default to encryption at host, SSH off, CriticalAddonsOnly and LocalDNS Disabled (design sections 2.2, 2.3, 4.2)."
  }
  assert {
    condition     = var.advanced_networking == null && !can(local.network_profile.advanced_networking)
    error_message = "ACNS should be off by default (design D80): no Hubble, no FQDN policies, no eBPF host routing."
  }
}

run "warns_about_ebpf_host_routing_on_another_node_os" {
  command = plan

  variables {
    advanced_networking = {}
    default_node_pool = {
      os_sku = "Ubuntu"
    }
  }

  expect_failures = [check.ebpf_host_routing_needs_azure_linux_or_ubuntu_on_every_node]
}

run "the_system_pool_can_be_hardened" {
  command = plan

  variables {
    default_node_pool = {
      os_sku             = "AzureLinux"
      encryption_at_host = true
      ssh_access         = "Disabled"
      node_taints        = ["CriticalAddonsOnly=true:NoSchedule"]
    }
  }

  assert {
    condition = (
      local.default_agent_pool.os_sku == "AzureLinux" &&
      local.default_agent_pool.enable_encryption_at_host &&
      local.default_agent_pool.security_profile.ssh_access == "Disabled" &&
      local.default_agent_pool.node_taints == tolist(["CriticalAddonsOnly=true:NoSchedule"])
    )
    error_message = "The system pool's OS, encryption at host, SSH and taints should reach the module."
  }
}

run "rejects_an_ssh_access_azure_does_not_have" {
  command = plan

  variables {
    default_node_pool = {
      ssh_access = "Off"
    }
  }

  expect_failures = [var.default_node_pool]
}

run "customer_managed_keys_encrypt_etcd_and_the_node_disks" {
  command = plan

  variables {
    customer_managed_keys = {
      key_vault_name = "kv-sec-test-platform"
    }
  }

  assert {
    condition     = azurerm_key_vault_key.cluster["kms"].name == "key-aks-test-kms" && azurerm_key_vault_key.cluster["disk"].name == "key-aks-test-disk"
    error_message = "The cluster should have a KMS key and a disk key of its own."
  }
  assert {
    condition     = azurerm_disk_encryption_set.this[0].name == "des-aks-test" && azurerm_disk_encryption_set.this[0].encryption_type == "EncryptionAtRestWithCustomerKey"
    error_message = "The disk key should back a disk encryption set."
  }
  assert {
    condition     = local.azure_key_vault_kms.enabled && local.azure_key_vault_kms.key_vault_network_access == "Public" && local.azure_key_vault_kms.key_vault_resource_id == null
    error_message = "KMS should use the key over the vault's public endpoint, naming no vault."
  }
  assert {
    condition = (
      azurerm_role_assignment.cluster_customer_managed_keys["kms_key"].role_definition_name == "Key Vault Crypto User" &&
      azurerm_role_assignment.disk_encryption_set_key[0].role_definition_name == "Key Vault Crypto Service Encryption User"
    )
    error_message = "The cluster identity should use the KMS key, the disk encryption set its own key."
  }
}

run "kms_data_encryption_reaches_a_private_vault_as_a_trusted_service" {
  command = plan

  variables {
    customer_managed_keys = {
      key_vault_name           = "kv-sec-test-platform"
      key_vault_network_access = "Private"
      kms_data_encryption      = true
    }
  }

  assert {
    condition     = local.azure_key_vault_kms == null && length(azapi_update_resource.kms_data_encryption) == 1
    error_message = "With KMS data encryption the module states no classic KMS; it is set beside the module."
  }
  assert {
    condition = (
      azapi_update_resource.kms_data_encryption[0].body.properties.securityProfile.kubernetesResourceObjectEncryptionProfile.infrastructureEncryption == "Enabled" &&
      azapi_update_resource.kms_data_encryption[0].body.properties.securityProfile.azureKeyVaultKms.keyVaultNetworkAccess == "Private"
    )
    error_message = "KMS data encryption is on, with the vault reached privately."
  }
  assert {
    condition     = azurerm_role_assignment.cluster_customer_managed_keys["kms_vault"].role_definition_name == "Key Vault Contributor"
    error_message = "The cluster identity gets the vault role AKS asks for."
  }
}

run "without_customer_managed_keys_there_are_none" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault_key.cluster) == 0 && local.disk_encryption_set_id == null && local.azure_key_vault_kms == null
    error_message = "Without customer_managed_keys the platform's keys are used."
  }
}

run "a_pod_subnet_cell_runs_classic_zone_pools_with_the_autoscaler" {
  command = plan

  variables {
    network_profile = {
      outbound_type = "userDefinedRouting"
    }
    default_node_pool = {
      availability_zones = ["3"]
      ssh_access         = "Disabled"
      encryption_at_host = true
    }
    isolation_zones = {
      int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
    }
    zone_node_pools = {
      max_count = 2
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = sort(keys(local.zone_agent_pools)) == tolist(["intse", "intsearm", "intsearmspot", "intsespot"])
    error_message = "A zone gets four pools: on-demand and spot, amd64 and arm64."
  }
  assert {
    condition = (
      local.zone_agent_pools["intsespot"].scale_set_priority == "Spot" &&
      local.zone_agent_pools["intsespot"].min_count == 0 &&
      local.zone_agent_pools["intsespot"].max_count == 1 &&
      local.zone_agent_pools["intse"].max_count == 2 &&
      local.zone_agent_pools["intse"].max_pods == 250 &&
      local.zone_agent_pools["intse"].scale_set_priority == null &&
      local.zone_agent_pools["intsearm"].vm_size == "Standard_D2pds_v6" &&
      local.zone_agent_pools["intse"].availability_zones == tolist(["3"]) &&
      local.zone_agent_pools["intse"].pod_subnet_id != null &&
      local.zone_agent_pools["intsespot"].node_labels == tomap({ "platform/zone" = "int-se", "platform/capacity" = "spot" }) &&
      local.zone_agent_pools["intsespot"].node_taints == tolist(["platform/zone=int-se:NoSchedule", "platform/capacity=spot:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]) &&
      local.zone_agent_pools["intse"].node_taints == tolist(["platform/zone=int-se:NoSchedule"]) &&
      local.zone_agent_pools["intse"].local_dns_profile.mode == "Disabled"
    )
    error_message = "The zone pools scale from zero in the cell's availability zone, labelled and tainted for the placement mutations, their pods in the zone's pod subnet."
  }
  assert {
    condition     = local.default_agent_pool.pod_subnet_id != null && local.auto_scaler_profile.expander == "priority"
    error_message = "The system pool's pods take its pod subnet, and the autoscaler the priority expander."
  }
  assert {
    condition = (
      contains(keys(azurerm_role_assignment.network_contributor), "virtual_network") &&
      !contains(keys(local.network_profile), "network_plugin_mode") && !contains(keys(local.network_profile), "pod_cidr")
    )
    error_message = "The zone pools' cluster gets the virtual network, and the cluster is sent no plugin mode and no pod range."
  }
}

run "an_external_cluster_holds_external_zones_and_tells_flux_its_exposure" {
  command = plan

  variables {
    exposure        = "ext"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes", pod_subnet_name = "snet-ext-fi-pods" }
      ext-se = { node_subnet_name = "snet-ext-se-nodes", pod_subnet_name = "snet-ext-se-pods" }
    }
    managed_namespaces = {
      ext-fi-orders = { labels = { "platform/zone" = "ext-fi" } }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.cluster_exposure == "ext"
    error_message = "The Flux repository should be told the cluster's exposure."
  }
}

run "an_external_cluster_refuses_an_internal_zone" {
  command = plan

  variables {
    exposure        = "ext"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes", pod_subnet_name = "snet-ext-fi-pods" }
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
    }
  }

  expect_failures = [var.exposure]
}

run "an_internal_cluster_refuses_an_external_namespace" {
  command = plan

  variables {
    exposure = "int"
    managed_namespaces = {
      ext-fi-orders = { labels = { "platform/zone" = "ext-fi" } }
    }
  }

  expect_failures = [var.exposure]
}

run "an_external_cluster_writes_no_internal_dns" {
  command = plan

  variables {
    exposure                = "ext"
    dns_zone_name           = "contoso.com"
    internal_dns_zone_names = ["int-fi.test.contoso.com"]
  }

  expect_failures = [var.exposure]
}

run "an_exposure_is_int_or_ext" {
  command = plan

  variables {
    exposure = "dmz"
  }

  expect_failures = [var.exposure]
}

run "isolation_zones_without_zone_node_pools_are_warned_about" {
  command = plan

  variables {
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
    }
  }

  expect_failures = [check.isolation_zones_need_nodes]
}

run "a_namespace_reads_its_zone_vault_on_a_shared_vault" {
  command = plan

  variables {
    key_vault_name       = "kv-sec-test-platform"
    key_vault_namespaces = ["ext-fi-gateway"]
    key_vault_namespace_vaults = {
      ext-fi-orders = "kv-sec-test-ext-fi"
    }
    managed_namespaces = {
      ext-fi-orders = {}
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      for key in ["key_vault_url_ext_fi_gateway", "key_vault_url_ext_fi_orders", "key_vault_client_id_ext_fi_orders"] :
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), key)
    ])
    error_message = "The Flux repository should be told each namespace's vault and identity."
  }
  assert {
    condition     = keys(data.azurerm_key_vault.namespace) == ["kv-sec-test-ext-fi"]
    error_message = "The zone vault should be looked up."
  }
}

run "the_internal_zones_are_granted_to_external_dns" {
  command = plan

  variables {
    dns_zone_name           = "contoso.com"
    internal_dns_zone_names = ["int-fi.test.contoso.com"]
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = azurerm_role_assignment.external_dns_internal["int-fi.test.contoso.com"].role_definition_name == "Private DNS Zone Contributor"
    error_message = "external-dns should write the internal zones."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.internal_dns_resource_group_name == "rg-aks-test"
    error_message = "The Flux repository should be told where the internal zones are."
  }
}

run "a_tenant_gets_the_substitutes_it_is_given" {
  command = plan

  variables {
    managed_namespaces = {
      ext-fi-orders = {
        flux = {
          url        = "https://github.com/example/orders"
          substitute = { zone_domain = "ext-fi.test.contoso.com" }
        }
      }
    }
  }

  assert {
    condition = (
      azapi_resource.managed_namespace_flux_configuration["ext-fi-orders"].body.properties.kustomizations.apps.postBuild.substitute.zone_domain == "ext-fi.test.contoso.com" &&
      azapi_resource.managed_namespace_flux_configuration["ext-fi-orders"].body.properties.kustomizations.apps.postBuild.substitute.cluster_name == "aks-test"
    )
    error_message = "A tenant's substitutes should reach its Flux configuration next to cluster_name."
  }
}

# ----------------------------------------------------------------------------------------------
# Image Integrity
# ----------------------------------------------------------------------------------------------

# Ratify reads the signatures and the signing certificate as the environment's shared identity, through
# this cluster's credential for its service account, and Flux is told what to configure it with.
run "image_integrity_federates_ratify_with_the_shared_identity" {
  command = plan

  variables {
    name                    = "aks-test-a"
    key_vault_name          = "kv-sec-test-shared"
    container_registry_name = "acrtest"
    image_integrity_enabled = true
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  override_data {
    target = data.azurerm_container_registry.this
    values = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerRegistry/registries/acrtest"
      login_server = "acrtest.azurecr.io"
    }
  }
  override_data {
    target = data.azurerm_key_vault_certificate.image_signing
    values = {
      certificate_policy = [{
        x509_certificate_properties = [{ subject = "CN=Test image signing, O=OneK8s, ST=Uusimaa, C=FI" }]
      }]
    }
  }

  assert {
    condition = alltrue([
      data.azurerm_user_assigned_identity.image_verification[0].name == "id-sec-test-shared-ratify",
      data.azurerm_user_assigned_identity.image_verification[0].resource_group_name == "rg-aks-test",
    ])
    error_message = "Ratify's identity should be the environment's shared one, looked up by its conventional name."
  }
  assert {
    condition = alltrue([
      azurerm_federated_identity_credential.image_verification[0].name == "aks-aks-test-a",
      azurerm_federated_identity_credential.image_verification[0].subject == "system:serviceaccount:gatekeeper-system:ratify-admin",
      azurerm_federated_identity_credential.image_verification[0].issuer == "https://swedencentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/",
    ])
    error_message = "The cluster should federate the add-on's Ratify service account with the shared identity, under the cluster's own name."
  }
  assert {
    condition = alltrue([
      azapi_update_resource.image_integrity.resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test",
      azapi_update_resource.image_integrity.type == "Microsoft.ContainerService/managedClusters@2026-05-02-preview",
      azapi_update_resource.image_integrity.body.properties.securityProfile.imageIntegrity.enabled == true,
    ])
    error_message = "Image Integrity should be turned on in the cluster beside the module, on the preview API that knows it."
  }
  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.image_verification_client_id == "88888888-8888-8888-8888-888888888888",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.image_signing_certificate_name == "image-signing",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.container_registry_login_server == "acrtest.azurecr.io",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.image_signing_subject == "CN=Test image signing, O=OneK8s, ST=Uusimaa, C=FI",
    ])
    error_message = "Flux should get Ratify's client ID, the signing certificate's name and subject, and the registry."
  }
}

run "no_image_integrity_by_default" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = (
      length(azurerm_federated_identity_credential.image_verification) == 0 &&
      !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "image_verification_client_id")
    )
    error_message = "Without image_integrity_enabled there is no Ratify credential and nothing for Flux to configure."
  }
  assert {
    condition     = azapi_update_resource.image_integrity.body.properties.securityProfile.imageIntegrity.enabled == false
    error_message = "Image Integrity should be stated off, so that turning it off turns it off."
  }
}

run "image_integrity_needs_the_shared_vault_and_the_registry" {
  command = plan

  variables {
    image_integrity_enabled = true
  }

  expect_failures = [var.image_integrity_enabled]
}

run "no_audit_log_without_a_workspace" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.audit) == 0
    error_message = "Without log_analytics_workspace_name the cluster should send its logs nowhere."
  }
}

run "the_audit_log_goes_to_the_environments_workspace" {
  command = plan

  variables {
    log_analytics_workspace_name = "log-test-platform"
  }

  override_data {
    target = data.azurerm_log_analytics_workspace.platform
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.OperationalInsights/workspaces/log-test-platform"
    }
  }

  assert {
    condition = alltrue([
      azurerm_monitor_diagnostic_setting.audit[0].log_analytics_workspace_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.OperationalInsights/workspaces/log-test-platform",
      azurerm_monitor_diagnostic_setting.audit[0].log_analytics_destination_type == "Dedicated",
      toset([for l in azurerm_monitor_diagnostic_setting.audit[0].enabled_log : l.category]) == toset(["kube-audit-admin", "guard"]),
    ])
    error_message = "The cluster should send kube-audit-admin and guard to the workspace, in resource-specific tables (CIS AKS 2.1.1)."
  }
}

run "rejects_an_unknown_log_category" {
  command = plan

  variables {
    audit_log_categories = ["kube-audit-everything"]
  }

  expect_failures = [var.audit_log_categories]
}

# Who owns a namespace and pays for it (design section 2.6): the team and cost centre as labels, the
# contact and the repository as annotations - what Azure Policy's namespace-ownership rule expects.
run "a_namespace_names_its_owner_in_labels_and_annotations" {
  command = plan

  variables {
    managed_namespaces = {
      ext-fi-payments = {
        owner = {
          team        = "payments"
          cost_center = "cc-4711"
          contact     = "payments-team@example.com"
        }
        flux = {
          url = "https://github.com/contoso/payments"
        }
      }
    }
  }

  assert {
    condition = (
      azapi_resource.managed_namespace["ext-fi-payments"].body.properties.labels["platform/team"] == "payments"
      && azapi_resource.managed_namespace["ext-fi-payments"].body.properties.labels["platform/cost-center"] == "cc-4711"
    )
    error_message = "The owner's team and cost centre should be the namespace's platform/team and platform/cost-center labels."
  }
  assert {
    condition = azapi_resource.managed_namespace["ext-fi-payments"].body.properties.annotations == tomap({
      "platform/contact"    = "payments-team@example.com"
      "platform/repository" = "https://github.com/contoso/payments"
    })
    error_message = "The contact and the namespace's repository should be annotations."
  }
}

run "rejects_an_owner_that_is_not_a_label_value" {
  command = plan

  variables {
    managed_namespaces = {
      ext-fi-payments = {
        owner = {
          team        = "Payments Team"
          cost_center = "cc-4711"
          contact     = "payments-team@example.com"
        }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_owner_labels_set_by_hand" {
  command = plan

  variables {
    managed_namespaces = {
      ext-fi-payments = {
        labels = { "platform/team" = "someone-else" }
        owner = {
          team        = "payments"
          cost_center = "cc-4711"
          contact     = "payments-team@example.com"
        }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# managed_namespaces[*].groups: an Entra ID group per built-in role, bound inside the namespace by a
# RoleBinding that a Flux configuration of the namespace's own applies, one Kustomization per role.
run "namespace_groups_get_a_role_binding_each_through_flux" {
  command = plan

  variables {
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
    managed_namespaces = {
      team-payments = {
        groups = {
          view  = "11111111-1111-1111-1111-111111111111"
          edit  = "22222222-2222-2222-2222-222222222222"
          admin = "33333333-3333-3333-3333-333333333333"
        }
      }
      # One role only: no binding for the other two.
      team-search = {
        groups = { view = "AAAAAAAA-4444-4444-4444-444444444444" }
      }
      team-batch = {}
    }
  }

  assert {
    condition     = toset(keys(azapi_resource.managed_namespace_access_flux_configuration)) == toset(["team-payments", "team-search"])
    error_message = "Every namespace that names a group, and only those, should get a Flux configuration for its bindings."
  }
  assert {
    condition     = azapi_resource.managed_namespace_access_flux_configuration["team-payments"].name == "team-payments-access"
    error_message = "A namespace's binding configuration should be named <namespace>-access."
  }
  assert {
    condition     = toset(keys(azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.kustomizations)) == toset(["view", "edit", "admin"])
    error_message = "Every role that names a group should get a Kustomization."
  }
  assert {
    condition     = toset(keys(azapi_resource.managed_namespace_access_flux_configuration["team-search"].body.properties.kustomizations)) == toset(["view"])
    error_message = "A role without a group should get no Kustomization."
  }
  assert {
    condition     = azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.kustomizations.edit.path == "./infrastructure/namespace-access/edit"
    error_message = "A binding should be applied from its role's directory under namespace_access_path: Azure refuses two Kustomizations on one path."
  }
  assert {
    condition = azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.kustomizations.edit.postBuild.substitute == {
      namespace       = "team-payments"
      role            = "edit"
      group_object_id = "22222222-2222-2222-2222-222222222222"
    }
    error_message = "A binding's Kustomization should be told its namespace, its role and its group."
  }
  assert {
    condition     = azapi_resource.managed_namespace_access_flux_configuration["team-search"].body.properties.kustomizations.view.postBuild.substitute.group_object_id == "aaaaaaaa-4444-4444-4444-444444444444"
    error_message = "The group's object ID should be sent in lower case, as Entra ID puts it into the token."
  }
  assert {
    condition     = azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.kustomizations.admin.prune
    error_message = "A binding's Kustomization should prune, so that removing the group removes the binding."
  }
  assert {
    condition = (
      azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.scope == "cluster"
      && azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.namespace == "flux-system"
      && azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.gitRepository.url == "https://github.com/example/cluster-config"
    )
    error_message = "The binding configuration should read the cluster's repository at cluster scope from flux-system."
  }
  assert {
    condition     = toset(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations)) == toset(["platform"])
    error_message = "The platform configuration should be unchanged by the bindings."
  }
}

# Each group's members can fetch a kubeconfig for the namespace, and only for it.
run "namespace_groups_get_namespace_user_on_their_namespace" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    managed_namespaces = {
      team-payments = {
        groups = {
          view = "11111111-1111-1111-1111-111111111111"
          edit = "22222222-2222-2222-2222-222222222222"
        }
      }
    }
  }

  assert {
    condition = toset(keys(azurerm_role_assignment.managed_namespace)) == toset([
      "team-payments/namespace_user/11111111-1111-1111-1111-111111111111",
      "team-payments/namespace_user/22222222-2222-2222-2222-222222222222",
    ])
    error_message = "Every group should get Namespace User on its namespace, once."
  }
  assert {
    condition = alltrue([
      for assignment in azurerm_role_assignment.managed_namespace :
      assignment.role_definition_name == "Azure Kubernetes Service Namespace User" && assignment.principal_type == "Group"
    ])
    error_message = "The groups should get Azure Kubernetes Service Namespace User, as groups."
  }
}

run "namespace_access_path_can_be_moved" {
  command = plan

  variables {
    flux_git_repository   = { url = "https://github.com/example/cluster-config" }
    namespace_access_path = "./rbac"
    managed_namespaces = {
      team-payments = { groups = { admin = "33333333-3333-3333-3333-333333333333" } }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace_access_flux_configuration["team-payments"].body.properties.kustomizations.admin.path == "./rbac/admin"
    error_message = "The bindings should be applied from namespace_access_path."
  }
}

run "namespace_groups_without_flux_are_warned_about" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = { groups = { view = "11111111-1111-1111-1111-111111111111" } }
    }
  }

  expect_failures = [check.namespace_groups_need_flux]
}

run "rejects_a_namespace_group_that_is_not_an_object_id" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = { groups = { edit = "team-payments-developers" } }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_with_groups_and_a_name_too_long_for_its_kustomizations" {
  command = plan

  variables {
    managed_namespaces = {
      "team-payments-with-a-name-far-too-long-to-be-labelled" = { groups = { view = "11111111-1111-1111-1111-111111111111" } }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "traefik_serves_every_gateway_from_a_flux_configuration_of_its_own" {
  command = plan

  variables {
    exposure        = "ext"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes", pod_subnet_name = "snet-ext-fi-pods" }
      ext-se = { node_subnet_name = "snet-ext-se-nodes", pod_subnet_name = "snet-ext-se-pods" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
  }

  assert {
    condition     = keys(azapi_resource.traefik_flux_configuration) == ["ext-fi", "ext-se"]
    error_message = "Each zone's Gateway should get a Traefik Flux configuration."
  }
  assert {
    condition     = azapi_resource.traefik_flux_configuration["ext-fi"].name == "traefik-ext-fi"
    error_message = "A Traefik Flux configuration should be named traefik-<gateway>."
  }
  assert {
    condition     = azapi_resource.traefik_flux_configuration["ext-fi"].body.properties.gitRepository.url == "https://github.com/onek8s/aks-terraform"
    error_message = "Traefik should be read from this repository by default."
  }
  assert {
    condition     = azapi_resource.traefik_flux_configuration["ext-fi"].body.properties.kustomizations.gateway.path == "./gateways/traefik"
    error_message = "Traefik should be read from gateways/traefik."
  }
  assert {
    condition = (
      azapi_resource.traefik_flux_configuration["ext-se"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_namespace == "ext-se-gateway" &&
      azapi_resource.traefik_flux_configuration["ext-se"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "false"
    )
    error_message = "Each Traefik configuration should be told its Gateway's namespace and load balancer."
  }
  assert {
    condition = (
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_ext_fi == "traefik-ext-fi" &&
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_ext_se == "traefik-ext-se"
    )
    error_message = "The Flux repository should be told each Gateway's Traefik class."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_implementation == "traefik"
    error_message = "The Flux repository should be told the implementation, for its components."
  }
}

run "an_internal_zone_gets_an_internal_traefik_load_balancer" {
  command = plan

  variables {
    exposure        = "int"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
  }

  assert {
    condition = (
      azapi_resource.traefik_flux_configuration["int-fi"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "true" &&
      azapi_resource.traefik_flux_configuration["int-fi"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_exposure == "int"
    )
    error_message = "An internal zone's Traefik should be behind an internal load balancer."
  }
}

run "app_routing_serves_every_gateway_without_traefik" {
  command = plan

  variables {
    exposure        = "ext"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes", pod_subnet_name = "snet-ext-fi-pods" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "approuting-istio"
  }

  assert {
    condition     = length(azapi_resource.traefik_flux_configuration) == 0
    error_message = "App Routing needs no Traefik."
  }
  assert {
    condition = (
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_ext_fi == "approuting-istio"
    )
    error_message = "Every Gateway should name App Routing's class."
  }
  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_implementation == "approuting-istio"
    error_message = "The Flux repository should be told the implementation, for its components."
  }
}

run "a_cluster_without_a_gateway_implementation_names_no_class" {
  command = plan

  variables {
    gateway_implementation = null
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = length(azapi_resource.traefik_flux_configuration) == 0 && length([
      for key in keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute) : key if startswith(key, "gateway_")
    ]) == 0
    error_message = "Without a gateway_implementation there are no Gateway classes to tell and no Traefik."
  }
}

run "an_unknown_gateway_implementation_is_refused" {
  command = plan

  variables {
    gateway_implementation = "nginx"
  }

  expect_failures = [var.gateway_implementation]
}

# ----------------------------------------------------------------------------------------------
# A cell routed through the landing zone's hub firewall (2026-10-15: the lab's internal cell behind labfw)
# ----------------------------------------------------------------------------------------------

run "a_routed_cell_grants_aks_its_route_table" {
  command = plan

  override_data {
    target = data.azurerm_subnet.node
    values = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-system"
      address_prefixes = ["172.22.0.0/24"]
      route_table_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/routeTables/rt-dev-int-stateless-az1"
    }
  }

  variables {
    network_profile = {
      outbound_type = "userDefinedRouting"
    }
  }

  assert {
    condition     = azurerm_role_assignment.network_contributor["route_table"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/routeTables/rt-dev-int-stateless-az1"
    error_message = "AKS needs Network Contributor on the node subnet's route table to egress through the hub firewall."
  }
}

run "a_cell_without_a_route_table_grants_none" {
  command = plan

  assert {
    condition     = !contains(keys(azurerm_role_assignment.network_contributor), "route_table")
    error_message = "No route table on the node subnet, no grant on one."
  }
}

run "the_system_pool_can_ask_for_an_ephemeral_os_disk" {
  command = plan

  variables {
    default_node_pool = {
      vm_size      = "Standard_D4alds_v6"
      os_disk_type = "Ephemeral"
    }
  }

  assert {
    condition     = local.default_agent_pool.os_disk_type == "Ephemeral"
    error_message = "The OS disk type should reach the module's default agent pool."
  }
}

run "an_unknown_os_disk_type_is_refused" {
  command = plan

  variables {
    default_node_pool = {
      os_disk_type = "Premium"
    }
  }

  expect_failures = [var.default_node_pool]
}

run "a_cell_without_the_webhook_has_a_gateway_per_zone_and_nothing_else" {
  command = plan

  variables {
    exposure        = "int"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
  }

  assert {
    condition     = keys(azapi_resource.traefik_flux_configuration) == ["int-fi"]
    error_message = "Without the Flux webhook, one Gateway per zone and nothing else."
  }
  assert {
    condition     = !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "gateway_class_name_platform")
    error_message = "The Flux repository is told no platform gateway class."
  }
}

run "the_flux_webhook_brings_the_platform_gateway_and_flux_systems_share" {
  command = plan

  variables {
    exposure        = "ext"
    zone_node_pools = {}
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes", pod_subnet_name = "snet-ext-fi-pods" }
    }
    key_vault_name = "kv-onek8s-gwc-platform"
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
    flux_github_webhook    = true
  }

  assert {
    condition     = keys(azapi_resource.traefik_flux_configuration) == ["ext-fi", "platform"]
    error_message = "The Flux webhook should bring the platform gateway beside the zone's."
  }
  assert {
    condition = (
      azapi_resource.traefik_flux_configuration["platform"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_namespace == "platform-gateway" &&
      azapi_resource.traefik_flux_configuration["platform"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "false" &&
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_platform == "traefik-platform"
    )
    error_message = "The platform gateway should be public, in platform-gateway, and its class told to the Flux repository."
  }
  assert {
    condition = alltrue([
      contains(keys(azurerm_federated_identity_credential.key_vault), "flux-system"),
      azurerm_federated_identity_credential.key_vault["flux-system"].subject == "system:serviceaccount:flux-system:key-vault",
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_flux_system"),
    ])
    error_message = "flux-system should get a share of the vault to read the webhook's token with."
  }
}

run "the_flux_webhook_needs_a_vault" {
  command = plan

  variables {
    flux_git_repository    = { url = "https://github.com/example/cluster-config" }
    gateway_implementation = "traefik"
    flux_github_webhook    = true
  }

  assert {
    condition     = !contains(keys(azapi_resource.traefik_flux_configuration), "platform")
    error_message = "No platform gateway without a vault to read the webhook's token from."
  }

  expect_failures = [check.flux_github_webhook_has_a_repository_a_vault_and_a_gateway]
}

run "the_flux_webhook_needs_a_gateway_implementation" {
  command = plan

  variables {
    key_vault_name         = "kv-onek8s-gwc-platform"
    flux_git_repository    = { url = "https://github.com/example/cluster-config" }
    gateway_implementation = null
    flux_github_webhook    = true
  }

  expect_failures = [check.flux_github_webhook_has_a_repository_a_vault_and_a_gateway]
}

