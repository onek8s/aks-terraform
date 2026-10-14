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
  resource_group_name  = "rg-aks-test"
  virtual_network_name = "vnet-aks-test"
}

# ----------------------------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------------------------

run "default_cluster_is_private_and_scoped_to_its_node_subnet" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 1
    error_message = "A cluster with one node subnet should get exactly one Network Contributor assignment."
  }
  assert {
    condition     = azurerm_role_assignment.network_contributor["node_subnet"].scope == data.azurerm_subnet.node[0].id
    error_message = "The assignment should be scoped to the node subnet, not to the virtual network."
  }
  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "Without a bring-your-own private DNS zone there is nothing to grant access to."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 1
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
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prototype-aks-a"
    error_message = "aks-prototype-a in swedencentral should be run by id-sec-prototype-aks-a."
  }
}

run "an_automatic_cluster_is_named_apart_from_its_sibling" {
  command = plan

  variables {
    name = "aks-prototype-automatic"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prototype-aks-automatic"
    error_message = "Two clusters in one environment must not end up sharing an identity name."
  }
}

run "a_cluster_name_with_nothing_after_the_environment_keeps_the_short_form" {
  command = plan

  variables {
    name = "aks-prod"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prod-aks"
    error_message = "A name with no distinguishing tail should stop after the function."
  }
}

run "a_cluster_name_with_nothing_to_split_has_no_environment_to_lift" {
  command = plan

  variables {
    name = "cluster"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-cluster"
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
    condition     = azurerm_user_assigned_identity.this[0].name == "id-euw-prod-aks-main"
    error_message = "The region code should come from location, not from swedencentral by habit."
  }
}

# Guessing a code for an unknown region would put an off-convention name on a real identity.
run "refuses_a_region_with_no_short_code" {
  command = plan

  variables {
    location = "moonbase1"
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "wider_scope_grants_the_virtual_network_instead" {
  command = plan

  variables {
    network_role_assignment_scope = "virtual_network"
  }

  assert {
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this[0].id
    error_message = "network_role_assignment_scope = \"virtual_network\" should grant the whole network."
  }
}

run "role_assignments_can_be_left_to_someone_else" {
  command = plan

  variables {
    create_role_assignments = false
    private_dns_zone_name   = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 0
    error_message = "create_role_assignments = false should create no assignments."
  }
  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "create_role_assignments = false should create no assignments."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "There is nothing to wait for when no assignment is created."
  }
}

run "byo_private_dns_zone_is_granted_and_named" {
  command = plan

  variables {
    private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 1
    error_message = "A bring-your-own zone needs the cluster identity to be able to write records into it."
  }
}

# Node autoprovisioning creates node pools of its own, which the subnet assignments do not cover, so
# Microsoft documents Network Contributor on the whole virtual network for this SKU. A cluster left
# on the subnet scope comes up half way and then sits in Creating until the deployment times out.
run "automatic_is_granted_the_whole_virtual_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["virtual_network"]
    error_message = "AKS Automatic should get one assignment on the virtual network, not one per subnet."
  }
  assert {
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this[0].id
    error_message = "The assignment should be scoped to the virtual network."
  }
}

# The narrower scope stays reachable, since an environment may have the assignment already in place
# at that scope, but it is the configuration the check block warns about.
run "automatic_can_still_be_scoped_down_by_hand" {
  command = plan

  variables {
    sku_name                      = "Automatic"
    sku_tier                      = "Standard"
    api_server_subnet_name        = "snet-aks-apiserver"
    system_node_subnet_name       = "snet-aks-system"
    network_role_assignment_scope = "subnet"
  }

  # The mocked subnet data source hands out one ID for every subnet, which would collapse into a
  # single assignment. Three distinct subnets is the point of this run, so they are named here.
  override_data {
    target = data.azurerm_subnet.system_node[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-system"
    }
  }
  override_data {
    target = data.azurerm_subnet.api_server[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-apiserver"
    }
  }

  expect_failures = [check.automatic_network_role_assignment_scope]

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 3
    error_message = "An explicit subnet scope should still produce one assignment per subnet."
  }
}

# A Base cluster is unaffected: it joins the subnets it is handed and nothing else.
run "base_keeps_the_subnet_scoped_assignments" {
  command = plan

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["node_subnet"]
    error_message = "A Base cluster should keep the least privilege subnet assignments."
  }
}

# The whole cluster can share a single subnet. Azure refuses a second assignment of the same role to
# the same principal at the same scope, so the duplicate has to be collapsed rather than sent twice.
run "one_subnet_in_two_roles_is_granted_once" {
  command = plan

  variables {
    system_node_subnet_name = "snet-aks-nodes"
  }

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 1
    error_message = "A node subnet that is also the system node subnet should be granted exactly once."
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
    error_message = "A Base cluster should still be sent the node pool it asked for."
  }
}

# The AzAPI default of 30 minutes is under what an AKS Automatic cluster in an existing network
# takes, and a Terraform side timeout does not stop the deployment - it just leaves the cluster in
# Creating with nothing in state.
run "cluster_operations_are_given_longer_than_the_provider_default" {
  command = plan

  assert {
    condition     = var.cluster_timeouts.create == "90m"
    error_message = "The cluster create timeout should be well above the 30 minute AzAPI default."
  }
}

# Pod right-sizing (OneK8s design section 4): the VPA add-on is on unless a cluster says otherwise,
# so the applications' VerticalPodAutoscalers in InPlaceOrRecreate mode have something to act on.
run "the_vpa_add_on_is_on_by_default" {
  command = plan

  assert {
    condition     = local.workload_auto_scaler_profile.vertical_pod_autoscaler.enabled
    error_message = "Every cluster should run the VPA add-on unless told otherwise."
  }

  assert {
    condition     = !can(local.workload_auto_scaler_profile.keda.enabled)
    error_message = "KEDA should be left to AKS, not sent."
  }
}

run "the_vpa_add_on_can_be_turned_off" {
  command = plan

  variables {
    vertical_pod_autoscaler_enabled = false
  }

  assert {
    condition     = local.workload_auto_scaler_profile.vertical_pod_autoscaler.enabled == false
    error_message = "vertical_pod_autoscaler_enabled = false should be sent, so AKS removes the add-on."
  }
}

run "an_automatic_cluster_is_sent_no_workload_auto_scaler_profile" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = local.workload_auto_scaler_profile == null
    error_message = "AKS Automatic manages the VPA itself."
  }
}

run "rejects_a_cluster_timeout_that_is_not_a_duration" {
  command = plan

  variables {
    cluster_timeouts = {
      create = "90 minutes"
    }
  }

  expect_failures = [var.cluster_timeouts]
}

# The module drops the whole network profile for an Automatic cluster on loadBalancer egress, so the
# ranges it runs on are Azure's rather than the ones network_profile asks for. They cannot be changed
# once the cluster exists, which is why this is worth catching before the apply.
run "automatic_on_load_balancer_egress_falls_back_to_the_azure_ranges" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  assert {
    condition     = !local.network_profile_is_sent
    error_message = "The module sends no network profile for this combination, so the configured ranges do not apply."
  }
  assert {
    condition     = local.effective_cluster_cidrs == tolist(["10.244.0.0/16", "10.0.0.0/16"])
    error_message = "The cluster should be reported as running on Azure's default pod and service ranges."
  }
}

# Any other egress type and the profile is sent, filtered down to the four properties Automatic
# accepts - which include the two ranges.
run "automatic_off_load_balancer_egress_keeps_the_configured_ranges" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
    network_profile = {
      outbound_type = "userDefinedRouting"
    }
  }

  assert {
    condition     = local.network_profile_is_sent
    error_message = "Anything other than loadBalancer egress should send the network profile."
  }
  assert {
    condition     = local.effective_cluster_cidrs == tolist(["100.201.0.0/16", "100.202.0.0/16"])
    error_message = "The configured ranges should survive for this combination."
  }
}

run "base_always_keeps_the_configured_ranges" {
  command = plan

  assert {
    condition     = local.network_profile_is_sent && local.effective_cluster_cidrs == tolist(["100.201.0.0/16", "100.202.0.0/16"])
    error_message = "A Base cluster is sent the network profile it asked for."
  }
}

run "an_address_space_clear_of_the_cluster_ranges_raises_nothing" {
  command = plan

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "100.201.0.0/16 and 100.202.0.0/16 do not overlap 172.19.0.0/16."
  }
}

# Azure's default service range is 10.0.0.0/16, which collides with a great many existing networks -
# and an Automatic cluster on loadBalancer egress gets it whether or not network_profile says so.
run "warns_when_the_azure_ranges_collide_with_the_existing_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  override_data {
    target = data.azurerm_virtual_network.this[0]
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["10.0.0.0/16"]
    }
  }

  expect_failures = [check.cluster_cidrs_do_not_overlap_the_network]
}

# A shorter prefix on either side still counts as an overlap.
run "warns_when_a_supernet_of_the_cluster_ranges_is_in_use" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.this[0]
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
    target = data.azurerm_virtual_network.this[0]
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

run "an_automatic_cluster_gets_flux_too" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = length(azapi_resource.flux_extension) == 1 && length(azapi_resource.flux_configuration) == 1
    error_message = "Flux follows flux_git_repository, not the SKU."
  }
}

run "a_public_flux_repository_is_sent_no_credentials" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = !contains(keys(azapi_resource.flux_configuration[0].body.properties.gitRepository), "httpsUser")
    error_message = "A public repository needs no HTTPS user."
  }
  assert {
    condition     = length(azapi_resource.flux_configuration[0].sensitive_body_version) == 0
    error_message = "A public repository has no protected settings to send."
  }
}

run "a_private_github_repository_is_read_with_a_token" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    flux_git_credentials = {
      https_key = "github_pat_example"
    }
  }

  assert {
    condition     = azapi_resource.flux_configuration[0].body.properties.gitRepository.httpsUser == "git"
    error_message = "The HTTPS user should default to git."
  }
  assert {
    condition = toset(nonsensitive(keys(azapi_resource.flux_configuration[0].sensitive_body_version))) == toset([
      "properties.configurationProtectedSettings.httpsKey",
    ])
    error_message = "The token should be sent as the httpsKey protected setting."
  }
  assert {
    condition     = nonsensitive(azapi_resource.flux_configuration[0].sensitive_body_version["properties.configurationProtectedSettings.httpsKey"]) == sha256("${base64encode("github_pat_example")}${jsonencode(azapi_resource.flux_configuration[0].body)}")
    error_message = "The token should be sent again whenever it or the rest of the configuration changes."
  }
}

run "a_private_github_repository_is_read_with_a_deploy_key" {
  command = plan

  variables {
    flux_git_repository = {
      url = "ssh://git@github.com/example/cluster-config"
    }
    flux_git_credentials = {
      ssh_private_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
    }
  }

  assert {
    condition     = !contains(keys(azapi_resource.flux_configuration[0].body.properties.gitRepository), "httpsUser")
    error_message = "An SSH repository needs no HTTPS user."
  }
  assert {
    condition = toset(nonsensitive(keys(azapi_resource.flux_configuration[0].sensitive_body_version))) == toset([
      "properties.configurationProtectedSettings.sshPrivateKey",
    ])
    error_message = "The key should be sent as the sshPrivateKey protected setting."
  }
}

run "rejects_flux_credentials_without_a_repository" {
  command = plan

  variables {
    flux_git_credentials = {
      https_key = "github_pat_example"
    }
  }

  expect_failures = [var.flux_git_credentials]
}

run "rejects_flux_credentials_with_both_a_token_and_a_key" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    flux_git_credentials = {
      https_key       = "github_pat_example"
      ssh_private_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
    }
  }

  expect_failures = [var.flux_git_credentials]
}

run "rejects_a_flux_token_for_an_ssh_repository" {
  command = plan

  variables {
    flux_git_repository = {
      url = "ssh://git@github.com/example/cluster-config"
    }
    flux_git_credentials = {
      https_key = "github_pat_example"
    }
  }

  expect_failures = [var.flux_git_credentials]
}

run "rejects_a_flux_deploy_key_for_an_https_repository" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    flux_git_credentials = {
      ssh_private_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
    }
  }

  expect_failures = [var.flux_git_credentials]
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

run "warns_about_a_public_api_server_without_an_allowlist" {
  command = plan

  variables {
    private_cluster_enabled = false
  }

  # In a real plan the check reports a warning; `terraform test` treats it as a failure, which is
  # what pins the warning down as still being raised.
  expect_failures = [check.api_server_exposure]
}

run "an_allowlisted_public_api_server_raises_nothing" {
  command = plan

  variables {
    private_cluster_enabled         = false
    api_server_authorized_ip_ranges = ["203.0.113.0/24"]
  }
}

# ----------------------------------------------------------------------------------------------
# Entra ID group access
# ----------------------------------------------------------------------------------------------

# Azure RBAC is how these clusters authorize the Kubernetes API, and there the groups are granted
# Azure roles on the cluster. The admin groups of the cluster's own Entra ID profile are not honored
# in that mode, so nothing is sent there.
run "azure_rbac_grants_the_entra_groups_on_the_cluster" {
  command = plan

  variables {
    entra_admin_group_object_ids  = ["22222222-2222-2222-2222-222222222222"]
    entra_reader_group_object_ids = ["33333333-3333-3333-3333-333333333333"]
  }

  assert {
    condition     = local.azure_rbac_enabled && local.kubernetes_rbac_admin_group_object_ids == null
    error_message = "A cluster on Azure RBAC should send no admin groups in its Entra ID profile."
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

# Kubernetes RBAC is the other half of the same decision: no role assignments, and the admin groups
# ride along in the cluster's Entra ID profile instead, where they are bound to cluster-admin.
run "kubernetes_rbac_sends_the_admin_groups_with_the_cluster" {
  command = plan

  variables {
    azure_rbac_enabled           = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = local.kubernetes_rbac_admin_group_object_ids == tolist(["22222222-2222-2222-2222-222222222222"])
    error_message = "Without Azure RBAC the admin groups are the only way in, so they have to reach the cluster."
  }
  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0
    error_message = "An Azure role assignment authorizes nothing on a cluster that runs on Kubernetes RBAC."
  }
}

# Read-only access has no counterpart in Kubernetes RBAC: the Entra ID profile of the cluster carries
# admin groups and nothing else, so the reader groups are granted nothing and are warned about.
run "warns_about_reader_groups_without_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled            = false
    entra_reader_group_object_ids = ["33333333-3333-3333-3333-333333333333"]
  }

  expect_failures = [check.reader_groups_need_azure_rbac]

  assert {
    condition     = length(azurerm_role_assignment.entra_reader) == 0
    error_message = "There is no read-only grant to make while the cluster authorizes through Kubernetes RBAC."
  }
}

# Azure preconfigures Automatic with Azure RBAC and gives it no way off, so the SKU decides and the
# groups are granted as role assignments regardless of what the variable asked for.
run "automatic_stays_on_azure_rbac_whatever_the_variable_says" {
  command = plan

  variables {
    sku_name                     = "Automatic"
    sku_tier                     = "Standard"
    api_server_subnet_name       = "snet-aks-apiserver"
    system_node_subnet_name      = "snet-aks-system"
    azure_rbac_enabled           = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  expect_failures = [check.automatic_is_always_authorized_through_azure_rbac]

  assert {
    condition     = local.azure_rbac_enabled && local.kubernetes_rbac_admin_group_object_ids == null
    error_message = "An Automatic cluster is authorized through Azure RBAC whatever azure_rbac_enabled says."
  }
  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 1
    error_message = "The admin groups of an Automatic cluster are granted as role assignments on it."
  }
}

# With the role assignments of the estate managed elsewhere, the groups are named here and granted
# there - which is worth saying out loud, because the cluster is otherwise unreachable.
run "warns_about_entra_groups_with_role_assignments_managed_elsewhere" {
  command = plan

  variables {
    create_role_assignments      = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  expect_failures = [check.entra_groups_are_granted_somewhere]

  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0
    error_message = "create_role_assignments = false should create no assignments."
  }
}

# ----------------------------------------------------------------------------------------------
# Input validation
# ----------------------------------------------------------------------------------------------

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
    network_profile = {
      network_policy    = "cilium"
      network_dataplane = "azure"
    }
  }

  expect_failures = [var.network_profile]
}

run "rejects_an_authorized_range_that_is_not_a_cidr" {
  command = plan

  variables {
    private_cluster_enabled         = false
    api_server_authorized_ip_ranges = ["203.0.113.5"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
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

# Azure answers this with 400 InvalidParameter, so it is refused before the request is built.
run "rejects_automatic_reusing_the_node_subnet_for_system_nodes" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-nodes"
  }

  expect_failures = [var.system_node_subnet_name]
}

run "rejects_automatic_without_a_system_node_subnet" {
  command = plan

  variables {
    sku_name               = "Automatic"
    sku_tier               = "Standard"
    api_server_subnet_name = "snet-aks-apiserver"
  }

  expect_failures = [var.system_node_subnet_name]
}

# Microsoft documents the API server subnet as required for an Automatic cluster in an existing
# network, but a cluster can be asked for without one - with a warning rather than a refusal.
run "warns_about_automatic_without_api_server_vnet_integration" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [check.automatic_api_server_subnet]
}

# Turning the integration off is a decision rather than an omission, so the warning above goes with
# it. This is what an AKS Automatic cluster on the network AKS manages asks for.
run "automatic_with_vnet_integration_turned_off_is_not_warned_about" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_vnet_integration_enabled = false
  }

  assert {
    condition     = !local.api_server_vnet_integration
    error_message = "The API server should not be joined to the network while the integration is off."
  }
  assert {
    condition     = length(data.azurerm_subnet.api_server) == 0
    error_message = "No API server subnet should be looked up while the integration is off."
  }
}

# The subnet is still granted to the cluster identity when the integration is on and the scope is
# narrowed to the subnets; with the integration off there is nothing there to grant.
run "no_api_server_subnet_assignment_while_the_integration_is_off" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_vnet_integration_enabled = false
    network_role_assignment_scope       = "subnet"
  }

  override_data {
    target = data.azurerm_subnet.system_node[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-system"
    }
  }

  expect_failures = [check.automatic_network_role_assignment_scope]

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["node_subnet", "system_node_subnet"]
    error_message = "Only the node and system node subnets should be granted while the integration is off."
  }
}

# Saying "no integration" and naming a subnet for it at the same time is refused, rather than one of
# the two being dropped silently.
run "rejects_an_api_server_subnet_while_the_integration_is_off" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_subnet_name              = "snet-aks-apiserver"
    api_server_vnet_integration_enabled = false
  }

  expect_failures = [var.api_server_subnet_name]
}

# A Base cluster keeps its own default: nothing to turn off, nothing to warn about.
run "the_integration_is_off_by_default_without_a_subnet_to_join" {
  command = plan

  assert {
    condition     = !local.api_server_vnet_integration
    error_message = "A cluster with no api_server_subnet_name should not ask for VNet integration."
  }
}

# ----------------------------------------------------------------------------------------------
# Clusters that bring no network
# ----------------------------------------------------------------------------------------------

# What an AKS Automatic cluster on the network AKS manages asks for: no virtual network, no subnets, nothing to look up
# and nothing to grant. AKS creates the network inside the node resource group instead.
run "a_cluster_without_a_network_looks_nothing_up_and_grants_nothing" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    virtual_network_name                = null
    node_subnet_name                    = null
    api_server_vnet_integration_enabled = false
  }

  assert {
    condition     = !local.byo_network
    error_message = "A cluster with no virtual_network_name should not be treated as attached to one."
  }
  assert {
    condition = alltrue([
      length(data.azurerm_virtual_network.this) == 0,
      length(data.azurerm_subnet.node) == 0,
      length(data.azurerm_subnet.system_node) == 0,
      length(data.azurerm_subnet.api_server) == 0,
    ])
    error_message = "There is no existing network to read, so none of the lookups should run."
  }
  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 0
    error_message = "AKS owns the network it creates, so the cluster identity needs nothing granted on it."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "With no role assignments there is nothing to wait for."
  }
  assert {
    condition     = local.default_agent_pool.vnet_subnet_id == null
    error_message = "The node pool should be sent no subnet when the cluster brings no network."
  }
}

# The two Automatic warnings are both about an existing virtual network, and the overlap check has
# no address space to compare against. None of them should fire on this arrangement.
run "a_cluster_without_a_network_raises_none_of_the_network_warnings" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    virtual_network_name                = null
    node_subnet_name                    = null
    api_server_vnet_integration_enabled = false
    private_cluster_enabled             = false
    api_server_authorized_ip_ranges     = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "There is no existing address space for the cluster ranges to collide with."
  }
}

# AKS Automatic hosts its system components in the network it creates, so the subnet that is
# otherwise required for this SKU is not.
run "automatic_without_a_network_needs_no_system_node_subnet" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = length(data.azurerm_subnet.system_node) == 0
    error_message = "A cluster with no network has no system node subnet to look up."
  }
}

# A Base cluster can do without a network too; the module then gets no subnet for its node pool.
run "base_without_a_network_sends_no_node_subnet" {
  command = plan

  variables {
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = local.default_agent_pool.vnet_subnet_id == null
    error_message = "A Base node pool should be sent no subnet when the cluster brings no network."
  }
}

# The network and the node subnet are one decision, so half of it is refused rather than half done.
run "rejects_a_virtual_network_without_a_node_subnet" {
  command = plan

  variables {
    node_subnet_name = null
  }

  expect_failures = [var.node_subnet_name]
}

run "rejects_a_node_subnet_without_a_virtual_network" {
  command = plan

  variables {
    virtual_network_name = null
  }

  expect_failures = [var.node_subnet_name]
}

run "rejects_a_system_node_subnet_without_a_virtual_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    virtual_network_name    = null
    node_subnet_name        = null
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [var.system_node_subnet_name]
}

run "rejects_an_api_server_subnet_without_a_virtual_network" {
  command = plan

  variables {
    virtual_network_name   = null
    node_subnet_name       = null
    api_server_subnet_name = "snet-aks-apiserver"
  }

  expect_failures = [var.api_server_subnet_name]
}

# Azure answers an Automatic cluster on the network it manages with `Managed cluster 'Automatic' SKU
# should use SAMI when using managed vnet`, so that combination runs on the cluster's own identity
# and none is created here. There is nothing to pre-grant either way.
run "automatic_without_a_network_runs_on_a_system_assigned_identity" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = local.system_assigned_identity
    error_message = "Azure refuses an Automatic cluster on a managed virtual network with a user assigned identity."
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 0
    error_message = "No user assigned identity should be created for a cluster that runs on its own."
  }
}

# The rule is Automatic's alone, and only on the network AKS manages.
run "automatic_on_an_existing_network_keeps_the_user_assigned_identity" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    system_node_subnet_name = "snet-aks-system"
    api_server_subnet_name  = "snet-aks-apiserver"
  }

  assert {
    condition     = !local.system_assigned_identity
    error_message = "An Automatic cluster on an existing network is granted access before it is created, so it needs an identity that already exists."
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 1
    error_message = "The identity should still be created for a cluster on an existing network."
  }
}

run "base_without_a_network_keeps_the_user_assigned_identity" {
  command = plan

  variables {
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 1
    error_message = "Only the Automatic SKU is refused a user assigned identity on a managed network."
  }
}

# The zone has to be granted to a principal that exists before the cluster, and a system assigned
# identity does not. Terraform warns rather than refusing - Azure creates the cluster either way,
# and it is the DNS registration that suffers.
run "warns_about_a_byo_private_dns_zone_with_no_identity_to_grant_it" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    virtual_network_name    = null
    node_subnet_name        = null
    private_cluster_enabled = true
    private_dns_zone_name   = "privatelink.swedencentral.azmk8s.io"
  }

  expect_failures = [check.byo_private_dns_zone_has_an_identity_to_grant]

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "There is no principal to grant the zone to before the cluster exists."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "With no assignments created there is nothing to wait for."
  }
}

# A bring-your-own private DNS zone is still reachable without a network of your own - it is the
# private cluster that needs it, not the subnets - so the grant on the zone survives.
run "a_cluster_without_a_network_still_grants_the_private_dns_zone" {
  command = plan

  variables {
    virtual_network_name  = null
    node_subnet_name      = null
    private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 1
    error_message = "The zone lives outside the network, so the cluster identity should still be granted it."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 1
    error_message = "There is an assignment to wait for, even with no network assignments."
  }
}

run "rejects_automatic_on_the_free_tier" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Free"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [var.sku_tier]
}

# ----------------------------------------------------------------------------------------------
# Managed namespaces
# ----------------------------------------------------------------------------------------------

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
      namespace.body.properties.defaultNetworkPolicy.egress == "AllowAll"
    ])
    error_message = "By default a workload should be able to reach out without further ado."
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
        network_policy = { egress = "AllowSameNamespace" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowAll"
    error_message = "A namespace that opens ingress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "Overriding ingress should leave egress on the default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.egress == "AllowSameNamespace"
    error_message = "A namespace that confines egress should get what it asked for."
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

# AKS Automatic runs Cilium whatever network_profile says, and is sent no network profile at all on
# loadBalancer egress - so the warning must not fire on it.
run "automatic_enforces_network_policies_whatever_the_profile_says" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
      pod_cidr          = "100.201.0.0/16"
      service_cidr      = "100.202.0.0/16"
      dns_service_ip    = "100.202.0.10"
      outbound_type     = "userDefinedRouting"
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = local.network_policy_engine_enabled
    error_message = "An Automatic cluster always runs Cilium, so its namespaces are enforced."
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

# The grants land on the namespace resource, not on the cluster: that is what keeps a team out of
# the namespace next door.
run "namespace_access_is_scoped_to_the_namespace_it_was_listed_on" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
      team-search = {
        access = [
          { role = "reader", principal_id = "33333333-3333-3333-3333-333333333333" },
        ]
      }
    }
  }

  assert {
    condition = toset(keys(azurerm_role_assignment.managed_namespace)) == toset([
      "team-payments/namespace_user/22222222-2222-2222-2222-222222222222",
      "team-payments/writer/22222222-2222-2222-2222-222222222222",
      "team-search/reader/33333333-3333-3333-3333-333333333333",
    ])
    error_message = "A grant should be addressed by what it grants, so that reordering the list churns nothing."
  }
  # The namespace IDs are only known after the apply, so they are overridden here to pin down that a
  # grant is scoped to its own namespace rather than to the cluster or to the namespace next door.
  override_resource {
    target          = azapi_resource.managed_namespace["team-search"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test/managedNamespaces/team-search"
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-search/reader/33333333-3333-3333-3333-333333333333"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test/managedNamespaces/team-search"
    error_message = "A grant belongs to the namespace it was listed on, not to the cluster."
  }
  assert {
    condition = alltrue([
      azurerm_role_assignment.managed_namespace["team-payments/namespace_user/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service Namespace User",
      azurerm_role_assignment.managed_namespace["team-payments/writer/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Writer",
      azurerm_role_assignment.managed_namespace["team-search/reader/33333333-3333-3333-3333-333333333333"].role_definition_name == "Azure Kubernetes Service RBAC Reader",
    ])
    error_message = "Each short role name should reach Azure as the built-in role it stands for."
  }
}

run "the_admin_role_is_the_namespace_one_and_not_the_cluster_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "admin", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/admin/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Admin"
    error_message = "A namespace admin should not be handed cluster admin by accident."
  }
}

# A group is the usual case, but a pipeline is a service principal and Azure has to be told which is
# which rather than being left to look the principal up.
run "a_service_principal_is_granted_as_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "44444444-4444-4444-4444-444444444444", principal_type = "ServicePrincipal" },
          { role = "reader", principal_id = "55555555-5555-5555-5555-555555555555", principal_type = "User" },
        ]
      }
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/writer/22222222-2222-2222-2222-222222222222"].principal_type == "Group"
    error_message = "A grant that says nothing about the principal should be a group."
  }
  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/writer/44444444-4444-4444-4444-444444444444"].principal_type == "ServicePrincipal"
    error_message = "A service principal should be granted as a service principal."
  }
  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/reader/55555555-5555-5555-5555-555555555555"].principal_type == "User"
    error_message = "A user should be granted as a user."
  }
}

run "namespace_access_is_left_to_someone_else_when_assignments_are" {
  command = plan

  variables {
    create_role_assignments = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 0
    error_message = "An estate with role assignments managed elsewhere should get these from there too."
  }

  expect_failures = [check.namespace_access_is_granted_somewhere]
}

# The data plane roles are Azure RBAC roles; a cluster on Kubernetes RBAC never consults them.
run "warns_about_namespace_data_plane_roles_without_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  expect_failures = [check.namespace_access_needs_azure_rbac]
}

# namespace_user is a control plane role on the Azure resource, so it works either way.
run "a_namespace_user_grant_needs_no_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = length(local.managed_namespace_data_plane_grants) == 0
    error_message = "namespace_user is granted on the Azure resource, not through Kubernetes authorization."
  }
  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 1
    error_message = "The grant should still be made."
  }
}

run "rejects_a_namespace_role_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "cluster_admin", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_grant_to_a_principal_type_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222", principal_type = "ManagedIdentity" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_grant_named_after_a_group_instead_of_its_object_id" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "aks-payments-writers" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# Two identical grants would collide on the address they are keyed by, which Terraform reports as
# something rather harder to read than this.
run "rejects_the_same_grant_listed_twice_in_one_namespace" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222", principal_type = "Group" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# The same principal in two namespaces is two grants, not a collision.
run "the_same_principal_can_be_granted_in_more_than_one_namespace" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [{ role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" }]
      }
      team-search = {
        access = [{ role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" }]
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 2
    error_message = "A principal granted in two namespaces should get one assignment in each."
  }
}

# ----------------------------------------------------------------------------------------------
# Pod Security Standards
# ----------------------------------------------------------------------------------------------

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

run "no_vault_and_no_zone_create_no_identities" {
  command = plan

  variables {
    managed_namespaces = {
      example = {}
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_key_vault.this) == 0,
      length(azurerm_user_assigned_identity.key_vault) == 0,
      length(azurerm_federated_identity_credential.key_vault) == 0,
      length(azurerm_role_assignment.key_vault_namespace_reader) == 0,
      length(azurerm_user_assigned_identity.external_dns) == 0,
      length(azurerm_federated_identity_credential.external_dns) == 0,
    ])
    error_message = "Without a vault or a zone there is nothing to create identities for - managed namespaces included."
  }
}

run "the_vault_is_created_next_to_the_cluster_on_azure_rbac" {
  command = plan

  variables {
    key_vault_name = "kv-aks-test"
  }

  assert {
    condition = alltrue([
      azurerm_key_vault.this[0].name == "kv-aks-test",
      azurerm_key_vault.this[0].resource_group_name == "rg-aks-test",
      azurerm_key_vault.this[0].rbac_authorization_enabled == true,
      azurerm_key_vault.this[0].sku_name == "standard",
    ])
    error_message = "The vault should be created in the cluster's resource group, on the Azure RBAC permission model."
  }
}

run "every_namespace_reads_its_own_share_of_the_vault" {
  command = plan

  variables {
    key_vault_name = "kv-aks-test"
    managed_namespaces = {
      example = {}
    }
  }

  assert {
    condition = alltrue([
      keys(azurerm_user_assigned_identity.key_vault) == ["example", "ingress-gateway"],
      azurerm_user_assigned_identity.key_vault["example"].name == "id-sec-test-aks-kv-example",
      azurerm_federated_identity_credential.key_vault["example"].subject == "system:serviceaccount:example:key-vault",
      azurerm_federated_identity_credential.key_vault["ingress-gateway"].subject == "system:serviceaccount:ingress-gateway:key-vault",
      azurerm_federated_identity_credential.key_vault["example"].audience == tolist(["api://AzureADTokenExchange"]),
    ])
    error_message = "Every managed namespace and every one of key_vault_namespaces should get an identity federated with its own key-vault service account."
  }

  assert {
    condition = alltrue([
      azurerm_role_assignment.key_vault_namespace_reader["example"].role_definition_name == "Key Vault Secrets User",
      azurerm_role_assignment.key_vault_namespace_reader["example"].condition_version == "2.0",
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})"),
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "@Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["ingress-gateway"].condition, "StringStartsWith 'ingress-gateway--'"),
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})"),
    ])
    error_message = "Each namespace identity should read the secrets under its own prefix only - values and metadata - and so list nothing."
  }
}

run "the_platform_namespaces_can_be_changed" {
  command = plan

  variables {
    key_vault_name       = "kv-aks-test"
    key_vault_namespaces = ["ingress-gateway"]
  }

  assert {
    condition     = keys(azurerm_user_assigned_identity.key_vault) == ["ingress-gateway"]
    error_message = "Only the namespaces key_vault_namespaces names should get a share, with no managed namespaces."
  }
}

run "namespace_writers_manage_their_own_secrets" {
  command = plan

  variables {
    key_vault_name = "kv-aks-test"
    managed_namespaces = {
      example = {
        access = [
          { role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "reader", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "33333333-3333-3333-3333-333333333333" },
          { role = "admin", principal_id = "44444444-4444-4444-4444-444444444444", principal_type = "ServicePrincipal" },
        ]
      }
    }
  }

  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_writer) == [
        "example/admin/44444444-4444-4444-4444-444444444444",
        "example/writer/33333333-3333-3333-3333-333333333333",
      ],
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].role_definition_name == "Key Vault Secrets Officer",
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].principal_type == "Group",
      azurerm_role_assignment.key_vault_namespace_writer["example/admin/44444444-4444-4444-4444-444444444444"].principal_type == "ServicePrincipal",
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].condition_version == "2.0",
    ])
    error_message = "The namespace's writers and admins - and nobody else - should be Secrets Officers of the vault."
  }

  assert {
    condition = alltrue([
      for fragment in [
        "@Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'",
        "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'",
        "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/setSecret/action'})",
        "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/delete'})",
        "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/purge/action'})",
      ] : strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].condition, fragment)
    ])
    error_message = "A writer's condition should hold creating a secret to the prefix by the requested name, and everything else done to a secret by its name."
  }
}

run "the_admin_groups_run_the_whole_vault" {
  command = plan

  variables {
    key_vault_name               = "kv-aks-test"
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition = alltrue([
      azurerm_role_assignment.key_vault_admin["22222222-2222-2222-2222-222222222222"].role_definition_name == "Key Vault Administrator",
      azurerm_role_assignment.key_vault_admin["22222222-2222-2222-2222-222222222222"].condition == null,
    ])
    error_message = "The cluster's admin groups should administer the vault without a condition."
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

run "zone_can_be_created_here" {
  command = plan

  # A created zone's ID is known only once it exists.
  override_resource {
    target          = azurerm_dns_zone.this[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/dnsZones/contoso.com"
    }
  }

  variables {
    dns_zone_name   = "contoso.com"
    dns_zone_create = true
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      length(data.azurerm_dns_zone.this) == 0,
      azurerm_dns_zone.this[0].name == "contoso.com",
      azurerm_dns_zone.this[0].resource_group_name == "rg-aks-test",
      azurerm_role_assignment.external_dns[0].scope == azurerm_dns_zone.this[0].id,
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_name == "contoso.com",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.dns_zone_subscription_id == "00000000-0000-0000-0000-000000000000",
    ])
    error_message = "With dns_zone_create the zone should be created in the cluster's resource group, granted to external-dns and handed to Flux, rather than looked up."
  }
}

run "zone_creation_needs_a_zone_name" {
  command = plan

  variables {
    dns_zone_create = true
  }

  expect_failures = [var.dns_zone_create]
}

run "vault_and_zone_grants_can_be_left_to_someone_else" {
  command = plan

  variables {
    key_vault_name               = "kv-aks-test"
    dns_zone_name                = "contoso.com"
    create_role_assignments      = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
    managed_namespaces = {
      example = {
        access = [{ role = "writer", principal_id = "33333333-3333-3333-3333-333333333333" }]
      }
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_role_assignment.key_vault_namespace_reader) == 0,
      length(azurerm_role_assignment.key_vault_namespace_writer) == 0,
      length(azurerm_role_assignment.key_vault_admin) == 0,
      length(azurerm_role_assignment.external_dns) == 0,
      length(azurerm_user_assigned_identity.key_vault) == 2,
      length(azurerm_user_assigned_identity.external_dns) == 1,
    ])
    error_message = "With create_role_assignments = false the identities are still created, and the grants left to the estate."
  }

  # The groups and the namespace grant are there to show they get no vault role either; that they
  # get nothing on the cluster or the namespace is warned about as usual.
  expect_failures = [check.entra_groups_are_granted_somewhere, check.namespace_access_is_granted_somewhere]
}

run "flux_is_told_where_the_vault_and_the_zone_are" {
  command = plan

  # The vault is created here, so its URI is known only once it exists.
  override_resource {
    target          = azurerm_key_vault.this[0]
    override_during = plan
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-aks-test"
      vault_uri = "https://kv-aks-test.vault.azure.net/"
    }
  }

  variables {
    key_vault_name = "kv-aks-test"
    dns_zone_name  = "contoso.com"
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
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-aks-test.vault.azure.net/",
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_example"),
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_ingress_gateway"),
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

run "flux_github_webhook_gets_a_token_and_flux_system_a_share" {
  command = plan

  variables {
    key_vault_name      = "kv-aks-test"
    flux_github_webhook = true
    flux_git_repository = {
      url  = "https://github.com/example/cluster-config"
      path = "./clusters/aks-test"
    }
  }

  assert {
    condition = alltrue([
      azurerm_key_vault_secret.flux_github_webhook[0].name == "flux-system--github-webhook-token",
      contains(keys(azurerm_user_assigned_identity.key_vault), "flux-system"),
      azurerm_federated_identity_credential.key_vault["flux-system"].subject == "system:serviceaccount:flux-system:key-vault",
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), "key_vault_client_id_flux_system"),
    ])
    error_message = "A Flux GitHub webhook should get its token in the vault, and flux-system a share of the vault to read it with."
  }
}

run "flux_github_webhook_without_a_vault_is_warned_about" {
  command = plan

  variables {
    flux_github_webhook = true
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = length(azurerm_key_vault_secret.flux_github_webhook) == 0
    error_message = "No token should be created without a vault to keep it in."
  }

  expect_failures = [check.flux_github_webhook_has_a_vault_and_a_repository]
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

run "portable_disks_are_left_ungranted_when_grants_are_made_elsewhere" {
  command = plan

  variables {
    portable_disks_enabled  = true
    create_role_assignments = false
  }

  assert {
    condition     = length(azurerm_role_assignment.portable_disks) == 0
    error_message = "With create_role_assignments = false the disk grant is left to the estate too."
  }
}

# ----------------------------------------------------------------------------------------------
# Node auto provisioning
# ----------------------------------------------------------------------------------------------

run "node_auto_provisioning_is_off_by_default" {
  command = plan

  assert {
    condition     = local.node_auto_provisioning == false
    error_message = "Node auto provisioning should be off unless asked for."
  }
}

run "node_auto_provisioning_grants_the_network_and_tells_flux_where_the_nodes_go" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["2"]
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition     = local.node_auto_provisioning
    error_message = "node_auto_provisioning_enabled should turn node auto provisioning on for a Base cluster."
  }
  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["virtual_network"]
    error_message = "Node auto provisioning should grant Network Contributor on the whole virtual network."
  }
  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.nap_subnet_id == data.azurerm_subnet.node[0].id,
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.nap_availability_zone == "swedencentral-2",
    ])
    error_message = "The Flux repository should be told the node subnet and the cell's availability zone."
  }
}

run "node_auto_provisioning_keeps_a_narrower_scope_it_is_given_but_warns" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
    network_role_assignment_scope  = "subnet"
    default_node_pool = {
      availability_zones = ["1"]
    }
  }

  expect_failures = [check.node_auto_provisioning_network_role_assignment_scope]
}

run "node_auto_provisioning_without_one_availability_zone_warns" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
  }

  expect_failures = [check.node_auto_provisioning_has_a_subnet_and_a_zone]
}

run "node_auto_provisioning_refuses_the_cluster_autoscaler" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones  = ["1"]
      enable_auto_scaling = true
      max_count           = 3
    }
  }

  expect_failures = [var.node_auto_provisioning_enabled]
}

run "node_auto_provisioning_needs_cilium_overlay" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    network_profile = {
      network_policy    = "azure"
      network_dataplane = "azure"
    }
  }

  expect_failures = [var.node_auto_provisioning_enabled]
}

run "a_cluster_on_the_shared_vault_only_federates_the_shared_identities" {
  command = plan

  variables {
    name                         = "aks-test-a"
    key_vault_name               = "kv-sec-test-shared"
    key_vault_create             = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
    managed_namespaces = {
      example = {
        access = [{ role = "writer", principal_id = "33333333-3333-3333-3333-333333333333" }]
      }
    }
    flux_github_webhook = true
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_key_vault.this) == 0,
      data.azurerm_key_vault.this[0].name == "kv-sec-test-shared",
      data.azurerm_key_vault.this[0].resource_group_name == "rg-aks-test",
    ])
    error_message = "A cluster on the shared vault should look it up, not create it."
  }
  assert {
    condition = alltrue([
      length(azurerm_user_assigned_identity.key_vault) == 0,
      keys(data.azurerm_user_assigned_identity.key_vault) == ["example", "flux-system", "ingress-gateway"],
      data.azurerm_user_assigned_identity.key_vault["example"].name == "id-sec-test-shared-kv-example",
      data.azurerm_user_assigned_identity.key_vault["ingress-gateway"].name == "id-sec-test-shared-kv-ingress-gateway",
      data.azurerm_user_assigned_identity.key_vault["example"].resource_group_name == "rg-aks-test",
    ])
    error_message = "The namespaces' identities should be the environment's shared ones, looked up by their conventional names."
  }
  assert {
    condition = alltrue([
      keys(azurerm_federated_identity_credential.key_vault) == ["example", "flux-system", "ingress-gateway"],
      azurerm_federated_identity_credential.key_vault["example"].name == "aks-aks-test-a",
      azurerm_federated_identity_credential.key_vault["example"].user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example",
      azurerm_federated_identity_credential.key_vault["example"].subject == "system:serviceaccount:example:key-vault",
    ])
    error_message = "The cluster should add a credential of its own to each shared identity."
  }
  assert {
    condition = alltrue([
      length(azurerm_role_assignment.key_vault_namespace_reader) == 0,
      length(azurerm_role_assignment.key_vault_admin) == 0,
      length(azurerm_role_assignment.key_vault_namespace_writer) == 0,
      length(azurerm_key_vault_secret.flux_github_webhook) == 0,
      length(random_password.flux_github_webhook) == 0,
    ])
    error_message = "Every grant on the shared vault, and the webhook token, are shared/'s."
  }
  assert {
    condition = alltrue([
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_url == "https://kv-sec-test-shared.vault.azure.net/",
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.key_vault_client_id_example == "88888888-8888-8888-8888-888888888888",
    ])
    error_message = "The Flux repository should be told the shared vault and the shared identities' client IDs."
  }
}

run "sharing_a_vault_needs_its_name" {
  command = plan

  variables {
    key_vault_create = false
  }

  expect_failures = [var.key_vault_create]
}

# ----------------------------------------------------------------------------------------------
# Container registry: images pulled as the kubelet identity
# ----------------------------------------------------------------------------------------------

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

run "a_private_zone_is_never_created_here" {
  command = plan

  variables {
    dns_zone_name    = "contoso.com"
    dns_zone_private = true
    dns_zone_create  = true
  }

  expect_failures = [var.dns_zone_private]
}

# ----------------------------------------------------------------------------------------------
# A stateless cell of the OneK8s design: isolation zones, ACNS, customer-managed keys, hardening
# ----------------------------------------------------------------------------------------------

run "a_cell_gets_acns_with_fqdn_policies_and_ebpf_host_routing" {
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

run "acns_stays_off_unless_asked_for" {
  command = plan

  assert {
    condition     = !can(local.network_profile.advanced_networking)
    error_message = "No ACNS and no eBPF host routing without advanced_networking."
  }
}

run "warns_about_ebpf_host_routing_on_the_default_node_os" {
  command = plan

  variables {
    advanced_networking = {}
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

run "without_customer_managed_keys_there_are_none" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault_key.cluster) == 0 && local.disk_encryption_set_id == null && local.azure_key_vault_kms == null
    error_message = "Without customer_managed_keys the platform's keys are used."
  }
}

run "isolation_zones_tell_flux_their_node_subnets" {
  command = plan

  variables {
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes" }
      ext-se = { node_subnet_name = "snet-ext-se-nodes" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = alltrue([
      for key in ["nap_subnet_id_int_fi", "nap_subnet_id_ext_se"] :
      contains(keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute), key)
    ])
    error_message = "The Flux repository should be told every zone's node subnet."
  }
}

run "an_external_cluster_holds_external_zones_and_tells_flux_its_exposure" {
  command = plan

  variables {
    exposure                       = "ext"
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
      ext-se = { node_subnet_name = "snet-ext-se-nodes" }
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
    exposure                       = "ext"
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
      int-fi = { node_subnet_name = "snet-int-fi-nodes" }
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

run "isolation_zones_without_node_auto_provisioning_are_warned_about" {
  command = plan

  variables {
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes" }
    }
  }

  expect_failures = [check.isolation_zones_need_node_auto_provisioning]
}

run "a_namespace_reads_its_zone_vault_on_a_shared_vault" {
  command = plan

  variables {
    key_vault_name       = "kv-sec-test-platform"
    key_vault_create     = false
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
    key_vault_create        = false
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

# Who owns a namespace and pays for it (design section 7): the team and cost centre as labels, the
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
        # The same grant through access as well: made once.
        access = [{ role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" }]
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

# Beside the cluster's own vault, the groups get on the namespace's secrets what their Kubernetes role
# gets on Secrets; shared/ does the same for the environment's shared vaults.
run "namespace_groups_get_their_kubernetes_role_on_the_namespaces_secrets" {
  command = plan

  variables {
    key_vault_name      = "kv-aks-test"
    flux_git_repository = { url = "https://github.com/example/cluster-config" }
    managed_namespaces = {
      team-payments = {
        groups = {
          view  = "11111111-1111-1111-1111-111111111111"
          edit  = "22222222-2222-2222-2222-222222222222"
          admin = "33333333-3333-3333-3333-333333333333"
        }
      }
    }
  }

  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_writer) == ["team-payments/writer/33333333-3333-3333-3333-333333333333"],
      azurerm_role_assignment.key_vault_namespace_writer["team-payments/writer/33333333-3333-3333-3333-333333333333"].role_definition_name == "Key Vault Secrets Officer",
      keys(azurerm_role_assignment.key_vault_namespace_editor) == ["team-payments/editor/22222222-2222-2222-2222-222222222222"],
    ])
    error_message = "The admin group should manage the namespace's secrets, the edit group only write them - and the view group get nothing."
  }
  assert {
    condition = alltrue([
      toset(one(azurerm_role_definition.key_vault_secrets_editor[0].permissions).data_actions) == toset([
        "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
        "Microsoft.KeyVault/vaults/secrets/setSecret/action",
        "Microsoft.KeyVault/vaults/secrets/update/action",
      ]),
      length(coalesce(one(azurerm_role_definition.key_vault_secrets_editor[0].permissions).actions, [])) == 0,
      azurerm_role_definition.key_vault_secrets_editor[0].name == "Key Vault Secrets Editor (aks-test)",
      azurerm_role_definition.key_vault_secrets_editor[0].assignable_scopes == tolist([data.azurerm_resource_group.this.id]),
    ])
    error_message = "The edit group's role should write, update and read the attributes of secrets - never getSecret, delete or purge - and be the cluster's own, at the resource group."
  }
  assert {
    condition = alltrue([
      strcontains(azurerm_role_assignment.key_vault_namespace_editor["team-payments/editor/22222222-2222-2222-2222-222222222222"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'team-payments--'"),
      strcontains(azurerm_role_assignment.key_vault_namespace_editor["team-payments/editor/22222222-2222-2222-2222-222222222222"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})"),
      # Azure refuses a condition naming an action the role lacks (InvalidRoleAssignmentCondition).
      !strcontains(azurerm_role_assignment.key_vault_namespace_editor["team-payments/editor/22222222-2222-2222-2222-222222222222"].condition, "getSecret"),
      !strcontains(azurerm_role_assignment.key_vault_namespace_editor["team-payments/editor/22222222-2222-2222-2222-222222222222"].condition, "secrets/delete"),
    ])
    error_message = "The edit group should be held to the namespace's secrets - and list nothing."
  }
  assert {
    condition     = strcontains(azurerm_role_assignment.key_vault_namespace_writer["team-payments/writer/33333333-3333-3333-3333-333333333333"].condition, "StringStartsWith 'team-payments--'")
    error_message = "The groups should be held to the namespace's secrets."
  }
  assert {
    condition     = strcontains(azurerm_role_assignment.key_vault_namespace_writer["team-payments/writer/33333333-3333-3333-3333-333333333333"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})")
    error_message = "The groups should list nothing: metadata reads are held to the namespace's secrets."
  }
}

run "namespace_groups_get_nothing_on_a_shared_vault_from_the_cluster" {
  command = plan

  variables {
    key_vault_name      = "kv-sec-test-shared"
    key_vault_create    = false
    flux_git_repository = { url = "https://github.com/example/cluster-config" }
    managed_namespaces = {
      team-payments = { groups = { view = "11111111-1111-1111-1111-111111111111", edit = "22222222-2222-2222-2222-222222222222" } }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.key_vault_namespace_writer) == 0 && length(azurerm_role_assignment.key_vault_namespace_editor) == 0 && length(azurerm_role_definition.key_vault_secrets_editor) == 0
    error_message = "A shared vault's grants are shared/'s: the cells would both make them."
  }
}

# ----------------------------------------------------------------------------------------------
# Gateway API implementation
# ----------------------------------------------------------------------------------------------

run "traefik_serves_every_gateway_from_a_flux_configuration_of_its_own" {
  command = plan

  variables {
    exposure                       = "ext"
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
      ext-se = { node_subnet_name = "snet-ext-se-nodes" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
  }

  assert {
    condition     = keys(azapi_resource.traefik_flux_configuration) == ["ext-fi", "ext-se", "platform"]
    error_message = "Each zone's Gateway and the platform's should get a Traefik Flux configuration."
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
      azapi_resource.traefik_flux_configuration["ext-se"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "false" &&
      azapi_resource.traefik_flux_configuration["platform"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_namespace == "platform-gateway"
    )
    error_message = "Each Traefik configuration should be told its Gateway's namespace and load balancer."
  }
  assert {
    condition = (
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_ext_fi == "traefik-ext-fi" &&
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_platform == "traefik-platform"
    )
    error_message = "The Flux repository should be told each Gateway's Traefik class."
  }
}

run "an_internal_zone_gets_an_internal_traefik_load_balancer" {
  command = plan

  variables {
    exposure                       = "int"
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      int-fi = { node_subnet_name = "snet-int-fi-nodes" }
    }
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
    gateway_implementation = "traefik"
  }

  assert {
    condition = (
      azapi_resource.traefik_flux_configuration["int-fi"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "true" &&
      azapi_resource.traefik_flux_configuration["int-fi"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_exposure == "int" &&
      azapi_resource.traefik_flux_configuration["platform"].body.properties.kustomizations.gateway.postBuild.substitute.gateway_internal == "false"
    )
    error_message = "An internal zone's Traefik should be behind an internal load balancer, the platform's a public one."
  }
}

run "app_routing_serves_every_gateway_without_traefik" {
  command = plan

  variables {
    exposure                       = "ext"
    node_auto_provisioning_enabled = true
    default_node_pool = {
      availability_zones = ["1"]
    }
    isolation_zones = {
      ext-fi = { node_subnet_name = "snet-ext-fi-nodes" }
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
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_ext_fi == "approuting-istio" &&
      azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute.gateway_class_name_platform == "approuting-istio"
    )
    error_message = "Every Gateway should name App Routing's class."
  }
}

run "a_cluster_without_a_gateway_implementation_names_no_class" {
  command = plan

  variables {
    flux_git_repository = {
      url = "https://github.com/example/cluster-config"
    }
  }

  assert {
    condition = length(azapi_resource.traefik_flux_configuration) == 0 && length([
      for key in keys(azapi_resource.flux_configuration[0].body.properties.kustomizations.platform.postBuild.substitute) : key if startswith(key, "gateway_class_name_")
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
