# Advanced Container Networking Services, the isolation zones' subnets, the namespaces' vaults and
# the internal zones' DNS - what a stateless cell of the OneK8s design needs beyond a plain cluster.

locals {
  # The network profile as sent: the variable's, with ACNS (design section 16) where it is asked for.
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
      # are its own - so changing it means building the cell again (section 16: drain, rebuild).
      performance = {
        acceleration_mode = var.advanced_networking.ebpf_host_routing ? "BpfVeth" : "None"
      }
    }
  })

  ebpf_host_routing = try(var.advanced_networking.ebpf_host_routing, false)

  # Whether the pods have an overlay range of their own, or addresses of their nodes' subnets.
  pod_overlay = var.network_profile.network_plugin_mode == "overlay"

  # Whether the system pool keeps everything but the platform's controllers off it.
  system_pool_critical_addons_only = anytrue([for taint in coalesce(var.default_node_pool.node_taints, []) : startswith(taint, "CriticalAddonsOnly")])
}

check "ebpf_host_routing_needs_azure_linux_or_ubuntu_on_every_node" {
  assert {
    condition     = !local.ebpf_host_routing || contains(["AzureLinux", "AzureLinux3", "Ubuntu2404"], coalesce(var.default_node_pool.os_sku, "-"))
    error_message = "${var.name} turns on eBPF host routing, which needs Azure Linux 3.0 or Ubuntu 24.04 on every node, but default_node_pool.os_sku is ${coalesce(var.default_node_pool.os_sku, "the AKS default")}. Set it to AzureLinux."
  }
}

# The isolation zones' node subnets, for their AKSNodeClasses.
data "azurerm_subnet" "zone" {
  for_each = local.byo_network ? var.isolation_zones : {}

  name                 = each.value.node_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

check "isolation_zones_need_node_auto_provisioning" {
  assert {
    condition     = length(var.isolation_zones) == 0 || (local.node_auto_provisioning && local.byo_network)
    error_message = "${var.name} names isolation zones, whose nodes node auto provisioning creates in their subnets of an existing network: turn on node_auto_provisioning_enabled and name virtual_network_name."
  }
}

# The other vaults of a shared vault's namespaces - an application's zone vault.
data "azurerm_key_vault" "namespace" {
  for_each = local.key_vault_shared ? toset(values(var.key_vault_namespace_vaults)) : toset([])

  name                = each.key
  resource_group_name = var.resource_group_name
}

locals {
  # The URL of the vault each namespace's share is in.
  key_vault_namespace_uris = {
    for namespace in local.key_vault_namespaces : namespace => (
      contains(keys(var.key_vault_namespace_vaults), namespace) && local.key_vault_shared
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
  for_each = var.create_role_assignments ? data.azurerm_private_dns_zone.internal : {}

  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
  scope                = each.value.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_type       = "ServicePrincipal"
}

locals {
  # What the Flux repository is told on top of flux_cluster_settings.
  flux_zone_settings = merge(
    {
      for zone, subnet in data.azurerm_subnet.zone : "nap_subnet_id_${replace(zone, "-", "_")}" => subnet.id
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
