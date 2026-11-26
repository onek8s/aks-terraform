# Plan-time behaviour of the tenants stack, without touching Azure: the providers are mocked, so
# `terraform test` (in tenants/) needs no subscription and no credentials. One cell, aks-test, holds the
# zones the tenants below are in; a tenant is named `<zone>-<app>`, so `team-payments` is in zone `team`.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "66666666-6666-6666-6666-666666666666"
    }
  }
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test-shared-kv-example"
      principal_id = "77777777-7777-7777-7777-777777777777"
      client_id    = "88888888-8888-8888-8888-888888888888"
    }
  }
  mock_data "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-test-zone"
      vault_uri = "https://kv-test-zone.vault.azure.net/"
    }
  }
}

# The cell and its platform Flux configuration answer with the same mock: an ID, and the values both
# are read for.
mock_provider "azapi" {
  mock_data "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      output = {
        issuer                = "https://issuer.example/aks-test/"
        network_policy        = "cilium"
        url                   = "https://github.com/example/cluster-config"
        branch                = "main"
        sync_interval_seconds = 300
      }
    }
  }
  # Every zone of the cell has node pools; the dedicated pool of team-dedicated too.
  mock_data "azapi_resource_list" {
    defaults = {
      output = {
        labels = [
          { "platform/zone" = "team" },
          { "platform/zone" = "ext-fi" },
          { "platform/zone" = "team", "platform/pool" = "team-dedicated" },
        ]
      }
    }
  }
}

variables {
  location            = "swedencentral"
  resource_group_name = "rg-aks-test"
  environment         = "test"
  cells = {
    aks-test = { zones = ["team", "ext-fi"] }
  }
}

run "a_cluster_with_no_managed_namespaces_creates_none" {
  command = plan

  assert {
    condition     = length(azapi_resource.namespace) == 0
    error_message = "Namespaces are opt-in; an environment that lists none should get none."
  }
}

# Listing the names is the whole of it: everything else comes from namespace_defaults.
run "a_namespace_closes_ingress_to_itself_and_leaves_egress_open" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
      team-search   = { zone = "team" }
    }
  }

  assert {
    condition     = toset(keys(azapi_resource.namespace)) == toset(["aks-test/team-payments", "aks-test/team-search"])
    error_message = "Every tenant should get a namespace of its own."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].name == "team-payments"
    error_message = "The namespace is named by the key, not by anything derived from it."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    error_message = "A managed namespace belongs to the cluster."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].type == "Microsoft.ContainerService/managedClusters/managedNamespaces@2026-05-02-preview"
    error_message = "The namespace should use the same AKS API version as everything else written directly."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.namespace :
      namespace.body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    ])
    error_message = "By default only pods of the same namespace should be able to reach into it."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.namespace :
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
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  # The pod security labels are always there - a namespace is held to the estate standard whether or
  # not it says anything - so what is checked here is that nothing else came along with them.
  assert {
    condition = toset(keys(azapi_resource.namespace["aks-test/team-payments"].body.properties.labels)) == toset([
      "platform/zone",
      "pod-security.kubernetes.io/audit",
      "pod-security.kubernetes.io/audit-version",
      "pod-security.kubernetes.io/enforce",
      "pod-security.kubernetes.io/enforce-version",
      "pod-security.kubernetes.io/warn",
      "pod-security.kubernetes.io/warn-version",
    ])
    error_message = "No labels were asked for, so only the zone's and the pod security ones should be sent."
  }
  assert {
    # The zone's tolerations whitelist (placement) is the platform's, always there with zone pools.
    condition     = length([for key in keys(try(azapi_resource.namespace["aks-test/team-payments"].body.properties.annotations, {})) : key if !startswith(key, "scheduler.alpha.kubernetes.io/")]) == 0
    error_message = "No annotations were asked for, so none but the placement ones should be sent."
  }
}

# Nothing is deleted or taken over behind anyone's back: an existing namespace of the same name
# fails the apply, and dropping the entry again leaves the Kubernetes namespace standing.
run "a_namespace_neither_adopts_nor_deletes_by_default" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.adoptionPolicy == "Never"
    error_message = "A namespace that already exists should stop the apply rather than be taken over."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.deletePolicy == "Keep"
    error_message = "Dropping a line from a variables file should not delete a running workload."
  }
}

run "a_namespace_overrides_only_the_defaults_it_names" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone           = "team"
        network_policy = { ingress = "AllowAll" }
      }
      team-search = {
        zone           = "team"
        network_policy = { egress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowAll"
    error_message = "A namespace that opens ingress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultNetworkPolicy.egress == "AllowSameNamespace"
    error_message = "Overriding ingress should leave egress on the default."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-search"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "A namespace that opens egress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-search"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Overriding egress should leave ingress on the default."
  }
}

# One place to move a whole cluster at once, rather than repeating the same override per namespace.
run "the_estate_wide_defaults_move_every_namespace_that_says_nothing" {
  command = plan

  variables {
    namespace_defaults = {
      adoption_policy = "IfIdentical"
      delete_policy   = "Delete"
      network_policy  = { egress = "DenyAll" }
      resource_quota  = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    tenants = {
      team-payments = { zone = "team" }
      team-search = {
        zone           = "team"
        network_policy = { egress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultNetworkPolicy.egress == "DenyAll"
    error_message = "A namespace that says nothing should follow the estate-wide default."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-search"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "A namespace that says otherwise should still win over the default."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Changing the default egress should leave the default ingress alone."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.namespace :
      namespace.body.properties.adoptionPolicy == "IfIdentical" && namespace.body.properties.deletePolicy == "Delete"
    ])
    error_message = "The adoption and delete policies should follow the defaults as well."
  }
  assert {
    condition     = keys(azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "The default quota should reach every namespace, all four figures of it."
  }
  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
    ])
    error_message = "The figures the defaults do name should reach the namespace, the CPU one as milliCPU."
  }
}

run "a_namespace_takes_the_quota_figures_it_names_and_the_defaults_for_the_rest" {
  command = plan

  variables {
    namespace_defaults = {
      resource_quota = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    tenants = {
      team-search = {
        zone           = "team"
        resource_quota = { cpu_limit = "8", memory_request = "1Gi" }
      }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.cpuRequest == "500m"
    error_message = "Neither side named a CPU request, so the built-in default should fill it in - Azure takes no namespace without one."
  }
  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.cpuLimit == "8000m",
      azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
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
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = keys(azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "A namespace with no quota of its own should still be sent all four figures."
  }
  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
    ])
    error_message = "The built-in quota should be the documented one, with the CPU figures in milliCPU."
  }
}

# Azure refuses a quota that states CPU in anything but milliCPU, while a manifest writes the same
# figure either way. Whichever form the variables name it in, what leaves here is milliCPU.
run "cpu_quota_figures_reach_azure_as_millicpu" {
  command = plan

  variables {
    namespace_defaults = {
      resource_quota = { cpu_request = "0.5" }
    }
    tenants = {
      team-payments = {
        zone           = "team"
        resource_quota = { cpu_limit = "2" }
      }
      # Named in milliCPU on both sides, which is the form Azure takes.
      team-search = {
        zone           = "team"
        resource_quota = { cpu_limit = "1500m", cpu_request = "0.125" }
      }
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
    ])
    error_message = "Whole and fractional cores should be sent as the milliCPU figure they mean."
  }
  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.cpuLimit == "1500m",
      azapi_resource.namespace["aks-test/team-search"].body.properties.defaultResourceQuota.cpuRequest == "125m",
    ])
    error_message = "A figure already written in milliCPU should be sent as it stands."
  }
}

# Labels and annotations are added to rather than replaced, so an estate-wide set survives a
# namespace adding one of its own.
run "namespace_labels_and_annotations_merge_with_the_defaults" {
  command = plan

  variables {
    namespace_defaults = {
      annotations = { "estate" = "prototype" }
      labels      = { "cost-centre" = "platform", "tier" = "shared" }
    }
    tenants = {
      team-search = {
        zone        = "team"
        annotations = { "owner" = "search" }
        labels      = { "tier" = "dedicated" }
      }
    }
  }

  assert {
    condition = azapi_resource.namespace["aks-test/team-search"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "tier"                                       = "dedicated"
      "platform/zone"                              = "team"
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
    condition = tomap({ for key, value in azapi_resource.namespace["aks-test/team-search"].body.properties.annotations : key => value if !startswith(key, "scheduler.alpha.kubernetes.io/") }) == tomap({
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

  override_data {
    target = data.azapi_resource.cluster["aks-test"]
    values = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      output = { issuer = "https://issuer.example/", network_policy = "none" }
    }
  }

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  expect_failures = [check.namespaces_have_something_enforcing_their_network_policies]
}

run "a_namespace_open_in_both_directions_needs_no_engine_to_enforce_it" {
  command = plan

  override_data {
    target = data.azapi_resource.cluster["aks-test"]
    values = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      output = { issuer = "https://issuer.example/", network_policy = "none" }
    }
  }

  variables {
    tenants = {
      team-payments = {
        zone           = "team"
        network_policy = { egress = "AllowAll", ingress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = length(local.namespaces_without_a_policy_engine) == 0
    error_message = "A namespace that restricts nothing has nothing for an engine to enforce."
  }
}

run "rejects_a_namespace_name_kubernetes_reserves" {
  command = plan

  variables {
    # A cell holds the zone, so only the name is wrong.
    cells = { aks-test = { zones = ["kube"] } }
    tenants = {
      kube-payments = { zone = "kube" }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_system_namespace_aks_will_not_hand_over" {
  command = plan

  variables {
    # A cell holds the zone, so only the name is wrong.
    cells = { aks-test = { zones = ["gatekeeper"] } }
    tenants = {
      gatekeeper-system = { zone = "gatekeeper" }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_namespace_name_kubernetes_would_refuse" {
  command = plan

  variables {
    # A cell holds the zone, so only the name is wrong.
    cells = { aks-test = { zones = ["Team"] } }
    tenants = {
      Team_Payments = { zone = "Team" }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_network_policy_rule_azure_does_not_have" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone           = "team"
        network_policy = { ingress = "AllowSameCluster" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_delete_policy_azure_does_not_have" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone          = "team"
        delete_policy = "Retain"
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_quota_that_is_not_a_kubernetes_quantity" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone           = "team"
        resource_quota = { memory_limit = "4GB" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_cpu_quota_azure_cannot_hold" {
  command = plan

  variables {
    tenants = {
      # Finer than the milliCPU Azure counts in, which would otherwise be quietly rounded away.
      team-payments = {
        zone           = "team"
        resource_quota = { cpu_limit = "0.0005" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_cpu_quota_of_nothing_at_all" {
  command = plan

  variables {
    namespace_defaults = {
      # Azure takes nothing below 1m, and a quota of zero CPU is not what anybody meant by it.
      resource_quota = { cpu_request = "0" }
    }
  }

  expect_failures = [var.namespace_defaults]
}

run "rejects_estate_wide_defaults_azure_does_not_have" {
  command = plan

  variables {
    namespace_defaults = {
      network_policy = { egress = "AllowSameCluster" }
    }
  }

  expect_failures = [var.namespace_defaults]
}

# ----------------------------------------------------------------------------------------------
# Tenant Flux configurations
# ----------------------------------------------------------------------------------------------

run "a_namespace_deploys_nothing_unless_it_names_a_repository" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = length(azapi_resource.team_flux_configuration) == 0
    error_message = "A managed namespace without flux should get no Flux configuration."
  }
}

run "a_tenant_syncs_its_own_repository_into_its_own_namespace" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        flux = {
          url         = "https://github.com/contoso/team-payments-deploy"
          path        = "./apps"
          secret_name = "team-payments-deploy-git"
        }
      }
      team-search = { zone = "team" }
    }
  }

  assert {
    condition     = keys(azapi_resource.team_flux_configuration) == ["aks-test/team-payments"]
    error_message = "Only the namespace that names a repository should get a Flux configuration."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].name == "team-payments"
    error_message = "The configuration should be named after its namespace."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].type == "Microsoft.KubernetesConfiguration/fluxConfigurations@2024-11-01"
    error_message = "The configuration should be a Flux configuration of the same API version as the platform's."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    error_message = "The configuration should belong to the cluster."
  }
  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.scope == "namespace"
      && azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.namespace == "team-payments"
    )
    error_message = "The configuration should be namespace-scoped, in the tenant's own namespace."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.url == "https://github.com/contoso/team-payments-deploy"
    error_message = "The configuration should sync the tenant's repository."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.repositoryRef.branch == "main"
    error_message = "The branch should default to main."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.localAuthRef == "team-payments-deploy-git"
    error_message = "A private repository should be read with the Secret already in the namespace."
  }
  assert {
    condition     = !contains(keys(azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties), "configurationProtectedSettings")
    error_message = "No credential should pass through Terraform or Azure."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.path == "./apps"
    error_message = "The Kustomization should apply the configured path."
  }
  assert {
    condition     = jsonencode(azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.postBuild.substitute) == jsonencode({ zone = "team", cluster_name = "aks-test" })
    error_message = "The team's manifests should get its zone and the cell's name, and nothing else, as post-build variables."
  }
  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.prune
      && azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.wait
    )
    error_message = "The Kustomization should prune what leaves the repository and wait for what it applied."
  }
  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.syncIntervalInSeconds == 300
      && azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.syncIntervalInSeconds == 300
      && azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.retryIntervalInSeconds == 300
    )
    error_message = "The repository should be read, applied and retried every five minutes by default."
  }
}

run "a_public_tenant_repository_is_read_with_no_secret" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        flux = {
          url                   = "https://github.com/contoso/team-payments-deploy"
          branch                = "release"
          sync_interval_seconds = 60
        }
      }
    }
  }

  assert {
    condition     = !contains(keys(azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository), "localAuthRef")
    error_message = "A public repository should name no Secret."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.repositoryRef.branch == "release"
    error_message = "The configured branch should be synced."
  }
  assert {
    condition     = azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.retryIntervalInSeconds == 60
    error_message = "A failed apply should be retried as often as the repository is read."
  }
}

run "rejects_a_tenant_repository_url_flux_cannot_read" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        flux = { url = "github.com/contoso/team-payments-deploy" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_tenant_sync_interval_under_a_minute" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        flux = {
          url                   = "https://github.com/contoso/team-payments-deploy"
          sync_interval_seconds = 30
        }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_tenant_secret_name_kubernetes_would_refuse" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        flux = {
          url         = "https://github.com/contoso/team-payments-deploy"
          secret_name = "Team_Payments_Git"
        }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_tenant_named_after_the_platform_configuration" {
  command = plan

  variables {
    # A cell holds the zone, so only the name is wrong.
    cells = { aks-test = { zones = ["platform"] } }
    tenants = {
      platform = {
        zone = "platform"
        flux = { url = "https://github.com/contoso/platform-deploy" }
      }
    }
  }

  expect_failures = [output.tenants]
}

# ----------------------------------------------------------------------------------------------
# Namespace-scoped access
# ----------------------------------------------------------------------------------------------

run "a_namespace_grants_nothing_unless_it_is_asked_to" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.namespace_user) == 0
    error_message = "A namespace with no access listed should hand nobody anything."
  }
}

# The labels the API server's Pod Security Admission controller reads. Nothing else is involved:
# admission is built into the API server, so a labelled namespace is an enforced one.
run "a_namespace_is_held_to_the_restricted_standard_by_default" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition = azapi_resource.namespace["aks-test/team-payments"].body.properties.labels == tomap({
      "platform/zone"                              = "team"
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
    tenants = {
      team-monitoring = {
        zone         = "team"
        pod_security = { enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-monitoring"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "privileged"
    error_message = "A namespace that cannot meet the standard should be able to say so."
  }
  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-monitoring"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
      azapi_resource.namespace["aks-test/team-monitoring"].body.properties.labels["pod-security.kubernetes.io/warn"] == "restricted",
    ])
    error_message = "An exception should stay visible: relaxing enforce must not drag audit and warn down with it."
  }
  assert {
    condition     = length(local.tenants_with_silent_pod_security_exceptions) == 0
    error_message = "An exception that is still audited is not a silent one."
  }
}

run "a_mode_set_to_none_leaves_its_label_off_entirely" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone         = "team"
        pod_security = { warn = "none" }
      }
    }
  }

  assert {
    condition     = !can(azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"])
    error_message = "A mode nobody wants should leave no label rather than an empty one."
  }
  assert {
    condition     = !can(azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/warn-version"])
    error_message = "The version label goes with the mode it belongs to."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Turning off the warning should leave enforcement alone."
  }
}

# `latest` follows the cluster, so an upgrade can tighten the standard under a running workload.
run "the_standard_can_be_pinned_to_a_kubernetes_version" {
  command = plan

  variables {
    namespace_defaults = {
      pod_security = { version = "v1.31" }
    }
    tenants = {
      team-payments = { zone = "team" }
      team-search = {
        zone         = "team"
        pod_security = { version = "v1.30" }
      }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.31"
    error_message = "A pinned estate-wide version should reach every namespace."
  }
  assert {
    condition     = azapi_resource.namespace["aks-test/team-search"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.30"
    error_message = "A namespace should be able to hold a version of its own."
  }
}

run "the_estate_wide_standard_can_be_lowered_for_a_whole_cluster" {
  command = plan

  variables {
    namespace_defaults = {
      pod_security = { audit = "restricted", enforce = "baseline", warn = "baseline" }
    }
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "baseline",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"] == "baseline",
      azapi_resource.namespace["aks-test/team-payments"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
    ])
    error_message = "One place should move the standard for the whole cluster."
  }
}

# The labels sit alongside whatever else the namespace carries, rather than replacing it.
run "pod_security_labels_join_the_labels_a_namespace_already_has" {
  command = plan

  variables {
    namespace_defaults = {
      labels = { "cost-centre" = "platform" }
    }
    tenants = {
      team-payments = {
        zone   = "team"
        labels = { "team" = "payments" }
      }
    }
  }

  assert {
    condition = azapi_resource.namespace["aks-test/team-payments"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "team"                                       = "payments"
      "platform/zone"                              = "team"
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
    tenants = {
      team-monitoring = {
        zone         = "team"
        pod_security = { audit = "none", enforce = "privileged", warn = "none" }
      }
    }
  }

  expect_failures = [check.pod_security_exceptions_stay_on_the_record]
}

run "an_exception_recorded_by_warn_alone_is_not_warned_about" {
  command = plan

  variables {
    tenants = {
      team-monitoring = {
        zone         = "team"
        pod_security = { audit = "none", enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = length(local.tenants_with_silent_pod_security_exceptions) == 0
    error_message = "Either audit or warn at the estate standard is enough to keep an exception visible."
  }
}

# Nothing was relaxed, so there is no exception to record - even with audit and warn turned off.
run "a_namespace_at_the_estate_standard_needs_no_record_of_an_exception" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone         = "team"
        pod_security = { audit = "none", warn = "none" }
      }
    }
  }

  assert {
    condition     = length(local.tenants_with_silent_pod_security_exceptions) == 0
    error_message = "A namespace that still enforces the estate standard has made no exception."
  }
}

run "rejects_a_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone         = "team"
        pod_security = { enforce = "hardened" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_pod_security_version_that_is_not_one" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone         = "team"
        pod_security = { version = "1.31" }
      }
    }
  }

  expect_failures = [output.tenants]
}

# One place decides the standard, so a hand-written label cannot contradict pod_security.
run "rejects_a_pod_security_label_written_by_hand" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone   = "team"
        labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_pod_security_label_written_by_hand_in_the_defaults" {
  command = plan

  variables {
    namespace_defaults = {
      labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
    }
  }

  expect_failures = [var.namespace_defaults]
}

run "rejects_an_estate_wide_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    namespace_defaults = {
      pod_security = { enforce = "hardened" }
    }
  }

  expect_failures = [var.namespace_defaults]
}

run "a_tenant_gets_the_substitutes_it_is_given" {
  command = plan

  variables {
    tenants = {
      ext-fi-orders = {
        zone = "ext-fi"
        flux = {
          url        = "https://github.com/example/orders"
          substitute = { zone_domain = "ext-fi.test.contoso.com" }
        }
      }
    }
  }

  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/ext-fi-orders"].body.properties.kustomizations.apps.postBuild.substitute.zone_domain == "ext-fi.test.contoso.com" &&
      azapi_resource.team_flux_configuration["aks-test/ext-fi-orders"].body.properties.kustomizations.apps.postBuild.substitute.cluster_name == "aks-test"
    )
    error_message = "A tenant's substitutes should reach its Flux configuration next to cluster_name."
  }
}

# ----------------------------------------------------------------------------------------------
# Ownership
# ----------------------------------------------------------------------------------------------

run "a_namespace_names_its_owner_in_labels_and_annotations" {
  command = plan

  variables {
    tenants = {
      ext-fi-payments = {
        zone = "ext-fi"
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
      azapi_resource.namespace["aks-test/ext-fi-payments"].body.properties.labels["platform/team"] == "payments"
      && azapi_resource.namespace["aks-test/ext-fi-payments"].body.properties.labels["platform/cost-center"] == "cc-4711"
    )
    error_message = "The owner's team and cost centre should be the namespace's platform/team and platform/cost-center labels."
  }
  assert {
    condition = tomap({ for key, value in azapi_resource.namespace["aks-test/ext-fi-payments"].body.properties.annotations : key => value if !startswith(key, "scheduler.alpha.kubernetes.io/") }) == tomap({
      "platform/contact"    = "payments-team@example.com"
      "platform/repository" = "https://github.com/contoso/payments"
    })
    error_message = "The contact and the namespace's repository should be annotations."
  }
}

run "rejects_an_owner_that_is_not_a_label_value" {
  command = plan

  variables {
    tenants = {
      ext-fi-payments = {
        zone = "ext-fi"
        owner = {
          team        = "Payments Team"
          cost_center = "cc-4711"
          contact     = "payments-team@example.com"
        }
      }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_owner_labels_set_by_hand" {
  command = plan

  variables {
    tenants = {
      ext-fi-payments = {
        zone   = "ext-fi"
        labels = { "platform/team" = "someone-else" }
        owner = {
          team        = "payments"
          cost_center = "cc-4711"
          contact     = "payments-team@example.com"
        }
      }
    }
  }

  expect_failures = [output.tenants]
}

# A tenant's groups: an Entra ID group per built-in role, bound inside the namespace by a
# RoleBinding that a Flux configuration of the namespace's own applies, one Kustomization per role.
run "namespace_groups_get_a_role_binding_each_through_flux" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        groups = {
          view  = "11111111-1111-1111-1111-111111111111"
          edit  = "22222222-2222-2222-2222-222222222222"
          admin = "33333333-3333-3333-3333-333333333333"
        }
      }
      # One role only: no binding for the other two.
      team-search = {
        zone   = "team"
        groups = { view = "AAAAAAAA-4444-4444-4444-444444444444" }
      }
      team-batch = { zone = "team" }
    }
  }

  assert {
    condition     = toset(keys(azapi_resource.platform_flux_configuration)) == toset(["aks-test/team-payments", "aks-test/team-search", "aks-test/team-batch"])
    error_message = "Every namespace should get the platform's Flux configuration: its store, and its bindings if it names groups."
  }
  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].name == "team-payments-access"
    error_message = "A namespace's binding configuration should be named <namespace>-access."
  }
  assert {
    condition     = toset(keys(azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations)) == toset(["view", "edit", "admin", "store"])
    error_message = "Every role that names a group should get a Kustomization, beside the store."
  }
  assert {
    condition     = toset(keys(azapi_resource.platform_flux_configuration["aks-test/team-search"].body.properties.kustomizations)) == toset(["view", "store"])
    error_message = "A role without a group should get no Kustomization."
  }
  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.edit.path == "./infrastructure/namespace-access/edit"
    error_message = "A binding should be applied from its role's directory under namespace_access_path: Azure refuses two Kustomizations on one path."
  }
  assert {
    condition = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.edit.postBuild.substitute == {
      namespace       = "team-payments"
      role            = "edit"
      group_object_id = "22222222-2222-2222-2222-222222222222"
    }
    error_message = "A binding's Kustomization should be told its namespace, its role and its group."
  }
  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-search"].body.properties.kustomizations.view.postBuild.substitute.group_object_id == "aaaaaaaa-4444-4444-4444-444444444444"
    error_message = "The group's object ID should be sent in lower case, as Entra ID puts it into the token."
  }
  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.admin.prune
    error_message = "A binding's Kustomization should prune, so that removing the group removes the binding."
  }
  assert {
    condition = (
      azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.scope == "cluster"
      && azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.namespace == "flux-system"
      && azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.gitRepository.url == "https://github.com/example/cluster-config"
    )
    error_message = "The binding configuration should read the cluster's repository at cluster scope from flux-system."
  }
  assert {
    condition     = toset(keys(azapi_resource.platform_flux_configuration["aks-test/team-batch"].body.properties.kustomizations)) == toset(["store"])
    error_message = "A namespace without groups should get the store alone."
  }
}

# Each group's members can fetch a kubeconfig for the namespace, and only for it.
run "namespace_groups_get_namespace_user_on_their_namespace" {
  command = plan

  variables {
    tenants = {
      team-payments = {
        zone = "team"
        groups = {
          view = "11111111-1111-1111-1111-111111111111"
          edit = "22222222-2222-2222-2222-222222222222"
        }
      }
    }
  }

  assert {
    condition = toset(keys(azurerm_role_assignment.namespace_user)) == toset([
      "aks-test/team-payments/namespace_user/11111111-1111-1111-1111-111111111111",
      "aks-test/team-payments/namespace_user/22222222-2222-2222-2222-222222222222",
    ])
    error_message = "Every group should get Namespace User on its namespace, once."
  }
  assert {
    condition = alltrue([
      for assignment in azurerm_role_assignment.namespace_user :
      assignment.role_definition_name == "Azure Kubernetes Service Namespace User" && assignment.principal_type == "Group"
    ])
    error_message = "The groups should get Azure Kubernetes Service Namespace User, as groups."
  }
}

run "namespace_access_path_can_be_moved" {
  command = plan

  variables {
    namespace_access_path = "./rbac"
    tenants = {
      team-payments = { zone = "team", groups = { admin = "33333333-3333-3333-3333-333333333333" } }
    }
  }

  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.admin.path == "./rbac/admin"
    error_message = "The bindings should be applied from namespace_access_path."
  }
}

run "rejects_a_namespace_group_that_is_not_an_object_id" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team", groups = { edit = "team-payments-developers" } }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_namespace_with_groups_and_a_name_too_long_for_its_kustomizations" {
  command = plan

  variables {
    tenants = {
      "team-payments-with-a-name-far-too-long-to-be-labelled" = { zone = "team", groups = { view = "11111111-1111-1111-1111-111111111111" } }
    }
  }

  expect_failures = [output.tenants]
}


# ----------------------------------------------------------------------------------------------
# What the split adds: cells, the store, placement, the zones' watch lists, federation, the catalogue
# ----------------------------------------------------------------------------------------------

# A tenant goes to every cell holding its zone - the cells of a zone run the same tenants - or to the
# cells it names.
run "a_tenant_goes_to_every_cell_of_its_zone" {
  command = plan

  variables {
    cells = {
      aks-test   = { zones = ["team"] }
      aks-test-2 = { zones = ["team", "ext-fi"] }
    }
    tenants = {
      team-payments   = { zone = "team" }
      ext-fi-orders   = { zone = "ext-fi" }
      team-only-there = { zone = "team", cells = ["aks-test-2"] }
    }
  }

  assert {
    condition = toset(keys(azapi_resource.namespace)) == toset([
      "aks-test/team-payments", "aks-test-2/team-payments", "aks-test-2/ext-fi-orders", "aks-test-2/team-only-there",
    ])
    error_message = "Each tenant should be in every cell of its zone, or in the cells it names."
  }
  assert {
    condition     = output.tenants["team-payments"].cells == tolist(["aks-test", "aks-test-2"])
    error_message = "The output should say which cells each tenant is in."
  }
}

run "rejects_a_tenant_in_a_cell_without_its_zone" {
  command = plan

  variables {
    tenants = {
      int-se-orders = { zone = "int-se", cells = ["aks-test"] }
    }
  }

  expect_failures = [output.tenants]
}

run "rejects_a_tenant_not_named_after_its_zone" {
  command = plan

  variables {
    tenants = {
      payments = { zone = "team" }
    }
  }

  expect_failures = [output.tenants]
}

run "warns_about_a_tenant_no_cell_holds" {
  command = plan

  variables {
    tenants = {
      int-se-orders = { zone = "int-se" }
    }
  }

  expect_failures = [check.every_tenant_is_in_a_cell]
}

# The namespace carries its zone, the label the zone's gateway selects routes by.
run "a_tenant_is_labelled_with_its_zone" {
  command = plan

  variables {
    tenants = {
      ext-fi-orders = { zone = "ext-fi" }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/ext-fi-orders"].body.properties.labels["platform/zone"] == "ext-fi"
    error_message = "The namespace should be labelled platform/zone with the tenant's zone."
  }
}

run "rejects_a_zone_label_written_by_hand" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team", labels = { "platform/zone" = "ext-fi" } }
    }
  }

  expect_failures = [output.tenants]
}

# The platform's part of every namespace: the store of its vault share, read as its own identity from
# its zone's vault, out of the cell's own repository and branch.
run "every_tenant_gets_its_store_from_the_platform_repository" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].name == "team-payments-access"
    error_message = "The platform's configuration of a namespace should be <namespace>-access."
  }
  assert {
    condition = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.gitRepository == {
      repositoryRef         = { branch = "main" }
      syncIntervalInSeconds = 300
      url                   = "https://github.com/example/cluster-config"
    }
    error_message = "It should read the cell's platform repository on the cell's branch."
  }
  assert {
    condition     = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.store.path == "./infrastructure/tenant"
    error_message = "The store should come from tenant_path."
  }
  assert {
    condition = azapi_resource.platform_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.store.postBuild.substitute == {
      namespace           = "team-payments"
      zone                = "team"
      key_vault_url       = "https://kv-test-zone.vault.azure.net/"
      key_vault_client_id = "88888888-8888-8888-8888-888888888888"
      azure_tenant_id     = "66666666-6666-6666-6666-666666666666"
    }
    error_message = "The store should be told its namespace, its zone, its zone's vault and its identity."
  }
}

# The identity of a namespace is federated with each cell it is in.
run "a_tenants_identity_is_federated_with_each_of_its_cells" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition = (
      azurerm_federated_identity_credential.key_vault["aks-test/team-payments"].name == "aks-aks-test"
      && azurerm_federated_identity_credential.key_vault["aks-test/team-payments"].issuer == "https://issuer.example/aks-test/"
      && azurerm_federated_identity_credential.key_vault["aks-test/team-payments"].subject == "system:serviceaccount:team-payments:key-vault"
    )
    error_message = "The credential should be the cell's, for the namespace's key-vault service account."
  }
}

# Placement (design section 2.3): every tenant of a zone with pools gets the tolerations whitelist, and
# a dedicated one its pool's node selector and toleration.
run "a_dedicated_tenant_is_placed_on_its_pools" {
  command = plan

  variables {
    tenants = {
      team-dedicated = { zone = "team", dedicated_node_pool = true }
      team-shared    = { zone = "team" }
    }
  }

  assert {
    condition     = azapi_resource.namespace["aks-test/team-dedicated"].body.properties.annotations["scheduler.alpha.kubernetes.io/node-selector"] == "platform/pool=team-dedicated"
    error_message = "A dedicated tenant's pods should select its pool."
  }
  assert {
    condition     = jsondecode(azapi_resource.namespace["aks-test/team-dedicated"].body.properties.annotations["scheduler.alpha.kubernetes.io/defaultTolerations"]) == [{ key = "platform/pool", operator = "Equal", value = "team-dedicated", effect = "NoSchedule" }]
    error_message = "A dedicated tenant's pods should tolerate its pool."
  }
  assert {
    condition     = contains(jsondecode(azapi_resource.namespace["aks-test/team-dedicated"].body.properties.annotations["scheduler.alpha.kubernetes.io/tolerationsWhitelist"]), { key = "platform/pool", operator = "Equal", value = "team-dedicated", effect = "NoSchedule" })
    error_message = "A dedicated tenant's whitelist should hold its own pool."
  }
  assert {
    condition     = !contains(keys(azapi_resource.namespace["aks-test/team-shared"].body.properties.annotations), "scheduler.alpha.kubernetes.io/node-selector")
    error_message = "A tenant on the zone's shared pools should get no node selector."
  }
  assert {
    condition     = !anytrue([for toleration in jsondecode(azapi_resource.namespace["aks-test/team-shared"].body.properties.annotations["scheduler.alpha.kubernetes.io/tolerationsWhitelist"]) : toleration.key == "platform/pool"])
    error_message = "Another tenant's whitelist should tolerate no pool, so a dedicated pool runs its own tenant's pods only."
  }
}

run "rejects_a_dedicated_tenant_whose_cell_has_no_pool_for_it" {
  command = plan

  variables {
    tenants = {
      team-payments = { zone = "team", dedicated_node_pool = true }
    }
  }

  expect_failures = [azapi_resource.namespace["aks-test/team-payments"]]
}

# A zone without pools in the cell gets no placement annotations.
run "a_zone_without_pools_places_nothing" {
  command = plan

  override_data {
    target = data.azapi_resource_list.agent_pools["aks-test"]
    values = {
      output = { labels = [] }
    }
  }

  variables {
    tenants = {
      team-payments = { zone = "team" }
    }
  }

  assert {
    condition     = !can(azapi_resource.namespace["aks-test/team-payments"].body.properties.annotations)
    error_message = "Without the zone's pools there is nothing to place on."
  }
}

# A cell of another type syncs another path of the same repository.
run "a_tenant_can_sync_another_path_in_one_cell" {
  command = plan

  variables {
    cells = {
      aks-test          = { zones = ["team"] }
      aks-test-stateful = { zones = ["team"] }
    }
    tenants = {
      team-payments = {
        zone = "team"
        flux = {
          url        = "https://github.com/contoso/payments"
          path       = "./stateless"
          cell_paths = { aks-test-stateful = "./stateful" }
        }
      }
    }
  }

  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/team-payments"].body.properties.kustomizations.apps.path == "./stateless"
      && azapi_resource.team_flux_configuration["aks-test-stateful/team-payments"].body.properties.kustomizations.apps.path == "./stateful"
    )
    error_message = "cell_paths should change the path in the cells it names only."
  }
}

# The catalogue: one YAML file per tenant, the file's name the namespace.
run "the_catalogue_files_are_tenants" {
  command = plan

  variables {
    catalogue_dir = "tests/catalogue"
  }

  assert {
    condition     = toset(keys(output.tenants)) == toset(["team-catalogued"])
    error_message = "Every file of the catalogue should be a tenant, named after the file."
  }
  assert {
    condition = (
      azapi_resource.team_flux_configuration["aks-test/team-catalogued"].body.properties.gitRepository.repositoryRef.branch == "main"
      && azapi_resource.team_flux_configuration["aks-test/team-catalogued"].body.properties.kustomizations.apps.syncIntervalInSeconds == 60
      && azapi_resource.namespace["aks-test/team-catalogued"].body.properties.labels["platform/team"] == "catalogue"
    )
    error_message = "A file should say what it needs and get the defaults for the rest."
  }
}
