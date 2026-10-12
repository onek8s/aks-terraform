# The stateless cells' networks - OneK8s design pictures 2 and 8, section 5. Every cell (a stateless
# cluster in one availability zone) has a virtual network of its own, `vnet-<cell>`, and in it one
# address range per isolation zone: the zone's own node subnet, where node auto provisioning puts the
# zone's nodes, and the subnet of the zone's internal load balancer. The system node pool has a subnet
# of its own beside them. Azure Virtual Network encryption encrypts the traffic between the nodes
# (section 13).
#
# Every subnet has its own network security group, which denies every inbound flow the design does
# not list (section 5): the kubelet from the system pool, Cilium's health checks and ICMP between the
# nodes, the pods of the cluster's overlay, the load balancers' health probes, and HTTPS from the
# internet (external zones and the platform gateway, through their public load balancers) or from
# the virtual network (internal zones). Pod-to-pod traffic between zones is the third layer's to
# stop: Cilium, in the platform repository. There is no hub Azure Firewall in the lab (the build
# tenant's network mode `sandbox`), so the nodes reach the internet through the cluster's load
# balancer and the NSGs and Cilium are the boundaries.
#
# Each cell's layout follows from its address space and the zones' indexes: a /24 per slot - the
# system pool's first, then one per zone (index 1, 2, ...) - split into the zone's nodes (the first
# half) and its internal load balancer (a /27 in the second half).
locals {
  cell_subnets = merge([
    for cell, settings in var.cells : merge(
      {
        "${cell}/snet-system" = {
          cell   = cell
          name   = "snet-system"
          zone   = null
          kind   = "system"
          prefix = cidrsubnet(settings.address_space, 4, 0)
        }
      },
      merge([
        for zone, z in var.isolation_zones : {
          "${cell}/snet-${zone}-nodes" = {
            cell   = cell
            name   = "snet-${zone}-nodes"
            zone   = zone
            kind   = "nodes"
            prefix = cidrsubnet(cidrsubnet(settings.address_space, 4, z.index), 1, 0)
          }
          "${cell}/snet-${zone}-ilb" = {
            cell   = cell
            name   = "snet-${zone}-ilb"
            zone   = zone
            kind   = "ilb"
            prefix = cidrsubnet(cidrsubnet(settings.address_space, 4, z.index), 3, 4)
          }
        }
      ]...)
    )
  ]...)

  # Every node subnet of a cell - the system pool's and each zone's - for the rules between nodes.
  cell_node_prefixes = {
    for cell in keys(var.cells) : cell => [
      for key, subnet in local.cell_subnets : subnet.prefix if subnet.cell == cell && subnet.kind != "ilb"
    ]
  }

  # The inbound flows each subnet allows, keyed `<cell>/<subnet>/<rule>`. Sources are address
  # prefixes or a service tag; never `VirtualNetwork` between zones.
  cell_nsg_rules = merge(
    # Node subnets - the system pool's and the zones'.
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/kubelet-from-system" = { subnet = key, priority = 100, protocol = "Tcp", ports = ["10250"], sources = [local.cell_subnets["${subnet.cell}/snet-system"].prefix] }
        "${key}/cilium-health"       = { subnet = key, priority = 110, protocol = "Tcp", ports = ["4240"], sources = local.cell_node_prefixes[subnet.cell] }
        "${key}/icmp"                = { subnet = key, priority = 120, protocol = "Icmp", ports = ["*"], sources = local.cell_node_prefixes[subnet.cell] }
        # Azure CNI Overlay keeps the pod addresses between nodes; which pod may reach which is
        # Cilium's to decide.
        "${key}/pods"        = { subnet = key, priority = 130, protocol = "*", ports = ["*"], sources = [var.cell_pod_cidr] }
        "${key}/lb-probes"   = { subnet = key, priority = 140, protocol = "*", ports = ["*"], sources = ["AzureLoadBalancer"] }
        "${key}/same-subnet" = { subnet = key, priority = 150, protocol = "*", ports = ["*"], sources = [subnet.prefix] }
      } if subnet.kind != "ilb"
    ]...),
    # HTTPS to the entry points: an external zone's and the platform gateway's public load balancer
    # from the internet, an internal zone's load balancer from the virtual network. Port 443 only -
    # no plain HTTP anywhere (section 13).
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/https" = {
          subnet   = key
          priority = 200
          protocol = "Tcp"
          ports    = ["443"]
          sources  = [subnet.kind == "system" || try(var.isolation_zones[subnet.zone].exposure, "") == "ext" ? "Internet" : "VirtualNetwork"]
        }
      } if subnet.kind == "system" || subnet.kind == "nodes" || (subnet.kind == "ilb" && try(var.isolation_zones[subnet.zone].exposure, "") == "int")
    ]...),
  )
}

resource "azurerm_virtual_network" "cell" {
  for_each = var.cells

  name                = "vnet-${each.key}"
  location            = var.location
  resource_group_name = local.resource_group_name
  address_space       = [each.value.address_space]

  # The only enforcement mode there is: a VM size without support sends in the clear, so the node
  # pools' size allow-lists keep to sizes that support it.
  encryption {
    enforcement = "AllowUnencrypted"
  }
}

resource "azurerm_network_security_group" "cell" {
  for_each = local.cell_subnets

  name                = "nsg-${each.value.cell}-${trimprefix(each.value.name, "snet-")}"
  location            = var.location
  resource_group_name = local.resource_group_name
}

resource "azurerm_network_security_rule" "cell_allow" {
  for_each = local.cell_nsg_rules

  name                        = "allow-${split("/", each.key)[2]}"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.ports == ["*"] ? "*" : null
  destination_port_ranges     = each.value.ports == ["*"] ? null : each.value.ports
  source_address_prefix       = length(each.value.sources) == 1 ? each.value.sources[0] : null
  source_address_prefixes     = length(each.value.sources) == 1 ? null : each.value.sources
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.cell[each.value.subnet].name
}

resource "azurerm_network_security_rule" "cell_deny" {
  for_each = local.cell_subnets

  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.cell[each.key].name
}

resource "azurerm_subnet" "cell" {
  for_each = local.cell_subnets

  name                 = each.value.name
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.cell[each.value.cell].name
  address_prefixes     = [each.value.prefix]
  # The internal load balancers' subnets may carry a Private Link Service later.
  private_link_service_network_policies_enabled = each.value.kind != "ilb"
}

resource "azurerm_subnet_network_security_group_association" "cell" {
  for_each = local.cell_subnets

  subnet_id                 = azurerm_subnet.cell[each.key].id
  network_security_group_id = azurerm_network_security_group.cell[each.key].id

  # The rules first: a subnet must never be associated with a group that denies everything.
  depends_on = [azurerm_network_security_rule.cell_allow]
}

# The internal zones' names - `<zone>.<environment>.<domain>` - resolve only inside the cells, from an
# Azure Private DNS zone each, linked to every cell's network. Each cluster's external-dns keeps the
# records of the routes its internal zones' Gateways serve.
resource "azurerm_private_dns_zone" "internal" {
  for_each = toset(var.internal_dns_zones)

  name                = each.key
  resource_group_name = local.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  for_each = { for pair in setproduct(var.internal_dns_zones, keys(var.cells)) : "${pair[0]}/${pair[1]}" => { zone = pair[0], cell = pair[1] } }

  name                  = "vnet-${each.value.cell}"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.internal[each.value.zone].name
  virtual_network_id    = azurerm_virtual_network.cell[each.value.cell].id
}

check "cells_have_room_for_every_zone" {
  assert {
    condition     = alltrue([for zone in values(var.isolation_zones) : zone.index >= 1 && zone.index <= 15])
    error_message = "An isolation zone's index picks its /24 in each cell's address space: 1 to 15 (0 is the system pool's)."
  }
}
