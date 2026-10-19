# The naming policy (variable `naming`, modules/conventions) without touching Azure: its defaults give
# the lab's names, a policy of its own gives the estate's, and a policy Azure would refuse fails the plan.
#
#   cd shared && terraform test

mock_provider "azurerm" {
  alias = "hub"
}
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "66666666-6666-6666-6666-666666666666"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-dev/providers/Microsoft.KeyVault/vaults/kv-onek8s-gwc-platform"
      vault_uri = "https://kv-onek8s-gwc-platform.vault.azure.net/"
    }
  }
  mock_resource "azurerm_container_registry" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-dev/providers/Microsoft.ContainerRegistry/registries/acronek8sdev"
    }
  }
  mock_resource "azurerm_cognitive_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-dev/providers/Microsoft.CognitiveServices/accounts/ais-onek8s-dev-agents"
    }
  }
}
mock_provider "azapi" {}

# The lab's environment (envs/dev.tfvars) as far as its names go, with no name stated.
variables {
  environment           = "dev"
  exposure              = "int"
  location              = "germanywestcentral"
  resource_group_create = true

  virtual_network_name          = "vnet-aks-dev"
  virtual_network_create        = true
  virtual_network_address_space = ["172.20.0.0/22"]
  subnets                       = { snet-aks-nodes = "172.20.0.0/23" }
  private_endpoints = {
    address_prefix             = "172.20.2.0/26"
    dns_zone_resource_group_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-dns-germanywestcentral"
    state_storage_account_id   = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-aks-dev-tfstate/providers/Microsoft.Storage/storageAccounts/stonek8sdevtfstate"
    public_network_access      = false
  }

  isolation_zones = {
    int-fi = { exposure = "int", index = 1 }
    int-se = { exposure = "int", index = 2 }
  }
  cells = {
    dev-int-stateless-az3 = { address_space = "10.100.0.0/16", pod_address_space = "100.64.0.0/16" }
  }
  hub = {
    virtual_network_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-hub-germanywestcentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-germanywestcentral"
    next_hop_ip        = "10.0.1.4"
    dns_servers        = ["10.0.1.4"]
  }

  key_vault_purge_protection_enabled = true
  log_analytics_workspace_create     = true
  container_registry_create          = true
  image_signing                      = { subject = "CN=OneK8s dev image signing, O=OneK8s, ST=Uusimaa, C=FI" }
  key_vault_namespaces = {
    flux-system    = {}
    int-fi-example = { zone = "int-fi" }
  }
  monthly_budget = { amount = 600, start_date = "2026-10-01T00:00:00Z" }
  ai_foundry     = { location = "swedencentral", deploy = false }
}

run "the_default_policy_gives_the_labs_names" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_resource_group.this[0].name == "rg-aks-dev",
      azurerm_key_vault.this.name == "kv-onek8s-gwc-platform",
      azurerm_key_vault.zone["int-fi"].name == "kv-onek8s-gwc-int-fi",
      azurerm_key_vault.zone["int-se"].name == "kv-onek8s-gwc-int-se",
      azurerm_container_registry.this[0].name == "acronek8sdev",
      azurerm_log_analytics_workspace.platform[0].name == "log-dev-platform",
      azurerm_cognitive_account.agents[0].name == "ais-onek8s-dev-agents",
      azurerm_cognitive_account.agents[0].custom_subdomain_name == "ais-onek8s-dev-agents",
      azurerm_consumption_budget_subscription.this[0].name == "budget-dev",
      azurerm_user_assigned_identity.key_vault["int-fi-example"].name == "id-gwc-dev-shared-kv-int-fi-example",
      azurerm_user_assigned_identity.image_verification[0].name == "id-gwc-dev-shared-ratify",
    ])
    error_message = "The default naming policy must give the lab's resources the names they have."
  }
  assert {
    condition = alltrue([
      keys(azurerm_virtual_network.cell) == ["dev-int-stateless-az3"],
      azurerm_virtual_network.cell["dev-int-stateless-az3"].name == "vnet-dev-int-stateless-az3",
      azurerm_route_table.cell["dev-int-stateless-az3"].name == "rt-dev-int-stateless-az3",
      azurerm_route_table.zone["dev-int-stateless-az3/int-se"].name == "rt-dev-int-stateless-az3-int-se",
      azurerm_network_security_group.cell["dev-int-stateless-az3/snet-system"].name == "nsg-dev-int-stateless-az3-system",
      azurerm_network_security_group.cell["dev-int-stateless-az3/snet-int-fi-nodes"].name == "nsg-dev-int-stateless-az3-int-fi-nodes",
      azurerm_network_security_group.cell["dev-int-stateless-az3/snet-int-se-ilb"].name == "nsg-dev-int-stateless-az3-int-se-ilb",
    ])
    error_message = "The cells' networks keep their names under the default policy."
  }
  assert {
    condition = alltrue([
      azurerm_private_endpoint.this["kv-platform"].name == "pe-kv-onek8s-gwc-platform",
      azurerm_private_endpoint.this["kv-platform"].custom_network_interface_name == "nic-pe-kv-onek8s-gwc-platform",
      azurerm_private_endpoint.this["state"].name == "pe-stonek8sdevtfstate",
      azurerm_private_endpoint.this["foundry"].name == "pe-ais-onek8s-dev-agents",
    ])
    error_message = "The private endpoints keep their names under the default policy."
  }
}

run "a_policy_of_its_own_names_everything" {
  command = plan

  variables {
    naming = {
      location_codes = { germanywestcentral = "dewc" }
      templates = {
        resource_group          = "rg-{location_code}-{environment}-{exposure}-k8s"
        key_vault               = "kvx7{location_code}{environment}-{name}"
        container_registry      = "cr-x7-{location_code}-{environment}-{exposure}"
        log_analytics_workspace = "log-{location_code}-{environment}-{exposure}-{name}"
        user_assigned_identity  = "mi-{location_code}-{environment}-{exposure}-{name}"
        virtual_network         = "vnet-{location_code}-{name}"
        network_security_group  = "nsg-{location_code}-{name}"
        route_table             = "udr-{location_code}-{name}"
        private_endpoint        = "pep-{name}"
        network_interface       = "nic-{name}"
        consumption_budget      = "bud-{environment}-{exposure}"
        ai_services             = "aix7-{location}-{environment}-{name}"
      }
    }
  }

  assert {
    condition = alltrue([
      azurerm_resource_group.this[0].name == "rg-dewc-dev-int-k8s",
      azurerm_key_vault.this.name == "kvx7dewcdev-platform",
      azurerm_key_vault.zone["int-fi"].name == "kvx7dewcdev-int-fi",
      azurerm_container_registry.this[0].name == "crx7dewcdevint",
      azurerm_log_analytics_workspace.platform[0].name == "log-dewc-dev-int-platform",
      azurerm_cognitive_account.agents[0].name == "aix7-germanywestcentral-dev-agents",
      azurerm_consumption_budget_subscription.this[0].name == "bud-dev-int",
      azurerm_user_assigned_identity.key_vault["flux-system"].name == "mi-dewc-dev-int-shared-kv-flux-system",
      azurerm_user_assigned_identity.image_verification[0].name == "mi-dewc-dev-int-shared-ratify",
      azurerm_virtual_network.cell["dev-int-stateless-az3"].name == "vnet-dewc-dev-int-stateless-az3",
      azurerm_route_table.cell["dev-int-stateless-az3"].name == "udr-dewc-dev-int-stateless-az3",
      azurerm_route_table.zone["dev-int-stateless-az3/int-fi"].name == "udr-dewc-dev-int-stateless-az3-int-fi",
      azurerm_network_security_group.cell["dev-int-stateless-az3/snet-system"].name == "nsg-dewc-dev-int-stateless-az3-system",
      azurerm_private_endpoint.this["kv-platform"].name == "pep-kvx7dewcdev-platform",
    ])
    error_message = "Every name should follow the estate's own templates and region codes."
  }
}

run "a_variable_that_names_a_resource_wins" {
  command = plan

  variables {
    resource_group_name  = "rg-legacy"
    key_vault_name       = "kv-legacy-platform"
    zone_key_vault_names = { int-se = "kv-legacy-int-se" }
  }

  assert {
    condition     = azurerm_resource_group.this[0].name == "rg-legacy" && azurerm_key_vault.this.name == "kv-legacy-platform" && azurerm_key_vault.zone["int-se"].name == "kv-legacy-int-se" && azurerm_key_vault.zone["int-fi"].name == "kv-onek8s-gwc-int-fi"
    error_message = "A name stated in a variable wins over the policy, resource by resource."
  }
}

run "an_empty_exposure_leaves_no_stray_hyphen" {
  command = plan

  variables {
    exposure = null
    naming   = { templates = { log_analytics_workspace = "log-{environment}-{exposure}-{name}" } }
  }

  assert {
    condition     = azurerm_log_analytics_workspace.platform[0].name == "log-dev-platform"
    error_message = "An empty placeholder should leave one hyphen, not two."
  }
}

run "refuses_a_policy_that_makes_a_name_azure_refuses" {
  command = plan

  # A virtual network's name cannot end in a dot - which the provider lets through to Azure.
  variables {
    naming = { templates = { virtual_network = "vnet-{name}." } }
  }

  expect_failures = [output.names]
}

run "refuses_an_unknown_placeholder" {
  command = plan

  # Refused even for a type nothing here is named by yet (no Traffic Manager in the internal exposure).
  variables {
    naming = { templates = { traffic_manager_profile = "tm-{region}-{name}" } }
  }

  expect_failures = [output.names]
}

run "refuses_an_unknown_resource_type" {
  command = plan

  variables {
    naming = { templates = { storage_account = "st{environment}" } }
  }

  expect_failures = [output.names]
}

run "a_region_code_from_the_policy" {
  command = plan

  variables {
    location = "norwayeast"
    naming   = { location_codes = { norwayeast = "noe" } }
  }

  assert {
    condition     = azurerm_key_vault.this.name == "kv-onek8s-noe-platform"
    error_message = "A region the built-in list lacks takes its code from the policy."
  }
}
