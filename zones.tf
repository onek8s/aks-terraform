# Advanced Container Networking Services, the isolation zones' subnets, the namespaces' vaults and
# the internal zones' DNS - what a stateless cell of the OneK8s design needs beyond a plain cluster.

locals {
  # The network profile as sent: the variable's, with ACNS where it is asked for (off by default, D80).
  # No plugin mode and no pod range: the pods take addresses of their pools' pod subnets.
  network_profile = merge(var.network_profile, var.advanced_networking == null ? {} : {
    advanced_networking = {
      enabled = true
      observability = {
        enabled = var.advanced_networking.observability
      }
      security = {
        enabled                   = var.advanced_networking.fqdn_policies
        advanced_network_policies = var.advanced_networking.fqdn_policies ? "FQDN" : "None"
      }
      # eBPF host routing. Sent with the cluster's create request: AKS refuses to turn it on for a
      # running cluster ("User-installed iptables rules found"), even one whose only iptables rules
      # are its own - so changing it means building the cell again (design section 5.1).
      performance = {
        acceleration_mode = var.advanced_networking.ebpf_host_routing ? "BpfVeth" : "None"
      }
    }
  })

  ebpf_host_routing = try(var.advanced_networking.ebpf_host_routing, false)

  # Whether the system pool keeps everything but the platform's controllers off it.
  system_pool_critical_addons_only = anytrue([for taint in coalesce(var.default_node_pool.node_taints, []) : startswith(taint, "CriticalAddonsOnly")])
}

check "ebpf_host_routing_needs_azure_linux_or_ubuntu_on_every_node" {
  assert {
    condition     = !local.ebpf_host_routing || contains(["AzureLinux", "AzureLinux3", "Ubuntu2404"], coalesce(var.default_node_pool.os_sku, "-"))
    error_message = "${var.name} turns on eBPF host routing, which needs Azure Linux 3.0 or Ubuntu 24.04 on every node, but default_node_pool.os_sku is ${coalesce(var.default_node_pool.os_sku, "the AKS default")}. Set it to AzureLinux."
  }
}

# The isolation zones' node subnets, for their node pools, and their route tables.
data "azurerm_subnet" "zone" {
  for_each = var.isolation_zones

  name                 = each.value.node_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

# The pod subnets: the system pool's and each zone's.
data "azurerm_subnet" "system_pods" {
  name                 = var.pod_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "zone_pods" {
  for_each = var.isolation_zones

  name                 = each.value.pod_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

# The zones' classic node pools (zone_node_pools): per zone and generation one per capacity type and
# architecture, from zero nodes, in the zone's node subnet with the pods in its pod subnet - labelled and
# tainted `platform/zone` and `platform/capacity=spot`, which the platform's placement mutations target, and
# labelled `platform/node-generation`. AKS adds its own spot taint and label to a spot pool - the taint is
# stated here too, or every plan would try to take it off again; the spot toleration mutation tolerates
# both. The cluster autoscaler's priority expander (the Flux repository's ConfigMap) tries the spot pools
# first.
#
# A pool is named `<country><generation><kind>` - `se1`, `se1spot`, `se1arm`, `se1armspot` for the zone
# int-se in generation 1: AKS allows 12 characters, and the exposure is the cluster's own (D52). Two
# generations side by side are the blue/green upgrade of a zone's nodes (design section 3.6): the new one
# is added at its own Kubernetes version and settings, the old one is marked retiring - tainted
# `platform/retiring=true:NoSchedule`, so no new pod lands on it, the pods it runs stay, and the
# autoscaler removes its nodes as they empty - and is taken out of Git once it is empty, which deletes
# its pools (AKS drains what is left, PodDisruptionBudgets respected). Placement never names a pool: the
# applications' pods select `platform/zone`, which every generation carries.
locals {
  zone_node_pool_kinds = {
    ""        = { arch = "amd64", spot = false }
    "spot"    = { arch = "amd64", spot = true }
    "arm"     = { arch = "arm64", spot = false }
    "armspot" = { arch = "arm64", spot = true }
  }

  # The zone's part of a pool name: its country, the last segment of `<exposure>-<country>`.
  zone_node_pool_prefixes = { for zone in keys(var.isolation_zones) : zone => element(split("-", zone), length(split("-", zone)) - 1) }

  # Every zone's generations: those that name it, or name no zone.
  zone_node_pool_generations = var.zone_node_pools == null ? {} : {
    for zone in keys(var.isolation_zones) : zone => {
      for generation, settings in var.zone_node_pools.generations : generation => settings
      if settings.zones == null || contains(coalesce(settings.zones, []), zone)
    }
  }

  zone_agent_pools = var.zone_node_pools == null ? {} : merge(flatten([
    for zone, generations in local.zone_node_pool_generations : [
      for generation, settings in generations : {
        for suffix, kind in local.zone_node_pool_kinds : "${local.zone_node_pool_prefixes[zone]}${generation}${suffix}" => {
          name                      = "${local.zone_node_pool_prefixes[zone]}${generation}${suffix}"
          mode                      = "User"
          availability_zones        = var.default_node_pool.availability_zones
          count_of                  = 0
          enable_auto_scaling       = true
          min_count                 = 0
          max_count                 = kind.spot ? var.zone_node_pools.spot_max_count : var.zone_node_pools.max_count
          max_pods                  = coalesce(settings.max_pods, var.zone_node_pools.max_pods)
          vm_size                   = kind.arch == "arm64" ? coalesce(settings.arm64_vm_size, var.zone_node_pools.arm64_vm_size) : coalesce(settings.amd64_vm_size, var.zone_node_pools.amd64_vm_size)
          orchestrator_version      = settings.kubernetes_version
          os_sku                    = var.default_node_pool.os_sku
          os_disk_type              = coalesce(settings.os_disk_type, var.zone_node_pools.os_disk_type)
          os_disk_size_gb           = coalesce(settings.os_disk_size_gb, var.zone_node_pools.os_disk_size_gb)
          enable_encryption_at_host = var.default_node_pool.encryption_at_host
          security_profile = var.default_node_pool.ssh_access == null ? null : {
            ssh_access = var.default_node_pool.ssh_access
          }
          local_dns_profile = local.local_dns_profile
          vnet_subnet_id    = data.azurerm_subnet.zone[zone].id
          pod_subnet_id     = data.azurerm_subnet.zone_pods[zone].id
          node_labels = merge(
            { "platform/zone" = zone, "platform/node-generation" = generation },
            kind.spot ? { "platform/capacity" = "spot" } : {},
          )
          node_taints = concat(
            ["platform/zone=${zone}:NoSchedule"],
            kind.spot ? ["platform/capacity=spot:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : [],
            contains(settings.retiring_zones, zone) ? ["platform/retiring=true:NoSchedule"] : [],
          )
          scale_set_priority        = kind.spot ? "Spot" : null
          scale_set_eviction_policy = kind.spot ? "Delete" : null
          spot_max_price            = kind.spot ? -1 : null
          upgrade_settings = kind.spot ? null : {
            max_surge = var.default_node_pool.max_surge
          }
        }
      }
    ]
  ])...)

  # The cluster autoscaler of the zones' pools: the priority expander (spot first), and a node removed
  # five minutes after it is no longer needed.
  auto_scaler_profile = var.zone_node_pools == null ? null : {
    expander                   = "priority"
    scale_down_unneeded_time   = "5m"
    scale_down_delay_after_add = "5m"
  }
}

check "every_zone_has_a_generation_that_takes_pods" {
  assert {
    condition = alltrue([
      for zone, generations in local.zone_node_pool_generations : anytrue([for settings in values(generations) : !contains(settings.retiring_zones, zone)])
    ])
    error_message = "${var.name}: a zone in zone_node_pools has no generation that is not retiring, so its new pods find no node. Add the next generation before the last one retires."
  }
}

check "isolation_zones_need_nodes" {
  assert {
    condition     = length(var.isolation_zones) == 0 || var.zone_node_pools != null
    error_message = "${var.name} names isolation zones, whose nodes come from the zones' node pools: set zone_node_pools."
  }
}

# The other vaults of a shared vault's namespaces - an application's zone vault.
data "azurerm_key_vault" "namespace" {
  for_each = toset(values(var.key_vault_namespace_vaults))

  name                = each.key
  resource_group_name = var.resource_group_name
}

locals {
  # The URL of the vault each namespace's share is in.
  key_vault_namespace_uris = {
    for namespace in local.key_vault_namespaces : namespace => (
      contains(keys(var.key_vault_namespace_vaults), namespace)
      ? data.azurerm_key_vault.namespace[var.key_vault_namespace_vaults[namespace]].vault_uri
      : local.key_vault_uri
    )
  }
}

# The internal zones' Private DNS zones, in which external-dns keeps the records of the cluster's
# internal gateways.
data "azurerm_private_dns_zone" "internal" {
  for_each = local.external_dns_enabled ? toset(var.internal_dns_zone_names) : toset([])

  name                = each.key
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "external_dns_internal" {
  for_each = data.azurerm_private_dns_zone.internal

  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
  scope                = each.value.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_type       = "ServicePrincipal"
}

locals {
  # What the Flux repository is told on top of flux_cluster_settings.
  flux_zone_settings = merge(
    {
      for namespace, uri in local.key_vault_namespace_uris : "key_vault_url_${replace(namespace, "-", "_")}" => uri
    },
    length(data.azurerm_private_dns_zone.internal) == 0 ? {} : {
      internal_dns_resource_group_name = var.resource_group_name
    },
    var.exposure == null ? {} : {
      cluster_exposure = var.exposure
    },
  )
}
