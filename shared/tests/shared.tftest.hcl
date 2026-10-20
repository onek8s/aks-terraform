# Plan-time behaviour of the environment's shared resources, without touching Azure: the providers
# are mocked.
#
#   cd shared && terraform test

mock_provider "azurerm" {
  alias = "hub"
}

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "66666666-6666-6666-6666-666666666666"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-sec-test-shared"
      vault_uri = "https://kv-sec-test-shared.vault.azure.net/"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_data "azurerm_dns_zone" {
    defaults = {
      name                = "contoso.com"
      resource_group_name = "rg-dns"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/privateDnsZones/contoso.com"
    }
  }
}
mock_provider "azapi" {}
mock_provider "random" {}

variables {
  environment         = "test"
  location            = "swedencentral"
  resource_group_name = "rg-aks-test"
  key_vault_name      = "kv-sec-test-shared"
  key_vault_namespaces = {
    ingress-gateway = {}
    example = {
      writers = [{ principal_id = "33333333-3333-3333-3333-333333333333" }]
    }
  }
}

run "the_vault_and_the_identities_are_named_as_the_environments" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_key_vault.this.name == "kv-sec-test-shared",
      azurerm_key_vault.this.resource_group_name == "rg-aks-test",
      azurerm_key_vault.this.rbac_authorization_enabled == true,
      azurerm_user_assigned_identity.key_vault["example"].name == "id-sec-test-shared-kv-example",
      azurerm_user_assigned_identity.key_vault["ingress-gateway"].name == "id-sec-test-shared-kv-ingress-gateway",
      azurerm_user_assigned_identity.key_vault["example"].resource_group_name == "rg-aks-test",
    ])
    error_message = "The vault and one identity per namespace should be created, named as the environment's shared ones."
  }
}

# The cluster configuration looks the identities up under names it works out itself - the two have to
# agree, which is what the shared module is for.
run "the_identity_names_are_the_ones_a_cluster_looks_for" {
  command = plan

  module {
    source = "../modules/conventions"
  }

  variables {
    environment          = "test"
    key_vault_namespaces = ["example"]
  }

  assert {
    condition     = output.shared_key_vault_identity_names["example"] == "id-sec-test-shared-kv-example"
    error_message = "The conventions should name the shared identity id-<region>-<environment>-shared-kv-<namespace>."
  }
}

run "each_namespace_reads_and_its_writers_manage_its_own_share" {
  command = plan

  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_reader) == ["example", "ingress-gateway"],
      azurerm_role_assignment.key_vault_namespace_reader["example"].role_definition_name == "Key Vault Secrets User",
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "StringStartsWith 'example--'"),
      keys(azurerm_role_assignment.key_vault_namespace_writer) == ["example/writer/33333333-3333-3333-3333-333333333333"],
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].role_definition_name == "Key Vault Secrets Officer",
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].principal_type == "Group",
      strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
    ])
    error_message = "Each namespace's identity should read, and its writers manage, its own secrets only."
  }
}

run "rejects_a_namespace_whose_share_would_overlap_another" {
  command = plan

  variables {
    key_vault_namespaces = {
      "team--a" = {}
    }
  }

  expect_failures = [var.key_vault_namespaces]
}

run "refuses_a_region_with_no_code" {
  command = plan

  variables {
    location = "brazilsouth"
  }

  expect_failures = [output.names]
}

run "a_registry_is_created_and_builds_its_images" {
  command = plan

  variables {
    container_registry_name = "acrtestshared"
    container_registry_builds = {
      "aks-hello:0.2.0" = {
        repository = "https://github.com/onek8s/aks-hello.git"
        commit     = "0123456789abcdef0123456789abcdef01234567"
      }
    }
  }

  assert {
    condition = alltrue([
      azurerm_container_registry.this[0].admin_enabled == false,
      azurerm_container_registry_task.build["aks-hello:0.2.0"].name == "aks-hello-0_2_0",
      one(azurerm_container_registry_task.build["aks-hello:0.2.0"].docker_step).context_path == "https://github.com/onek8s/aks-hello.git#0123456789abcdef0123456789abcdef01234567",
      contains(one(azurerm_container_registry_task.build["aks-hello:0.2.0"].docker_step).image_names, "aks-hello:0.2.0"),
    ])
    error_message = "The registry should have no admin user, and build aks-hello:0.2.0 from the pinned commit."
  }
}

run "refuses_a_build_of_a_branch" {
  command = plan

  variables {
    container_registry_name = "acrtestshared"
    container_registry_builds = {
      "aks-hello:0.2.0" = {
        repository = "https://github.com/onek8s/aks-hello.git"
        commit     = "main"
      }
    }
  }

  expect_failures = [var.container_registry_builds]
}

run "an_existing_public_zone_is_looked_up" {
  command = plan

  variables {
    dns_zone_name                = "contoso.com"
    dns_zone_create              = false
    dns_zone_resource_group_name = "rg-dns"
  }

  assert {
    condition     = length(azurerm_dns_zone.this) == 0 && data.azurerm_dns_zone.this[0].resource_group_name == "rg-dns"
    error_message = "With dns_zone_create = false the public zone should be looked up in its own resource group, not created."
  }
}

run "the_resource_group_and_the_network_can_be_created" {
  command = plan

  variables {
    resource_group_create         = true
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    subnets                       = { snet-aks-nodes = "172.20.0.0/23" }
  }

  assert {
    condition = alltrue([
      azurerm_resource_group.this[0].name == "rg-aks-test",
      azurerm_virtual_network.this[0].resource_group_name == "rg-aks-test",
      azurerm_subnet.this["snet-aks-nodes"].address_prefixes[0] == "172.20.0.0/23",
    ])
    error_message = "The resource group, the network and its subnet should be created."
  }
}

run "a_global_hostname_is_a_traffic_manager_profile_over_the_clusters" {
  command = plan

  variables {
    dns_zone_name                = "contoso.com"
    dns_zone_create              = false
    dns_zone_resource_group_name = "rg-dns"
    global_hostnames = {
      hello = {
        endpoints   = ["public-aks-test-a.contoso.com", "public-aks-test-b.contoso.com"]
        health_path = "/healthz"
      }
    }
  }

  assert {
    condition = alltrue([
      azurerm_traffic_manager_profile.global["hello"].name == "contoso-com-test-hello",
      azurerm_traffic_manager_profile.global["hello"].traffic_routing_method == "Weighted",
      azurerm_traffic_manager_profile.global["hello"].monitor_config[0].path == "/healthz",
      one(azurerm_traffic_manager_profile.global["hello"].monitor_config[0].custom_header).value == "hello.contoso.com",
      azurerm_traffic_manager_external_endpoint.global["hello/public-aks-test-b.contoso.com"].target == "public-aks-test-b.contoso.com",
      azurerm_dns_cname_record.global["hello"].name == "hello",
    ])
    error_message = "hello.contoso.com should be a CNAME to a weighted profile over both clusters, probed as hello.contoso.com."
  }
}

run "a_private_zone_is_looked_up_and_gets_no_traffic_manager" {
  command = plan

  variables {
    dns_zone_name                = "contoso.com"
    dns_zone_private             = true
    dns_zone_create              = false
    dns_zone_resource_group_name = "rg-dns"
    global_hostnames = {
      hello = { endpoints = ["public-aks-test-a.contoso.com"] }
    }
  }

  assert {
    condition     = length(data.azurerm_private_dns_zone.this) == 1 && length(data.azurerm_dns_zone.this) == 0 && length(azurerm_traffic_manager_profile.global) == 0
    error_message = "A private zone should be looked up in Azure Private DNS, and get no Traffic Manager CNAME."
  }

  expect_failures = [check.global_hostnames_need_a_public_zone]
}

run "a_private_zone_created_here_is_linked_to_the_clusters_network" {
  command = plan

  variables {
    dns_zone_name                 = "contoso.com"
    dns_zone_private              = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_create        = true
    virtual_network_address_space = ["172.20.0.0/22"]
  }

  assert {
    condition = alltrue([
      length(azurerm_dns_zone.this) == 0,
      azurerm_private_dns_zone.this[0].name == "contoso.com",
      azurerm_private_dns_zone_virtual_network_link.this[0].private_dns_zone_name == "contoso.com",
      azurerm_private_dns_zone_virtual_network_link.this[0].registration_enabled != true,
      length(data.azurerm_virtual_network.this) == 0,
    ])
    error_message = "A private zone created here should be linked to the network created here, and no public zone created."
  }
}

run "a_private_zone_on_an_existing_network_links_that_network" {
  command = plan

  variables {
    dns_zone_name        = "contoso.com"
    dns_zone_private     = true
    virtual_network_name = "vnet-aks-test"
  }

  assert {
    condition     = length(data.azurerm_virtual_network.this) == 1 && data.azurerm_virtual_network.this[0].name == "vnet-aks-test" && length(azurerm_private_dns_zone_virtual_network_link.this) == 1
    error_message = "A private zone should be linked to the existing network, looked up by name."
  }
}

run "a_private_zone_without_a_network_resolves_nowhere" {
  command = plan

  variables {
    dns_zone_name    = "contoso.com"
    dns_zone_private = true
  }

  expect_failures = [check.a_created_private_zone_has_a_network_to_resolve_in]
}

run "a_namespace_with_a_zone_reads_the_zone_vault" {
  command = apply

  variables {
    isolation_zones      = { ext-fi = { exposure = "ext", index = 3 } }
    zone_key_vault_names = { ext-fi = "kv-sec-test-ext-fi" }
    key_vault_namespaces = {
      ext-fi-gateway = {}
      ext-fi-orders  = { zone = "ext-fi" }
    }
  }

  assert {
    condition     = azurerm_key_vault.zone["ext-fi"].name == "kv-sec-test-ext-fi" && !azurerm_key_vault.zone["ext-fi"].purge_protection_enabled
    error_message = "The zone's vault is created, without purge protection."
  }
  assert {
    condition     = azurerm_role_assignment.key_vault_namespace_reader["ext-fi-gateway"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-sec-test-shared"
    error_message = "A namespace with no zone - a gateway, for its certificate - reads the platform vault."
  }
  assert {
    condition     = azurerm_role_assignment.key_vault_namespace_reader["ext-fi-orders"].condition == module.conventions.key_vault_read_conditions["ext-fi-orders"]
    error_message = "An application reads its own secrets only, under its prefix."
  }
}

run "rejects_a_namespace_in_a_zone_with_no_vault" {
  command = plan

  # A disabled zone has no vault.
  variables {
    isolation_zones = { ext-fi = { exposure = "ext", index = 3, enabled = false } }
    key_vault_namespaces = {
      ext-fi-orders = { zone = "ext-fi" }
    }
  }

  expect_failures = [var.key_vault_namespaces]
}

run "the_platform_vault_can_hold_customer_managed_keys" {
  command = plan

  variables {
    key_vault_purge_protection_enabled = true
  }

  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled
    error_message = "A disk encryption set needs purge protection on the vault of its key."
  }
}

run "the_external_exposure_holds_only_external_zones" {
  command = plan

  variables {
    exposure = "ext"
    isolation_zones = {
      ext-fi = { exposure = "ext", index = 3 }
      int-fi = { exposure = "int", index = 1 }
    }
  }

  expect_failures = [var.exposure]
}

run "the_external_exposure_has_no_internal_dns" {
  command = plan

  variables {
    exposure           = "ext"
    internal_dns_zones = ["int-fi.test.contoso.com"]
  }

  expect_failures = [var.exposure]
}

run "the_internal_exposure_publishes_nothing_through_traffic_manager" {
  command = plan

  variables {
    exposure                     = "int"
    dns_zone_name                = "contoso.com"
    dns_zone_create              = false
    dns_zone_resource_group_name = "rg-dns"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
    }
    global_hostnames = {
      "hello.ext-fi.dev" = { endpoints = ["hello-a.ext-fi.dev.contoso.com"], zone = "ext-fi" }
    }
  }

  assert {
    condition     = length(azurerm_traffic_manager_profile.global) == 0 && length(azurerm_dns_cname_record.global) == 0
    error_message = "The internal exposure creates no Traffic Manager profile, even with a global hostname listed."
  }
}

run "traffic_manager_only_for_a_deployed_external_zone" {
  command = plan

  variables {
    exposure                     = "ext"
    dns_zone_name                = "contoso.com"
    dns_zone_create              = false
    dns_zone_resource_group_name = "rg-dns"
    isolation_zones = {
      ext-fi = { exposure = "ext", index = 3 }
      ext-se = { exposure = "ext", index = 4, enabled = false }
    }
    global_hostnames = {
      "hello.ext-fi.dev" = { endpoints = ["hello-a.ext-fi.dev.contoso.com"], zone = "ext-fi" }
      "hello.ext-se.dev" = { endpoints = ["hello-a.ext-se.dev.contoso.com"], zone = "ext-se" }
      "hello.ext-dk.dev" = { endpoints = ["hello-a.ext-dk.dev.contoso.com"], zone = "ext-dk" }
    }
  }

  assert {
    condition     = keys(azurerm_traffic_manager_profile.global) == ["hello.ext-fi.dev"]
    error_message = "A profile only for the global hostname of an enabled external zone."
  }
}

run "a_disabled_country_keeps_its_index_and_gets_nothing" {
  command = plan

  variables {
    exposure = "int"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
      int-se = { exposure = "int", index = 2, enabled = false }
    }
    cells = {
      dev-int-stateless-az1 = { address_space = "172.22.0.0/20", pod_address_space = "100.64.0.0/16" }
    }
  }

  assert {
    condition     = sort(keys(azurerm_subnet.cell)) == sort(["dev-int-stateless-az1/snet-system", "dev-int-stateless-az1/snet-system-pods", "dev-int-stateless-az1/snet-int-fi-nodes", "dev-int-stateless-az1/snet-int-fi-pods", "dev-int-stateless-az1/snet-int-fi-ilb"])
    error_message = "No subnet for the disabled int-se."
  }
  assert {
    condition     = length(azurerm_route_table.zone) == 0
    error_message = "No route table without a hub."
  }
}

run "a_disabled_country_gets_no_route_table_but_its_slot_is_still_routed" {
  command = plan

  variables {
    exposure = "int"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
      int-se = { exposure = "int", index = 2, enabled = false }
    }
    cells = {
      dev-int-stateless-az1 = { address_space = "172.22.0.0/20", pod_address_space = "100.64.0.0/16" }
    }
    hub = {
      virtual_network_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-germanywestcentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-germanywestcentral"
      next_hop_ip        = "10.0.1.4"
    }
  }

  assert {
    condition = (
      keys(azurerm_route_table.zone) == ["dev-int-stateless-az1/int-fi"] &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az1/int-fi"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "nodes-via-hub-firewall 172.22.0.0/20 VirtualAppliance") &&
      !contains([for r in azurerm_route_table.zone["dev-int-stateless-az1/int-fi"].route : r.address_prefix], "172.22.2.0/24")
    )
    error_message = "A disabled zone gets no route table; its slot is routed to the firewall from the other zones by the cell's address space, not by a route of its own."
  }
}

run "a_cell_behind_the_hub_firewall" {
  command = plan

  variables {
    exposure = "int"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
    }
    cells = {
      dev-int-stateless-az1 = { address_space = "172.22.0.0/20", pod_address_space = "100.64.0.0/16" }
    }
    internal_dns_zones = ["int-fi.test.contoso.com"]
    hub = {
      virtual_network_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-germanywestcentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-germanywestcentral"
      next_hop_ip        = "10.0.1.4"
      dns_servers        = ["10.0.1.4"]
    }
  }

  assert {
    condition     = contains([for r in azurerm_route_table.cell["dev-int-stateless-az1"].route : "${r.address_prefix} ${coalesce(r.next_hop_in_ip_address, "-")}"], "0.0.0.0/0 10.0.1.4") && !azurerm_route_table.cell["dev-int-stateless-az1"].bgp_route_propagation_enabled
    error_message = "The cell sends everything else to the hub's firewall."
  }
  assert {
    condition     = sort(keys(azurerm_subnet_route_table_association.cell)) == sort(["dev-int-stateless-az1/snet-system", "dev-int-stateless-az1/snet-system-pods", "dev-int-stateless-az1/snet-int-fi-nodes", "dev-int-stateless-az1/snet-int-fi-pods"])
    error_message = "Every node and pod subnet - not the load balancer's - takes a route table."
  }
  assert {
    condition = (
      length(azurerm_route_table.cell["dev-int-stateless-az1"].route) == 5 &&
      toset([for r in azurerm_route_table.cell["dev-int-stateless-az1"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type} ${coalesce(r.next_hop_in_ip_address, "-")}"]) == toset([
        "default-via-hub-firewall 0.0.0.0/0 VirtualAppliance 10.0.1.4",
        "nodes-via-hub-firewall 172.22.0.0/20 VirtualAppliance 10.0.1.4",
        "pods-via-hub-firewall 100.64.0.0/16 VirtualAppliance 10.0.1.4",
        "own-nodes-direct 172.22.0.0/24 VnetLocal -",
        "own-pods-direct 100.64.0.0/20 VnetLocal -",
      ])
    )
    error_message = "The system pool's table (design D73) sends the default route and the cell's two address spaces to the hub's firewall and keeps its own slot inside the virtual network: a zone is reached through the firewall, like it reaches the system pool."
  }
  assert {
    condition     = alltrue([for key, subnet in azurerm_subnet.cell : subnet.private_endpoint_network_policies == "Disabled"])
    error_message = "No subnet applies its route table to a private endpoint: the API server's endpoint answers the system pool's own nodes directly, as they reach it (2026-10-20)."
  }
  assert {
    condition = (
      keys(azurerm_route_table.zone) == ["dev-int-stateless-az1/int-fi"] &&
      !azurerm_route_table.zone["dev-int-stateless-az1/int-fi"].bgp_route_propagation_enabled &&
      length(azurerm_route_table.zone["dev-int-stateless-az1/int-fi"].route) == 6 &&
      toset([for r in azurerm_route_table.zone["dev-int-stateless-az1/int-fi"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type} ${coalesce(r.next_hop_in_ip_address, "-")}"]) == toset([
        "default-via-hub-firewall 0.0.0.0/0 VirtualAppliance 10.0.1.4",
        "nodes-via-hub-firewall 172.22.0.0/20 VirtualAppliance 10.0.1.4",
        "pods-via-hub-firewall 100.64.0.0/16 VirtualAppliance 10.0.1.4",
        "own-nodes-direct 172.22.1.0/24 VnetLocal -",
        "own-pods-direct 100.64.16.0/20 VnetLocal -",
        "own-ilb-via-hub-firewall 172.22.1.128/27 VirtualAppliance 10.0.1.4",
      ])
    )
    error_message = "A zone's table (design D73) sends the default route and the cell's two address spaces to the hub's firewall, keeps the zone's own node and pod slots inside the virtual network, and sends even its own load balancer to the firewall - the system pool's slot included, so the Kubernetes flows meet the firewall symmetrically."
  }
  assert {
    condition = (
      azurerm_network_security_rule.cell_allow["dev-int-stateless-az1/snet-int-fi-nodes/icmp-from-hub-firewall"].source_address_prefix == "10.0.1.4" &&
      azurerm_network_security_rule.cell_allow["dev-int-stateless-az1/snet-system/icmp-from-hub-firewall"].protocol == "Icmp" &&
      length([for k in keys(azurerm_network_security_rule.cell_allow) : k if endswith(k, "/icmp-from-hub-firewall")]) == 4
    )
    error_message = "The nodes answer ping from the hub firewall's address, and nothing wider."
  }
  assert {
    condition     = tolist(azurerm_virtual_network.cell["dev-int-stateless-az1"].dns_servers) == tolist(["10.0.1.4"])
    error_message = "The cell resolves through the hub firewall's DNS proxy."
  }
  assert {
    condition     = azurerm_virtual_network_peering.hub_to_cell["dev-int-stateless-az1"].virtual_network_name == "vnet-hub-germanywestcentral" && azurerm_virtual_network_peering.hub_to_cell["dev-int-stateless-az1"].resource_group_name == "rg-hub-germanywestcentral" && azurerm_virtual_network_peering.cell_to_hub["dev-int-stateless-az1"].allow_forwarded_traffic
    error_message = "The cell and the hub are peered both ways."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.internal_hub["int-fi.test.contoso.com"].name == "vnet-hub-germanywestcentral"
    error_message = "The internal zones' names resolve in the hub, for its DNS proxy."
  }
}

run "an_external_exposure_with_its_zones_plans" {
  command = plan

  variables {
    exposure              = "ext"
    resource_group_create = true
    isolation_zones = {
      ext-fi = { exposure = "ext", index = 3 }
      ext-se = { exposure = "ext", index = 4 }
    }
    cells = {
      dev-ext-stateless-az1 = { address_space = "172.21.0.0/20", pod_address_space = "100.64.0.0/16" }
    }
  }

  assert {
    condition     = length(azurerm_network_security_group.cell) == 8
    error_message = "An external cell has the system pool's subnets and the two external zones' nodes, pods and load balancer subnets."
  }
  assert {
    condition     = output.exposure == "ext"
    error_message = "The stack says which exposure it serves."
  }
}

run "a_cell_has_a_subnet_and_an_nsg_per_zone" {
  command = plan

  variables {
    resource_group_create = true
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
      ext-fi = { exposure = "ext", index = 3 }
    }
    cells = {
      dev-ext-stateless-az1 = { address_space = "172.21.0.0/20", pod_address_space = "100.64.0.0/16" }
    }
    internal_dns_zones = ["int-fi.test.contoso.com"]
  }

  assert {
    condition     = azurerm_virtual_network.cell["dev-ext-stateless-az1"].name == "vnet-dev-ext-stateless-az1" && azurerm_virtual_network.cell["dev-ext-stateless-az1"].encryption[0].enforcement == "AllowUnencrypted"
    error_message = "Every cell has a network of its own, with VNet encryption."
  }
  assert {
    condition = (
      azurerm_subnet.cell["dev-ext-stateless-az1/snet-system"].address_prefixes[0] == "172.21.0.0/24" &&
      azurerm_subnet.cell["dev-ext-stateless-az1/snet-int-fi-nodes"].address_prefixes[0] == "172.21.1.0/25" &&
      azurerm_subnet.cell["dev-ext-stateless-az1/snet-int-fi-ilb"].address_prefixes[0] == "172.21.1.128/27" &&
      azurerm_subnet.cell["dev-ext-stateless-az1/snet-ext-fi-nodes"].address_prefixes[0] == "172.21.3.0/25" &&
      length(azurerm_subnet.cell["dev-ext-stateless-az1/snet-system"].delegation) == 0
    )
    error_message = "The system pool takes the first /24, each zone the /24 of its index: nodes in the first half, the internal load balancer in a /27 of the second."
  }
  assert {
    condition     = length(azurerm_network_security_group.cell) == 8 && length(azurerm_network_security_rule.cell_deny) == 8
    error_message = "Every subnet has an NSG of its own that denies what it does not allow."
  }
  assert {
    condition = (
      azurerm_network_security_rule.cell_allow["dev-ext-stateless-az1/snet-ext-fi-nodes/https"].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.cell_allow["dev-ext-stateless-az1/snet-int-fi-nodes/https"].source_address_prefix == "VirtualNetwork" &&
      azurerm_network_security_rule.cell_allow["dev-ext-stateless-az1/snet-system/https"].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.cell_allow["dev-ext-stateless-az1/snet-system/https-from-network"].source_address_prefix == "VirtualNetwork"
    )
    error_message = "HTTPS comes from the internet to the external zones, from the network to the internal zones, and from both to the system pool, where every zone's gateway runs."
  }
  assert {
    condition     = !contains(keys(azurerm_network_security_rule.cell_allow), "dev-ext-stateless-az1/snet-ext-fi-ilb/https")
    error_message = "An external zone's load balancer is public: its internal load balancer subnet lets nothing in."
  }
  assert {
    condition     = azurerm_network_security_rule.cell_allow["dev-ext-stateless-az1/snet-ext-fi-nodes/kubelet-from-system"].source_address_prefix == "172.21.0.0/24"
    error_message = "Only the system pool reaches a zone's kubelets."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.internal["int-fi.test.contoso.com/dev-ext-stateless-az1"].name == "vnet-dev-ext-stateless-az1"
    error_message = "The internal zones' names resolve in every cell."
  }
}

run "a_cell_has_pod_subnets_in_a_second_address_space" {
  command = plan

  variables {
    exposure = "int"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
      int-se = { exposure = "int", index = 2 }
    }
    cells = {
      dev-int-stateless-az3 = { address_space = "10.100.0.0/16", pod_address_space = "100.64.0.0/16" }
    }
    internal_dns_zones = ["int-fi.test.contoso.com"]
    hub = {
      virtual_network_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
      next_hop_ip        = "10.0.1.4"
      dns_servers        = ["10.0.1.4"]
    }
  }

  assert {
    condition = (
      toset(azurerm_virtual_network.cell["dev-int-stateless-az3"].address_space) == toset(["10.100.0.0/16", "100.64.0.0/16"])
    )
    error_message = "A cell's network has the pods' address space beside the nodes'."
  }
  assert {
    condition = (
      azurerm_subnet.cell["dev-int-stateless-az3/snet-system"].address_prefixes == tolist(["10.100.0.0/24"]) &&
      azurerm_subnet.cell["dev-int-stateless-az3/snet-int-se-nodes"].address_prefixes == tolist(["10.100.2.0/25"]) &&
      azurerm_subnet.cell["dev-int-stateless-az3/snet-int-se-ilb"].address_prefixes == tolist(["10.100.2.128/27"]) &&
      azurerm_subnet.cell["dev-int-stateless-az3/snet-system-pods"].address_prefixes == tolist(["100.64.0.0/20"]) &&
      azurerm_subnet.cell["dev-int-stateless-az3/snet-int-fi-pods"].address_prefixes == tolist(["100.64.16.0/20"]) &&
      azurerm_subnet.cell["dev-int-stateless-az3/snet-int-se-pods"].address_prefixes == tolist(["100.64.32.0/20"]) &&
      one(azurerm_subnet.cell["dev-int-stateless-az3/snet-int-se-pods"].delegation).service_delegation[0].name == "Microsoft.ContainerService/managedClusters" &&
      length(azurerm_subnet.cell["dev-int-stateless-az3/snet-int-se-nodes"].delegation) == 0
    )
    error_message = "Nodes and load balancers keep /24 slots in any address space; the pods take the /20 of the same slot in the pod address space."
  }
  assert {
    condition = (
      toset(azurerm_network_security_rule.cell_allow["dev-int-stateless-az3/snet-int-se-nodes/pods"].source_address_prefixes) == toset(["100.64.0.0/20", "100.64.16.0/20", "100.64.32.0/20"]) &&
      toset(azurerm_network_security_rule.cell_allow["dev-int-stateless-az3/snet-int-se-pods/pods"].source_address_prefixes) == toset(["100.64.0.0/20", "100.64.16.0/20", "100.64.32.0/20"]) &&
      azurerm_network_security_rule.cell_allow["dev-int-stateless-az3/snet-system-pods/https-from-network"].source_address_prefix == "VirtualNetwork" &&
      azurerm_network_security_rule.cell_allow["dev-int-stateless-az3/snet-int-se-pods/https"].source_address_prefix == "VirtualNetwork"
    )
    error_message = "The pods are let in from the cell's pod subnets, which take their pool's rules."
  }
  assert {
    condition = (
      contains(keys(azurerm_subnet_route_table_association.cell), "dev-int-stateless-az3/snet-system-pods") &&
      contains(keys(azurerm_subnet_route_table_association.cell), "dev-int-stateless-az3/snet-int-se-pods") &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "nodes-via-hub-firewall 10.100.0.0/16 VirtualAppliance") &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "pods-via-hub-firewall 100.64.0.0/16 VirtualAppliance") &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "own-nodes-direct 10.100.2.0/24 VnetLocal") &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "own-pods-direct 100.64.32.0/20 VnetLocal") &&
      contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "own-ilb-via-hub-firewall 10.100.2.128/27 VirtualAppliance") &&
      !contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : r.address_prefix], "10.100.1.0/24") &&
      !contains([for r in azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route : r.address_prefix], "100.64.0.0/20") &&
      length(azurerm_route_table.zone["dev-int-stateless-az3/int-se"].route) == 6 &&
      contains([for r in azurerm_route_table.cell["dev-int-stateless-az3"].route : "${r.name} ${r.address_prefix} ${r.next_hop_type}"], "own-pods-direct 100.64.0.0/20 VnetLocal") &&
      length(azurerm_route_table.cell["dev-int-stateless-az3"].route) == 5
    )
    error_message = "A pod subnet takes its pool's route table, and the zone table routes the cell's pod address space to the firewall too - only the zone's own pod slot stays in the virtual network; the system pool's table does the same for its own."
  }
}

run "rejects_a_cell_whose_pods_are_outside_the_shared_address_space" {
  command = plan

  variables {
    cells = {
      dev-int-stateless-az3 = { address_space = "10.100.0.0/16", pod_address_space = "172.23.0.0/16" }
    }
  }

  expect_failures = [var.cells]
}

run "rejects_a_cell_that_is_not_a_slash_16_to_20" {
  command = plan

  variables {
    cells = {
      dev-ext-stateless-az1 = { address_space = "172.21.0.0/22", pod_address_space = "100.64.0.0/16" }
    }
  }

  expect_failures = [var.cells]
}

run "a_global_hostname_below_the_zone_has_a_profile_name_without_dots" {
  command = plan

  variables {
    dns_zone_name   = "contoso.com"
    dns_zone_create = false
    global_hostnames = {
      "hello.ext-fi.dev" = { endpoints = ["hello-a.ext-fi.dev.contoso.com"] }
    }
  }

  assert {
    condition     = azurerm_traffic_manager_profile.global["hello.ext-fi.dev"].name == "contoso-com-test-hello-ext-fi-dev"
    error_message = "A profile's name has no dots."
  }
  assert {
    condition     = azurerm_dns_cname_record.global["hello.ext-fi.dev"].name == "hello.ext-fi.dev"
    error_message = "The record keeps the hostname."
  }
}

# Image signing: a code signing certificate whose key never leaves the vault, and the verifier's
# identity able to read the signatures and that one certificate - nothing else in the vault.
run "image_signing_has_a_certificate_and_a_verifier_identity" {
  command = plan

  variables {
    container_registry_name = "acrtestshared"
    image_signing = {
      subject = "CN=Test image signing, O=OneK8s, ST=Uusimaa, C=FI"
    }
  }

  assert {
    condition = alltrue([
      azurerm_key_vault_certificate.image_signing[0].name == "image-signing",
      one(one(azurerm_key_vault_certificate.image_signing[0].certificate_policy).issuer_parameters).name == "Self",
      one(one(azurerm_key_vault_certificate.image_signing[0].certificate_policy).key_properties).exportable == false,
      tolist(one(one(azurerm_key_vault_certificate.image_signing[0].certificate_policy).x509_certificate_properties).key_usage) == tolist(["digitalSignature"]),
      tolist(one(one(azurerm_key_vault_certificate.image_signing[0].certificate_policy).x509_certificate_properties).extended_key_usage) == tolist(["1.3.6.1.5.5.7.3.3"]),
      one(one(azurerm_key_vault_certificate.image_signing[0].certificate_policy).x509_certificate_properties).validity_in_months == 12,
    ])
    error_message = "The signing certificate should be self-signed, code signing only, with a key that cannot be exported."
  }

  assert {
    condition     = azurerm_user_assigned_identity.image_verification[0].name == "id-sec-test-shared-ratify"
    error_message = "The verifier's identity should be named the way the clusters look for it."
  }

  assert {
    condition = (
      azurerm_role_assignment.image_verification["registry"].role_definition_name == "AcrPull" &&
      azurerm_role_assignment.image_verification["certificate"].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.image_verification["certificate"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-sec-test-shared/secrets/image-signing"
    )
    error_message = "The verifier should pull from the registry and read the signing certificate's secret alone, not the vault."
  }

  assert {
    condition     = length(local.image_verification_grants) == 2
    error_message = "The verifier should get exactly the two grants."
  }
}

run "no_image_signing_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_key_vault_certificate.image_signing) == 0 && length(azurerm_user_assigned_identity.image_verification) == 0
    error_message = "Without image_signing there is no certificate and no verifier identity."
  }
}

run "image_signing_needs_a_registry" {
  command = plan

  variables {
    image_signing = {
      subject = "CN=Test image signing, O=OneK8s, ST=Uusimaa, C=FI"
    }
  }

  expect_failures = [var.image_signing]
}

run "refuses_a_signing_subject_without_a_country" {
  command = plan

  variables {
    container_registry_name = "acrtestshared"
    image_signing = {
      subject = "CN=Test image signing, O=OneK8s, ST=Uusimaa"
    }
  }

  expect_failures = [var.image_signing]
}

run "the_workspace_takes_only_entra_id_and_caps_its_ingestion" {
  command = plan

  variables {
    log_analytics_workspace_name = "log-test-platform"
  }

  assert {
    condition = alltrue([
      azurerm_log_analytics_workspace.platform[0].name == "log-test-platform",
      azurerm_log_analytics_workspace.platform[0].local_authentication_enabled == false,
      azurerm_log_analytics_workspace.platform[0].daily_quota_gb == 1,
      azurerm_log_analytics_workspace.platform[0].retention_in_days == 30,
    ])
    error_message = "The workspace should accept only Entra ID, keep 30 days and cap ingestion at 1 GB a day."
  }
}

# The monthly budget: the whole subscription, the Owners told at 80 % and 100 % of actual cost and at
# a forecast of 100 %.
run "the_budget_covers_the_subscription_and_tells_its_owners" {
  command = plan

  variables {
    monthly_budget = {
      amount     = 600
      start_date = "2026-10-01T00:00:00Z"
    }
  }

  assert {
    condition     = azurerm_consumption_budget_subscription.this[0].subscription_id == "/subscriptions/00000000-0000-0000-0000-000000000000" && azurerm_consumption_budget_subscription.this[0].amount == 600
    error_message = "The budget should cover the subscription with the amount given."
  }
  assert {
    condition = toset([for n in azurerm_consumption_budget_subscription.this[0].notification : "${n.threshold_type}-${n.threshold}"]) == toset(["Actual-80", "Actual-100", "Forecasted-100"]) && alltrue([
      for n in azurerm_consumption_budget_subscription.this[0].notification : n.contact_roles == tolist(["Owner"])
    ])
    error_message = "The Owners should hear at 80 % and 100 % of actual cost and at a forecast of 100 %."
  }
}

run "no_budget_unless_asked" {
  command = plan

  assert {
    condition     = length(azurerm_consumption_budget_subscription.this) == 0
    error_message = "No budget without monthly_budget."
  }
}

run "rejects_a_budget_start_that_is_not_the_first_of_a_month" {
  command = plan

  variables {
    monthly_budget = {
      amount     = 600
      start_date = "2026-10-13T00:00:00Z"
    }
  }

  expect_failures = [var.monthly_budget]
}

# A namespace's groups (the clusters' managed_namespaces.<ns>.groups) get on its share what their
# Kubernetes role gets on Secrets: edit and admin manage its secrets, view gets nothing.
run "a_namespaces_groups_get_their_kubernetes_role_on_its_share" {
  command = plan

  variables {
    key_vault_namespaces = {
      example = {
        groups = {
          view  = "AAAAAAAA-1111-1111-1111-111111111111"
          edit  = "22222222-2222-2222-2222-222222222222"
          admin = "44444444-4444-4444-4444-444444444444"
        }
        # A writer that is also the edit group is granted once.
        writers = [{ principal_id = "22222222-2222-2222-2222-222222222222" }]
      }
      other = {}
    }
  }

  assert {
    condition = toset(keys(azurerm_role_assignment.key_vault_namespace_writer)) == toset([
      "example/writer/22222222-2222-2222-2222-222222222222",
      "example/writer/44444444-4444-4444-4444-444444444444",
    ])
    error_message = "The admin group and the writers should manage the namespace's secrets, each once - an edit group that is also a writer stays one - and the view group get nothing."
  }
  assert {
    condition = alltrue([
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/44444444-4444-4444-4444-444444444444"].role_definition_name == "Key Vault Secrets Officer",
      strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/44444444-4444-4444-4444-444444444444"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
    ])
    error_message = "The admin group should be held to the namespace's secrets by its condition."
  }
  assert {
    condition     = length(azurerm_role_assignment.key_vault_namespace_editor) == 0
    error_message = "An edit group that is also a writer should not get the narrower Secrets Editor role too."
  }
}

# An edit group writes and updates the namespace's secrets and reads their attributes, never a value:
# a custom role at the resource group, under the namespace's condition.
run "an_edit_group_writes_secrets_without_reading_them" {
  command = plan

  variables {
    key_vault_namespaces = {
      example = {
        groups = {
          edit  = "22222222-2222-2222-2222-222222222222"
          admin = "44444444-4444-4444-4444-444444444444"
        }
      }
    }
  }

  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_writer) == ["example/writer/44444444-4444-4444-4444-444444444444"],
      keys(azurerm_role_assignment.key_vault_namespace_editor) == ["example/editor/22222222-2222-2222-2222-222222222222"],
      azurerm_role_assignment.key_vault_namespace_editor["example/editor/22222222-2222-2222-2222-222222222222"].principal_type == "Group",
      strcontains(azurerm_role_assignment.key_vault_namespace_editor["example/editor/22222222-2222-2222-2222-222222222222"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
      strcontains(azurerm_role_assignment.key_vault_namespace_editor["example/editor/22222222-2222-2222-2222-222222222222"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})"),
      # Azure refuses a condition naming an action the role lacks (InvalidRoleAssignmentCondition).
      !strcontains(azurerm_role_assignment.key_vault_namespace_editor["example/editor/22222222-2222-2222-2222-222222222222"].condition, "getSecret"),
      !strcontains(azurerm_role_assignment.key_vault_namespace_editor["example/editor/22222222-2222-2222-2222-222222222222"].condition, "secrets/delete"),
    ])
    error_message = "The edit group should get the Secrets Editor role, held to the namespace's secrets; the admin group Secrets Officer."
  }
  assert {
    condition = alltrue([
      toset(one(azurerm_role_definition.key_vault_secrets_editor[0].permissions).data_actions) == toset([
        "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
        "Microsoft.KeyVault/vaults/secrets/setSecret/action",
        "Microsoft.KeyVault/vaults/secrets/update/action",
      ]),
      length(coalesce(one(azurerm_role_definition.key_vault_secrets_editor[0].permissions).actions, [])) == 0,
      azurerm_role_definition.key_vault_secrets_editor[0].name == "OneK8s Key Vault Secrets Editor (${var.resource_group_name})",
      azurerm_role_definition.key_vault_secrets_editor[0].assignable_scopes == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}"]),
    ])
    error_message = "The role should write, update and read the attributes of secrets - never getSecret, delete or purge - defined and assignable at the resource group."
  }
}

run "no_edit_groups_no_editor_role" {
  command = plan

  assert {
    condition     = length(azurerm_role_definition.key_vault_secrets_editor) == 0 && length(azurerm_role_assignment.key_vault_namespace_editor) == 0
    error_message = "Without edit groups there should be no custom role."
  }
}

run "rejects_a_namespace_group_that_is_not_an_object_id" {
  command = plan

  variables {
    key_vault_namespaces = {
      example = { groups = { view = "example-readers" } }
    }
  }

  expect_failures = [var.key_vault_namespaces]
}

# Soft multi-tenancy: a namespace's identity and writers read and manage its secrets by name and list
# nothing - the name condition covers readMetadata, which a list call is evaluated on as a whole.
run "no_namespace_lists_the_vault" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})"),
      strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].condition, "!(ActionMatches{'Microsoft.KeyVault/vaults/secrets/readMetadata/action'})"),
    ])
    error_message = "Reading metadata - and so listing the vault - should be held to the namespace's secrets for readers and writers alike."
  }
}

# The platform viewers list namespaces and secrets - names only - through a custom role defined and
# assigned at the resource group, nothing at the subscription.
run "platform_viewers_list_namespaces_and_secrets_from_a_resource_group_role" {
  command = plan

  variables {
    platform_viewer_group_object_ids = ["99999999-9999-9999-9999-999999999999"]
  }

  assert {
    condition = alltrue([
      azurerm_role_definition.platform_viewer[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}",
      azurerm_role_definition.platform_viewer[0].assignable_scopes == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}"]),
      azurerm_role_definition.platform_viewer[0].name == "OneK8s Platform Viewer (${var.resource_group_name})",
    ])
    error_message = "The role should be defined at the resource group and assignable only there."
  }
  assert {
    condition = toset(one(azurerm_role_definition.platform_viewer[0].permissions).data_actions) == toset([
      "Microsoft.ContainerService/managedClusters/namespaces/read",
      "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
    ])
    error_message = "The role's data plane should be listing namespaces and secret metadata, nothing more - no secret value, nothing inside a namespace."
  }
  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.platform_viewer) == ["99999999-9999-9999-9999-999999999999"],
      azurerm_role_assignment.platform_viewer["99999999-9999-9999-9999-999999999999"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}",
      azurerm_role_assignment.platform_viewer["99999999-9999-9999-9999-999999999999"].principal_type == "Group",
    ])
    error_message = "Each platform viewer group should get the role on the resource group."
  }
}

run "no_platform_viewers_no_role" {
  command = plan

  assert {
    condition     = length(azurerm_role_definition.platform_viewer) == 0 && length(azurerm_role_assignment.platform_viewer) == 0
    error_message = "Without platform viewer groups there should be no custom role."
  }
}

run "rejects_a_platform_viewer_group_that_is_not_an_object_id" {
  command = plan

  variables {
    platform_viewer_group_object_ids = ["platform-viewers"]
  }

  expect_failures = [var.platform_viewer_group_object_ids]
}

run "a_disabled_cell_keeps_its_address_space_but_gets_no_network" {
  command = plan

  variables {
    exposure = "int"
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
    }
    cells = {
      dev-int-stateless-az1 = { address_space = "172.22.0.0/20", pod_address_space = "100.64.0.0/16", enabled = false }
      dev-int-stateless-az2 = { address_space = "172.22.16.0/20", pod_address_space = "100.64.0.0/16" }
    }
    hub = {
      virtual_network_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-germanywestcentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-germanywestcentral"
      next_hop_ip        = "10.0.1.4"
    }
  }

  assert {
    condition     = keys(azurerm_virtual_network.cell) == ["dev-int-stateless-az2"] && keys(azurerm_route_table.cell) == ["dev-int-stateless-az2"] && keys(azurerm_route_table.zone) == ["dev-int-stateless-az2/int-fi"] && keys(azurerm_virtual_network_peering.hub_to_cell) == ["dev-int-stateless-az2"]
    error_message = "Only the enabled cell gets a network, its route tables and a hub peering."
  }
  assert {
    condition     = azurerm_subnet.cell["dev-int-stateless-az2/snet-int-fi-nodes"].address_prefixes[0] == "172.22.17.0/25"
    error_message = "The enabled cell's zone takes the /24 of its index in the cell's own address space."
  }
}

run "private_endpoints_for_the_vaults_and_the_registry" {
  command = plan

  variables {
    resource_group_create         = true
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    subnets                       = { snet-aks-nodes = "172.20.0.0/23" }
    isolation_zones               = { int-fi = { exposure = "int", index = 1 } }
    zone_key_vault_names          = { int-fi = "kv-test-int-fi" }
    container_registry_name       = "acrtest"
    container_registry_sku        = "Premium"
    private_endpoints = {
      address_prefix             = "172.20.2.0/26"
      dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns"
    }
    hub = {
      virtual_network_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub"
      next_hop_ip        = "10.0.1.4"
    }
  }

  assert {
    condition     = sort(keys(azurerm_private_endpoint.this)) == sort(["kv-platform", "kv-int-fi", "acr"])
    error_message = "Every vault and the registry get a private endpoint."
  }
  assert {
    condition     = tolist(azurerm_private_endpoint.this["acr"].private_service_connection[0].subresource_names) == tolist(["registry"]) && one(azurerm_private_endpoint.this["kv-int-fi"].private_dns_zone_group).private_dns_zone_ids[0] == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    error_message = "The endpoints register in the hub's private link zones."
  }
  assert {
    condition     = azurerm_container_registry.this[0].data_endpoint_enabled && length(azurerm_virtual_network_peering.hub_to_environment) == 1
    error_message = "A Premium registry gets a dedicated data endpoint; the environment network is peered with the hub."
  }
}

run "no_public_network_access" {
  command = plan

  variables {
    resource_group_create         = true
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    subnets                       = { snet-aks-nodes = "172.20.0.0/23" }
    isolation_zones               = { int-fi = { exposure = "int", index = 1 } }
    zone_key_vault_names          = { int-fi = "kv-test-int-fi" }
    container_registry_name       = "acrtest"
    container_registry_sku        = "Premium"
    log_analytics_workspace_name  = "log-test"
    ai_foundry                    = { name = "ais-test", location = "swedencentral" }
    private_endpoints = {
      address_prefix             = "172.20.2.0/26"
      dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns"
      state_storage_account_id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-tfstate/providers/Microsoft.Storage/storageAccounts/sttest"
      public_network_access      = false
    }
  }

  assert {
    condition     = sort(keys(azurerm_private_endpoint.this)) == sort(["kv-platform", "kv-int-fi", "acr", "foundry", "state"])
    error_message = "Foundry and the state account get private endpoints too."
  }
  assert {
    condition = (
      length(one(azurerm_private_endpoint.this["foundry"].private_dns_zone_group).private_dns_zone_ids) == 3 &&
      tolist(azurerm_private_endpoint.this["state"].private_service_connection[0].subresource_names) == tolist(["blob"]) &&
      azurerm_private_endpoint.this["state"].name == "pe-sttest"
    )
    error_message = "Foundry registers in its three zones, the state account's blob endpoint in the blob zone."
  }
  assert {
    condition = (
      !azurerm_key_vault.this.public_network_access_enabled && !azurerm_key_vault.zone["int-fi"].public_network_access_enabled &&
      azurerm_key_vault.this.network_acls[0].bypass == "AzureServices" &&
      !azurerm_container_registry.this[0].public_network_access_enabled && azurerm_container_registry.this[0].network_rule_bypass_for_tasks_enabled &&
      !azurerm_cognitive_account.agents[0].public_network_access_enabled &&
      !azurerm_log_analytics_workspace.platform[0].internet_query_enabled && !azurerm_log_analytics_workspace.platform[0].internet_ingestion_enabled &&
      azapi_update_resource.state_storage[0].body.properties.publicNetworkAccess == "Disabled" &&
      !azapi_update_resource.state_storage[0].body.properties.allowSharedKeyAccess
    )
    error_message = "No service answers publicly; Azure's trusted services (disk encryption, KMS, ACR Tasks) keep their way in."
  }
}

run "a_basic_registry_gets_no_private_endpoint" {
  command = plan

  variables {
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    container_registry_name       = "acrtest"
    private_endpoints = {
      address_prefix             = "172.20.2.0/26"
      dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns"
    }
  }

  assert {
    condition     = keys(azurerm_private_endpoint.this) == ["kv-platform"] && !azurerm_container_registry.this[0].data_endpoint_enabled
    error_message = "Only the vaults get endpoints while the registry is Basic (Azure offers it none)."
  }
}

run "the_registry_tier_follows_the_environment_basic_below_prd" {
  command = plan

  variables {
    environment                   = "acc"
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    container_registry_name       = "acrtest"
    private_endpoints = {
      address_prefix             = "172.20.2.0/26"
      dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns"
      public_network_access      = false
    }
  }

  assert {
    condition = (
      azurerm_container_registry.this[0].sku == "Basic" &&
      azurerm_container_registry.this[0].public_network_access_enabled &&
      !azurerm_container_registry.this[0].data_endpoint_enabled &&
      !azurerm_container_registry.this[0].network_rule_bypass_for_tasks_enabled &&
      !azurerm_container_registry.this[0].admin_enabled &&
      !contains(keys(azurerm_private_endpoint.this), "acr")
    )
    error_message = "Below prd the registry is Basic on its public endpoint (D62), even where the other services are private; admin user off."
  }
}

run "the_registry_tier_follows_the_environment_premium_in_prd" {
  command = plan

  variables {
    environment                   = "prd"
    virtual_network_create        = true
    virtual_network_name          = "vnet-aks-test"
    virtual_network_address_space = ["172.20.0.0/22"]
    container_registry_name       = "acrtest"
    private_endpoints = {
      address_prefix             = "172.20.2.0/26"
      dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns"
      public_network_access      = false
    }
  }

  assert {
    condition = (
      azurerm_container_registry.this[0].sku == "Premium" &&
      !azurerm_container_registry.this[0].public_network_access_enabled &&
      azurerm_container_registry.this[0].data_endpoint_enabled &&
      azurerm_container_registry.this[0].network_rule_bypass_for_tasks_enabled &&
      contains(keys(azurerm_private_endpoint.this), "acr")
    )
    error_message = "In prd the registry is Premium with its private endpoint and no public network access (D62)."
  }
}

run "an_explicit_registry_sku_wins" {
  command = plan

  variables {
    environment             = "prd"
    container_registry_name = "acrtest"
    container_registry_sku  = "Standard"
  }

  assert {
    condition     = azurerm_container_registry.this[0].sku == "Standard" && azurerm_container_registry.this[0].public_network_access_enabled
    error_message = "container_registry_sku overrides the environment's default."
  }
}

run "no_claude_deployment_without_the_organisations_attestation" {
  command = plan

  variables {
    ai_foundry = {
      name     = "ais-onek8s-dev-agents"
      location = "swedencentral"
    }
  }

  assert {
    condition     = length(azurerm_cognitive_account.agents) == 1 && length(azapi_resource.agents_model) == 0
    error_message = "Anthropic's terms are accepted only in the name of an organisation the configuration names."
  }
}

run "the_agents_model_endpoint_takes_entra_id_only" {
  command = plan

  variables {
    ai_foundry = {
      name     = "ais-onek8s-dev-agents"
      location = "swedencentral"
      model_provider = {
        organization_name = "Contoso"
        country_code      = "FI"
      }
    }
  }

  assert {
    condition = (
      !azurerm_cognitive_account.agents[0].local_auth_enabled &&
      azapi_resource.agents_model[0].body.properties.model.format == "Anthropic" &&
      azapi_resource.agents_model[0].body.properties.model.name == "claude-sonnet-5-5" &&
      azapi_resource.agents_model[0].body.properties.modelProviderData.industry == "technology" &&
      azurerm_role_assignment.agents_model_user[0].role_definition_name == "Cognitive Services User"
    )
    error_message = "A Claude deployment behind Entra ID, usable by the identity that runs the agents."
  }
}

run "the_agents_openai_models_on_the_same_resource" {
  command = plan

  variables {
    ai_foundry = {
      name     = "ais-onek8s-dev-agents"
      location = "swedencentral"
      openai_deployments = {
        "gpt-4.1-mini" = { version = "2025-04-14", capacity = 100 }
      }
    }
  }

  assert {
    condition = (
      azurerm_cognitive_deployment.agents_openai["gpt-4.1-mini"].model[0].format == "OpenAI" &&
      azurerm_cognitive_deployment.agents_openai["gpt-4.1-mini"].sku[0].capacity == 100 &&
      length(azapi_resource.agents_model) == 0
    )
    error_message = "An OpenAI model is a deployment of its own on the agents' resource."
  }
}

run "the_webhook_token_is_flux_systems" {
  command = plan

  variables {
    flux_github_webhook = true
    key_vault_namespaces = {
      flux-system = {}
    }
  }

  assert {
    condition     = azurerm_key_vault_secret.flux_github_webhook[0].name == "flux-system--github-webhook-token"
    error_message = "The webhook's token should be in flux-system's share of the vault."
  }
}

run "the_webhook_token_needs_flux_system_to_have_a_share" {
  command = plan

  variables {
    flux_github_webhook = true
  }

  expect_failures = [azurerm_key_vault_secret.flux_github_webhook]
}

run "a_team_namespace_gets_the_webhook_token_in_its_share" {
  command = plan

  variables {
    key_vault_namespaces = {
      flux-system = {}
      example     = {}
    }
    flux_github_webhook            = true
    flux_github_webhook_namespaces = ["example"]
  }

  assert {
    condition     = azurerm_key_vault_secret.flux_github_webhook_namespace["example"].name == "example--github-webhook-token"
    error_message = "The example namespace should get the webhook token in its own share of the vault."
  }
}
