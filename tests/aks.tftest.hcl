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
    naming = { templates = { key_vault = "kv-{region}" } }
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
    condition     = keys(data.azurerm_user_assigned_identity.key_vault) == ["int-fi-gateway"] && keys(azurerm_federated_identity_credential.platform_key_vault) == ["int-fi-gateway"]
    error_message = "Only the namespaces key_vault_namespaces names should get a share, the tenants' are tenants/'."
  }
}

run "rejects_a_namespace_whose_share_would_overlap_another" {
  command = plan

  variables {
    key_vault_name       = "kv-aks-test"
    key_vault_namespaces = ["team--a"]
  }

  expect_failures = [azurerm_federated_identity_credential.platform_key_vault]
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
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-sec-test-shared.vault.azure.net/",
      !contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_example"),
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_int_fi_gateway"),
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_name == "contoso.com",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_id == data.azurerm_dns_zone.this[0].id,
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.quote == "\"",
    ])
    error_message = "The platform Kustomization should be told the vault URL, each platform namespace's identity (no tenant's: tenants/ tells them) and where the zone is."
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
    persistent_storage_enabled = true
    portable_disks_enabled     = true
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
      keys(data.azurerm_user_assigned_identity.key_vault) == ["flux-system", "int-fi-gateway"],
      data.azurerm_user_assigned_identity.key_vault["int-fi-gateway"].name == "id-sec-test-shared-kv-int-fi-gateway",
      data.azurerm_user_assigned_identity.key_vault["int-fi-gateway"].resource_group_name == "rg-aks-test",
    ])
    error_message = "The namespaces' identities should be the environment's shared ones, looked up by their conventional names."
  }
  assert {
    condition = alltrue([
      keys(azurerm_federated_identity_credential.platform_key_vault) == ["flux-system", "int-fi-gateway"],
      azurerm_federated_identity_credential.platform_key_vault["int-fi-gateway"].name == "aks-aks-test-a",
      azurerm_federated_identity_credential.platform_key_vault["int-fi-gateway"].user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example",
      azurerm_federated_identity_credential.platform_key_vault["int-fi-gateway"].subject == "system:serviceaccount:int-fi-gateway:key-vault",
    ])
    error_message = "The cluster should add a credential of its own to each shared identity."
  }
  assert {
    condition     = sort(keys(azurerm_role_assignment.network_contributor)) == tolist(["node_subnet", "pod_subnet"])
    error_message = "The cluster's own grants are the network's; every grant on the vaults is shared/'s, a namespace's kubeconfig tenants/'."
  }
  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-sec-test-shared.vault.azure.net/",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_client_id_int_fi_gateway == "88888888-8888-8888-8888-888888888888",
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

run "a_private_zone_is_looked_up_and_named_by_its_resource_id" {
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
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_id == data.azurerm_private_dns_zone.zone[0].id,
    ])
    error_message = "A private zone should be looked up in Azure Private DNS, granted as Private DNS Zone Contributor, and Flux told its resource ID."
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
    condition     = var.gateways_enabled
    error_message = "A cluster should serve Gateways through App Routing by default (design section 4.1)."
  }
  assert {
    condition     = var.vertical_pod_autoscaler_enabled
    error_message = "The VPA add-on should be on by default."
  }
  assert {
    condition     = !var.persistent_storage_enabled
    error_message = "A cluster should have no persistent storage unless it says so: the stateless cells (design section 3.1)."
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
    condition     = sort(keys(local.zone_agent_pools)) == tolist(["se1", "se1arm", "se1armspot", "se1spot"])
    error_message = "A zone gets four pools of generation 1, named by its country: on-demand and spot, amd64 and arm64."
  }
  assert {
    condition = (
      local.zone_agent_pools["se1spot"].scale_set_priority == "Spot" &&
      local.zone_agent_pools["se1spot"].min_count == 0 &&
      local.zone_agent_pools["se1spot"].max_count == 1 &&
      local.zone_agent_pools["se1"].max_count == 2 &&
      local.zone_agent_pools["se1"].max_pods == 250 &&
      local.zone_agent_pools["se1"].scale_set_priority == null &&
      local.zone_agent_pools["se1arm"].vm_size == "Standard_D2pds_v6" &&
      local.zone_agent_pools["se1"].availability_zones == tolist(["3"]) &&
      local.zone_agent_pools["se1"].pod_subnet_id != null &&
      local.zone_agent_pools["se1spot"].node_labels == tomap({ "platform/zone" = "int-se", "platform/node-generation" = "1", "platform/capacity" = "spot" }) &&
      local.zone_agent_pools["se1spot"].node_taints == tolist(["platform/zone=int-se:NoSchedule", "platform/capacity=spot:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]) &&
      local.zone_agent_pools["se1"].node_taints == tolist(["platform/zone=int-se:NoSchedule"]) &&
      local.zone_agent_pools["se1"].local_dns_profile.mode == "Disabled" &&
      local.zone_agent_pools["se1"].orchestrator_version == null
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

run "a_zone_moves_to_a_new_node_pool_generation_blue_green" {
  command = plan

  variables {
    network_profile = {
      outbound_type = "userDefinedRouting"
    }
    default_node_pool = {
      availability_zones = ["3"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
      int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
    }
    zone_node_pools = {
      generations = {
        "1" = { kubernetes_version = "1.36", retiring_zones = ["int-fi"] }
        "2" = { zones = ["int-fi"], amd64_vm_size = "Standard_D4alds_v6" }
      }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = sort(keys(local.zone_agent_pools)) == tolist([
      "fi1", "fi1arm", "fi1armspot", "fi1spot", "fi2", "fi2arm", "fi2armspot", "fi2spot",
      "se1", "se1arm", "se1armspot", "se1spot",
    ])
    error_message = "The zone moving to generation 2 has both generations' pools side by side, the other zone only generation 1's."
  }
  assert {
    condition = (
      local.zone_agent_pools["fi1"].orchestrator_version == "1.36" &&
      local.zone_agent_pools["fi2"].orchestrator_version == null &&
      local.zone_agent_pools["fi2"].vm_size == "Standard_D4alds_v6" &&
      local.zone_agent_pools["fi2arm"].vm_size == "Standard_D2pds_v6" &&
      local.zone_agent_pools["fi2"].node_labels == tomap({ "platform/zone" = "int-fi", "platform/node-generation" = "2" })
    )
    error_message = "The old generation stays on its pinned version, the new one takes the cluster's and its own VM size, and both carry the zone label placement selects."
  }
  assert {
    condition = (
      contains(local.zone_agent_pools["fi1"].node_taints, "platform/retiring=true:NoSchedule") &&
      contains(local.zone_agent_pools["fi1spot"].node_taints, "platform/retiring=true:NoSchedule") &&
      !contains(local.zone_agent_pools["fi2"].node_taints, "platform/retiring=true:NoSchedule") &&
      !contains(local.zone_agent_pools["se1"].node_taints, "platform/retiring=true:NoSchedule")
    )
    error_message = "Only the retiring generation's pools in the zone that moves are tainted retiring."
  }
}

run "a_namespace_moves_to_node_pools_of_its_own" {
  command = plan

  variables {
    default_node_pool = {
      availability_zones = ["3"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
      int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
    }
    zone_node_pools = {
      generations = {
        "2" = {}
      }
    }
    namespace_node_pools = {
      int-se-example = { name = "ex", kinds = ["", "spot"] }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = sort(keys(local.zone_agent_pools)) == tolist([
      "fi2", "fi2arm", "fi2armspot", "fi2spot",
      "se2", "se2arm", "se2armspot", "se2ex", "se2exspot", "se2spot",
    ])
    error_message = "The namespace gets pools of its own beside its zone's shared ones, of the kinds it names."
  }
  assert {
    condition = (
      local.zone_agent_pools["se2exspot"].node_labels == tomap({ "platform/zone" = "int-se", "platform/node-generation" = "2", "platform/capacity" = "spot", "platform/pool" = "int-se-example" }) &&
      local.zone_agent_pools["se2exspot"].node_taints == tolist(["platform/zone=int-se:NoSchedule", "platform/pool=int-se-example:NoSchedule", "platform/capacity=spot:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]) &&
      local.zone_agent_pools["se2ex"].pod_subnet_id == local.zone_agent_pools["se2"].pod_subnet_id &&
      local.zone_agent_pools["se2"].node_taints == tolist(["platform/zone=int-se:NoSchedule"])
    )
    error_message = "The namespace's pools carry the zone's labels and taints and platform/pool, in the zone's subnets; the shared pools do not."
  }
}

run "a_namespace_pool_needs_a_zone_namespace" {
  command = plan

  variables {
    isolation_zones = {
      int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
    }
    zone_node_pools = {}
    namespace_node_pools = {
      team-search = { name = "ts" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  expect_failures = [check.namespace_node_pools_are_in_a_zone]
}

run "a_generation_key_is_one_character" {
  command = plan

  variables {
    isolation_zones = {
      int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
    }
    zone_node_pools = {
      generations = {
        "blue" = {}
      }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  expect_failures = [var.zone_node_pools]
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
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  # Two zones of one country are refused by zone_node_pools too: they would name the same pools.
  expect_failures = [var.exposure, var.zone_node_pools]
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
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  expect_failures = [check.isolation_zones_need_nodes]
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
    condition     = azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.internal_dns_zone_ids == "'[${data.azurerm_private_dns_zone.internal["int-fi.test.contoso.com"].id}]'"
    error_message = "The Flux repository should be told the internal zones' resource IDs."
  }
}

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
run "the_flux_repository_names_the_gateway_class_itself" {
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
  }

  assert {
    condition = length([
      for key in keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute) : key if startswith(key, "gateway_")
    ]) == 0
    error_message = "App Routing's class is the only one: the Flux repository is told no Gateway class or implementation."
  }
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
    flux_github_webhook = true
  }

  assert {
    condition = alltrue([
      contains(keys(azurerm_federated_identity_credential.platform_key_vault), "flux-system"),
      azurerm_federated_identity_credential.platform_key_vault["flux-system"].subject == "system:serviceaccount:flux-system:key-vault",
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_flux_system"),
    ])
    error_message = "flux-system should get a share of the vault to read the webhook's token with."
  }
}

run "the_flux_webhook_needs_a_vault" {
  command = plan

  variables {
    flux_git_repository = { url = "https://github.com/example/cluster-config" }
    flux_github_webhook = true
  }

  expect_failures = [check.flux_github_webhook_has_a_repository_a_vault_and_a_gateway]
}

run "the_flux_webhook_needs_gateways" {
  command = plan

  variables {
    key_vault_name      = "kv-onek8s-gwc-platform"
    flux_git_repository = { url = "https://github.com/example/cluster-config" }
    gateways_enabled    = false
    flux_github_webhook = true
  }

  expect_failures = [check.flux_github_webhook_has_a_repository_a_vault_and_a_gateway]
}

