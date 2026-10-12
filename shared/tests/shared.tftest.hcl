# Plan-time behaviour of the environment's shared resources, without touching Azure: the providers
# are mocked.
#
#   cd shared && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "66666666-6666-6666-6666-666666666666"
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

run "grants_can_be_left_to_someone_else" {
  command = plan

  variables {
    create_role_assignments          = false
    key_vault_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition = alltrue([
      length(azurerm_role_assignment.key_vault_namespace_reader) == 0,
      length(azurerm_role_assignment.key_vault_namespace_writer) == 0,
      length(azurerm_role_assignment.key_vault_admin) == 0,
      length(azurerm_user_assigned_identity.key_vault) == 2,
    ])
    error_message = "With create_role_assignments = false the identities are still created, and the grants left to the estate."
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

  expect_failures = [azurerm_user_assigned_identity.key_vault]
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
