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

run "a_namespace_with_a_zone_reads_the_zone_vault" {
  command = apply

  variables {
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

  variables {
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

run "a_cell_has_a_subnet_and_an_nsg_per_zone" {
  command = plan

  variables {
    resource_group_create = true
    isolation_zones = {
      int-fi = { exposure = "int", index = 1 }
      ext-fi = { exposure = "ext", index = 3 }
    }
    cells = {
      dev-stateless-az1 = { address_space = "172.21.0.0/20" }
    }
    internal_dns_zones = ["int-fi.test.contoso.com"]
  }

  assert {
    condition     = azurerm_virtual_network.cell["dev-stateless-az1"].name == "vnet-dev-stateless-az1" && azurerm_virtual_network.cell["dev-stateless-az1"].encryption[0].enforcement == "AllowUnencrypted"
    error_message = "Every cell has a network of its own, with VNet encryption."
  }
  assert {
    condition = (
      azurerm_subnet.cell["dev-stateless-az1/snet-system"].address_prefixes[0] == "172.21.0.0/24" &&
      azurerm_subnet.cell["dev-stateless-az1/snet-int-fi-nodes"].address_prefixes[0] == "172.21.1.0/25" &&
      azurerm_subnet.cell["dev-stateless-az1/snet-int-fi-ilb"].address_prefixes[0] == "172.21.1.128/27" &&
      azurerm_subnet.cell["dev-stateless-az1/snet-ext-fi-nodes"].address_prefixes[0] == "172.21.3.0/25"
    )
    error_message = "The system pool takes the first /24, each zone the /24 of its index: nodes in the first half, the internal load balancer in a /27 of the second."
  }
  assert {
    condition     = length(azurerm_network_security_group.cell) == 5 && length(azurerm_network_security_rule.cell_deny) == 5
    error_message = "Every subnet has an NSG of its own that denies what it does not allow."
  }
  assert {
    condition = (
      azurerm_network_security_rule.cell_allow["dev-stateless-az1/snet-ext-fi-nodes/https"].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.cell_allow["dev-stateless-az1/snet-int-fi-nodes/https"].source_address_prefix == "VirtualNetwork" &&
      azurerm_network_security_rule.cell_allow["dev-stateless-az1/snet-system/https"].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.cell_allow["dev-stateless-az1/snet-system/https-from-network"].source_address_prefix == "VirtualNetwork"
    )
    error_message = "HTTPS comes from the internet to the external zones, from the network to the internal zones, and from both to the system pool, where every zone's gateway runs."
  }
  assert {
    condition     = !contains(keys(azurerm_network_security_rule.cell_allow), "dev-stateless-az1/snet-ext-fi-ilb/https")
    error_message = "An external zone's load balancer is public: its internal load balancer subnet lets nothing in."
  }
  assert {
    condition     = azurerm_network_security_rule.cell_allow["dev-stateless-az1/snet-ext-fi-nodes/kubelet-from-system"].source_address_prefix == "172.21.0.0/24"
    error_message = "Only the system pool reaches a zone's kubelets."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.internal["int-fi.test.contoso.com/dev-stateless-az1"].name == "vnet-dev-stateless-az1"
    error_message = "The internal zones' names resolve in every cell."
  }
}

run "rejects_a_cell_that_is_not_a_slash_20" {
  command = plan

  variables {
    cells = {
      dev-stateless-az1 = { address_space = "172.21.0.0/22" }
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
# Kubernetes role gets on Secrets: edit and admin manage its secrets, view sees the vault's metadata.
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
    error_message = "The edit and admin groups should manage the namespace's secrets, each once."
  }
  assert {
    condition = alltrue([
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/44444444-4444-4444-4444-444444444444"].role_definition_name == "Key Vault Secrets Officer",
      strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/44444444-4444-4444-4444-444444444444"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
    ])
    error_message = "The admin group should be held to the namespace's secrets by its condition."
  }
  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_viewer) == ["example/viewer/aaaaaaaa-1111-1111-1111-111111111111"],
      azurerm_role_assignment.key_vault_namespace_viewer["example/viewer/aaaaaaaa-1111-1111-1111-111111111111"].role_definition_name == "Key Vault Reader",
      azurerm_role_assignment.key_vault_namespace_viewer["example/viewer/aaaaaaaa-1111-1111-1111-111111111111"].principal_type == "Group",
    ])
    error_message = "The view group should get Key Vault Reader - metadata, never a value."
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
