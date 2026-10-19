# Advanced Container Networking Services, the isolation zones' subnets, the namespaces' vaults and
# the internal zones' DNS - what a stateless cell of the OneK8s design needs beyond a plain cluster.

locals {
  # The network profile as sent: the variable's, with ACNS (design section 5.1) where it is asked for.
  # Without an overlay (network_plugin_mode "none", Azure CNI node subnet) no mode and no pod range.
  network_profile = merge(var.network_profile, {
    network_plugin_mode = local.pod_overlay ? var.network_profile.network_plugin_mode : null
    pod_cidr            = local.pod_overlay ? var.network_profile.pod_cidr : null
    }, var.advanced_networking == null ? {} : {
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
      # are its own - so changing it means building the cell again (section 5.1: drain, rebuild).
      performance = {
        acceleration_mode = var.advanced_networking.ebpf_host_routing ? "BpfVeth" : "None"
      }
    }
  })

  ebpf_host_routing = try(var.advanced_networking.ebpf_host_routing, false)

  # Whether the pods have an overlay range of their own, or VNet addresses - of their pools' pod subnets
  # (Azure CNI Pod Subnet, design D74) when the system pool names one, of their nodes' subnets otherwise.
  pod_overlay = var.network_profile.network_plugin_mode == "overlay"
  pod_subnet  = !local.pod_overlay && var.default_node_pool.pod_subnet_name != null

  # Whether the system pool keeps everything but the platform's controllers off it.
  system_pool_critical_addons_only = anytrue([for taint in coalesce(var.default_node_pool.node_taints, []) : startswith(taint, "CriticalAddonsOnly")])
}

check "ebpf_host_routing_needs_azure_linux_or_ubuntu_on_every_node" {
  assert {
    condition     = !local.ebpf_host_routing || contains(["AzureLinux", "AzureLinux3", "Ubuntu2404"], coalesce(var.default_node_pool.os_sku, "-"))
    error_message = "${var.name} turns on eBPF host routing, which needs Azure Linux 3.0 or Ubuntu 24.04 on every node, but default_node_pool.os_sku is ${coalesce(var.default_node_pool.os_sku, "the AKS default")}. Set it to AzureLinux."
  }
}

# The isolation zones' node subnets, for their AKSNodeClasses or node pools, and their route tables.
data "azurerm_subnet" "zone" {
  for_each = var.isolation_zones

  name                 = each.value.node_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

# A pod-subnet cell's pod subnets: the system pool's and each zone's (design D74).
data "azurerm_subnet" "system_pods" {
  count = local.pod_subnet ? 1 : 0

  name                 = var.default_node_pool.pod_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "zone_pods" {
  for_each = local.pod_subnet ? var.isolation_zones : {}

  name                 = each.value.pod_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
}

# The zones' classic node pools (zone_node_pools, design D74): per zone one per capacity type and
# architecture, from zero nodes, in the zone's node subnet with the pods in its pod subnet - labelled and
# tainted like the zone's NAP NodePools, so that the platform's placement mutations put a pod on them
# unchanged. AKS adds its own spot taint and label to a spot pool - the taint is stated here too, or
# every plan would try to take it off again; the spot toleration mutation tolerates both. The cluster
# autoscaler's priority expander (the Flux repository's ConfigMap) tries the spot pools first.
locals {
  zone_node_pool_kinds = {
    ""        = { arch = "amd64", spot = false }
    "spot"    = { arch = "amd64", spot = true }
    "arm"     = { arch = "arm64", spot = false }
    "armspot" = { arch = "arm64", spot = true }
  }

  zone_agent_pools = var.zone_node_pools == null ? {} : merge([
    for zone, settings in var.isolation_zones : {
      for suffix, kind in local.zone_node_pool_kinds : "${replace(zone, "-", "")}${suffix}" => {
        name                      = "${replace(zone, "-", "")}${suffix}"
        mode                      = "User"
        availability_zones        = var.default_node_pool.availability_zones
        count_of                  = 0
        enable_auto_scaling       = true
        min_count                 = 0
        max_count                 = kind.spot ? var.zone_node_pools.spot_max_count : var.zone_node_pools.max_count
        max_pods                  = var.zone_node_pools.max_pods
        vm_size                   = kind.arch == "arm64" ? var.zone_node_pools.arm64_vm_size : var.zone_node_pools.amd64_vm_size
        os_sku                    = var.default_node_pool.os_sku
        os_disk_type              = var.zone_node_pools.os_disk_type
        os_disk_size_gb           = var.zone_node_pools.os_disk_size_gb
        enable_encryption_at_host = var.default_node_pool.encryption_at_host
        security_profile = var.default_node_pool.ssh_access == null ? null : {
          ssh_access = var.default_node_pool.ssh_access
        }
        vnet_subnet_id = data.azurerm_subnet.zone[zone].id
        pod_subnet_id  = try(data.azurerm_subnet.zone_pods[zone].id, null)
        node_labels = merge(
          { "platform/zone" = zone },
          kind.spot ? { "platform/capacity" = "spot" } : {},
        )
        node_taints = concat(
          ["platform/zone=${zone}:NoSchedule"],
          kind.spot ? ["platform/capacity=spot:NoSchedule", "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : [],
        )
        scale_set_priority        = kind.spot ? "Spot" : null
        scale_set_eviction_policy = kind.spot ? "Delete" : null
        spot_max_price            = kind.spot ? -1 : null
        upgrade_settings = kind.spot ? null : {
          max_surge = var.default_node_pool.max_surge
        }
      }
    }
  ]...)

  # The cluster autoscaler of the zones' pools: the priority expander (spot first), and a node removed
  # five minutes after it is no longer needed, as NAP consolidates the NAP cells' zone nodes.
  auto_scaler_profile = var.zone_node_pools == null ? null : {
    expander                   = "priority"
    scale_down_unneeded_time   = "5m"
    scale_down_delay_after_add = "5m"
  }
}

check "isolation_zones_need_nodes" {
  assert {
    condition     = length(var.isolation_zones) == 0 || var.node_auto_provisioning_enabled || var.zone_node_pools != null
    error_message = "${var.name} names isolation zones, whose nodes come from node auto provisioning or the zones' node pools: turn on node_auto_provisioning_enabled, or set zone_node_pools."
  }
}

check "a_pod_subnet_cell_names_every_pools_pod_subnet" {
  assert {
    condition     = !local.pod_subnet || alltrue([for zone in values(var.isolation_zones) : zone.pod_subnet_name != null])
    error_message = "${var.name} gives its system pool a pod subnet, and AKS takes a pod subnet on every node pool or on none: name each isolation zone's pod_subnet_name."
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
      for zone, subnet in data.azurerm_subnet.zone : "nap_subnet_id_${replace(zone, "-", "_")}" => subnet.id if var.node_auto_provisioning_enabled
    },
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
