# The stateless cells' networks - OneK8s design pictures 2.1 and 3.1, section 5. Every cell (a stateless
# cluster in one availability zone) has a virtual network of its own, `vnet-<cell>`, and in it one
# address range per isolation zone: the zone's own node subnet, where node auto provisioning puts the
# zone's nodes, and the subnet of the zone's internal load balancer. The system node pool has a subnet
# of its own beside them. Azure Virtual Network encryption encrypts the traffic between the nodes
# (section 4.1).
#
# Every subnet has its own network security group, which denies every inbound flow the design does
# not list (section 2.4): the kubelet from the system pool, Cilium's health checks and ICMP between the
# nodes, the pods of the cluster's overlay, the load balancers' health probes, and HTTPS from the
# internet (external zones and the platform gateway, through their public load balancers) or from
# the virtual network (internal zones). Pod-to-pod traffic between zones is the third layer's to
# stop: Cilium, in the platform repository. With `hub` (the build tenant's network mode `labfw`, or
# `firewall`) every cell is peered with the landing zone's hub and its node subnets send everything
# else to the hub's firewall, which decides what a cell reaches outside its own network - and, since
# design D73, what one zone of the cell may reach in another: a zone's node subnet has a route table
# of its own, `rt-<cell>-<zone>`, that routes every other zone's slot to the firewall as well, while
# the system pool's subnet keeps `rt-<cell>` with the default route alone. Without a hub (`sandbox`)
# the nodes reach the internet through the cluster's load balancer and the NSGs and Cilium are the
# boundaries.
#
# Each cell's layout follows from its address space and the zones' indexes: a /24 per slot - the system
# pool's first, then one per zone (index 1, 2, ...) - split into the zone's nodes (the first half) and its
# internal load balancer (the fifth eighth, a /27). A cell with `pod_network = "pod-subnet"` (design D74)
# has no overlay: its pods take addresses of a pod subnet of their own, laid out the same way in a second
# address space of the VNet, `pod_address_space` - a /16 of 100.64.0.0/10 with a /20 per slot:
# `snet-system-pods` in slot 0, `snet-<zone>-pods` in the zone's. With `api_server_subnet`, slot 15 starts
# with `snet-apiserver`, a /28 delegated to AKS for API Server VNet Integration (design section 2.2) -
# which Azure refuses on an encrypted network with v4+ VM sizes, so no cell has it yet.
locals {
  # The enabled isolation zones: a disabled country's zone keeps its index but gets nothing.
  isolation_zones = { for zone, z in var.isolation_zones : zone => z if z.enabled }
  # The enabled cells: a disabled cell keeps its address space but gets no network.
  cells = { for cell, c in var.cells : cell => c if c.enabled }

  # A cell's slot: the /24 with that index in its address space - and in a pod-subnet cell the /20 with
  # the same index in its pod address space.
  cell_slots = {
    for cell, settings in local.cells : cell => [for index in range(16) : cidrsubnet(settings.address_space, 24 - tonumber(split("/", settings.address_space)[1]), index)]
  }
  cell_pod_slots = {
    for cell, settings in local.cells : cell => [for index in range(16) : cidrsubnet(settings.pod_address_space, 4, index)] if settings.pod_network == "pod-subnet"
  }

  cell_subnets = merge([
    for cell, settings in local.cells : merge(
      {
        "${cell}/snet-system" = {
          cell   = cell
          name   = "snet-system"
          zone   = null
          kind   = "system"
          prefix = local.cell_slots[cell][0]
        }
      },
      settings.pod_network != "pod-subnet" ? {} : {
        "${cell}/snet-system-pods" = {
          cell   = cell
          name   = "snet-system-pods"
          zone   = null
          kind   = "system-pods"
          prefix = local.cell_pod_slots[cell][0]
        }
      },
      !settings.api_server_subnet ? {} : {
        "${cell}/snet-apiserver" = {
          cell   = cell
          name   = "snet-apiserver"
          zone   = null
          kind   = "apiserver"
          prefix = cidrsubnet(local.cell_slots[cell][15], 4, 0)
        }
      },
      merge([
        for zone, z in local.isolation_zones : {
          "${cell}/snet-${zone}-nodes" = {
            cell   = cell
            name   = "snet-${zone}-nodes"
            zone   = zone
            kind   = "nodes"
            prefix = cidrsubnet(local.cell_slots[cell][z.index], 1, 0)
          }
          "${cell}/snet-${zone}-ilb" = {
            cell   = cell
            name   = "snet-${zone}-ilb"
            zone   = zone
            kind   = "ilb"
            prefix = cidrsubnet(local.cell_slots[cell][z.index], 3, 4)
          }
        }
      ]...),
      settings.pod_network != "pod-subnet" ? {} : {
        for zone, z in local.isolation_zones : "${cell}/snet-${zone}-pods" => {
          cell   = cell
          name   = "snet-${zone}-pods"
          zone   = zone
          kind   = "pods"
          prefix = local.cell_pod_slots[cell][z.index]
        }
      },
    )
  ]...)

  # The subnets that hold nodes or pods - the system pool's and each zone's, and in a pod-subnet cell their
  # pod subnets, which take the rules of their pool's node subnet - and the system pool's ones.
  cell_host_kinds   = ["system", "nodes", "system-pods", "pods"]
  cell_system_kinds = ["system", "system-pods"]

  # Every pod subnet of a pod-subnet cell, for the rule that lets the pods in.
  cell_pod_prefixes = {
    for cell in keys(local.cells) : cell => [
      for key, subnet in local.cell_subnets : subnet.prefix if subnet.cell == cell && contains(["system-pods", "pods"], subnet.kind)
    ]
  }

  # Every node subnet of a cell - the system pool's and each zone's - for the rules between nodes.
  cell_node_prefixes = {
    for cell in keys(local.cells) : cell => [
      for key, subnet in local.cell_subnets : subnet.prefix if subnet.cell == cell && contains(["system", "nodes"], subnet.kind)
    ]
  }

  # The inbound flows each subnet allows, keyed `<cell>/<subnet>/<rule>`. Sources are address
  # prefixes or a service tag; never `VirtualNetwork` between zones.
  cell_nsg_rules = merge(
    # Node subnets - the system pool's and the zones' - and their pod subnets.
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/kubelet-from-system" = { subnet = key, priority = 100, protocol = "Tcp", ports = ["10250"], sources = [local.cell_subnets["${subnet.cell}/snet-system"].prefix] }
        "${key}/cilium-health"       = { subnet = key, priority = 110, protocol = "Tcp", ports = ["4240"], sources = local.cell_node_prefixes[subnet.cell] }
        "${key}/icmp"                = { subnet = key, priority = 120, protocol = "Icmp", ports = ["*"], sources = local.cell_node_prefixes[subnet.cell] }
        # CoreDNS, which runs on the system pool, for what queries it from a node's own address - the
        # ACNS DNS proxy forwarding a pod's query.
        "${key}/dns" = { subnet = key, priority = 125, protocol = "*", ports = ["53"], sources = local.cell_node_prefixes[subnet.cell] }
        # Azure CNI Overlay keeps the pod addresses between nodes; which pod may reach which is
        # Cilium's to decide. In a pod-subnet cell (`pod_network = "pod-subnet"`, design D74) the pods
        # have addresses of the cell's pod subnets, so those are let in - between zones the hub
        # firewall sees them as well (D73), and Cilium decides inside a zone.
        "${key}/pods"        = { subnet = key, priority = 130, protocol = "*", ports = ["*"], sources = local.cells[subnet.cell].pod_network == "pod-subnet" ? local.cell_pod_prefixes[subnet.cell] : [var.cell_pod_cidr] }
        "${key}/lb-probes"   = { subnet = key, priority = 140, protocol = "*", ports = ["*"], sources = ["AzureLoadBalancer"] }
        "${key}/same-subnet" = { subnet = key, priority = 150, protocol = "*", ports = ["*"], sources = [subnet.prefix] }
      } if contains(local.cell_host_kinds, subnet.kind)
    ]...),
    # The VNet-integrated API server: the kubelet (logs, exec) and admission webhooks
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/api-server" = { subnet = key, priority = 160, protocol = "Tcp", ports = ["*"], sources = [local.cell_subnets["${subnet.cell}/snet-apiserver"].prefix] }
      } if contains(local.cell_host_kinds, subnet.kind) && contains(keys(local.cell_subnets), "${subnet.cell}/snet-apiserver")
    ]...),
    # The API server's subnet: HTTPS from the network (the nodes, and through the hub's peering the
    # management network and the labfw VPN, which arrive SNATed to the firewall), the nodes' tunnel
    # port and the load balancer's health probes.
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/lb-probes" = { subnet = key, priority = 140, protocol = "*", ports = ["*"], sources = ["AzureLoadBalancer"] }
        "${key}/https"     = { subnet = key, priority = 200, protocol = "Tcp", ports = ["443"], sources = ["VirtualNetwork"] }
        "${key}/tunnel"    = { subnet = key, priority = 210, protocol = "Tcp", ports = ["4443"], sources = local.cell_node_prefixes[subnet.cell] }
      } if subnet.kind == "apiserver"
    ]...),
    # HTTPS to the entry points: an external zone's and the platform gateway's public load balancer
    # from the internet, an internal zone's load balancer from the virtual network. Port 443 only -
    # no plain HTTP anywhere (section 4.1). Every zone's gateway runs on the system pool (so that a
    # zone without applications has no nodes), which therefore takes both.
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/https" = {
          subnet   = key
          priority = 200
          protocol = "Tcp"
          ports    = ["443"]
          sources  = [contains(local.cell_system_kinds, subnet.kind) || try(local.isolation_zones[subnet.zone].exposure, "") == "ext" ? "Internet" : "VirtualNetwork"]
        }
      } if contains(local.cell_host_kinds, subnet.kind) || (subnet.kind == "ilb" && try(local.isolation_zones[subnet.zone].exposure, "") == "int")
    ]...),
    # With `hub`: ping from the hub firewall's address, which the management network and the labfw VPN
    # arrive as (SNAT) - the nodes answer it; never `VirtualNetwork`, which would let the zones ping each
    # other. Not the load balancers' subnets: an internal load balancer's frontend forwards only its rules'
    # protocols (TCP 443) and does not answer ping itself, nor does a private endpoint.
    merge([
      for key, subnet in local.cell_subnets : {
        "${key}/icmp-from-hub-firewall" = { subnet = key, priority = 220, protocol = "Icmp", ports = ["*"], sources = [var.hub.next_hop_ip] }
      } if var.hub != null && contains(local.cell_host_kinds, subnet.kind)
    ]...),
    # A rule takes one service tag, so the system pool's HTTPS from the network is a rule of its own.
    {
      for key, subnet in local.cell_subnets : "${key}/https-from-network" => {
        subnet   = key
        priority = 210
        protocol = "Tcp"
        ports    = ["443"]
        sources  = ["VirtualNetwork"]
      } if contains(local.cell_system_kinds, subnet.kind)
    },
  )
}

resource "azurerm_virtual_network" "cell" {
  for_each = local.cells

  name                = local.names["virtual_network/${each.key}"]
  location            = var.location
  resource_group_name = local.resource_group_name
  # A pod-subnet cell's pod address space beside the nodes'
  address_space = compact([each.value.address_space, each.value.pod_address_space])
  # The hub firewall's DNS proxy with `hub`; Azure DNS otherwise
  dns_servers = var.hub == null ? [] : var.hub.dns_servers

  # The only enforcement mode there is: a VM size without support sends in the clear, so the node
  # pools' size allow-lists keep to sizes that support it.
  encryption {
    enforcement = "AllowUnencrypted"
  }
}

resource "azurerm_network_security_group" "cell" {
  for_each = local.cell_subnets

  name                = local.names["network_security_group/${each.key}"]
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

  dynamic "delegation" {
    for_each = each.value.kind == "apiserver" ? [1] : []
    content {
      name = "aks-api-server"
      service_delegation {
        name    = "Microsoft.ContainerService/managedClusters"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "cell" {
  for_each = local.cell_subnets

  subnet_id                 = azurerm_subnet.cell[each.key].id
  network_security_group_id = azurerm_network_security_group.cell[each.key].id

  # The rules first: a subnet must never be associated with a group that denies everything.
  depends_on = [azurerm_network_security_rule.cell_allow]
}

# With `hub`: the cell's network is peered with the landing zone's hub - both directions, the hub's
# side as the identity's `AKS spoke peering` role allows - and its node subnets send everything that
# is not in the cell to the hub's firewall (Azure Firewall or labfw). The clusters then egress through
# it (AKS outbound type `userDefinedRouting`); a public load balancer in a cell does not work behind it
# (answers would leave by the default route), so a routed cell serves the internal exposure only.
locals {
  hub_subscription_id = try(split("/", var.hub.virtual_network_id)[2], null)
  hub_virtual_network = var.hub == null ? null : {
    id                  = var.hub.virtual_network_id
    name                = split("/", var.hub.virtual_network_id)[8]
    resource_group_name = split("/", var.hub.virtual_network_id)[4]
  }
}

# The system pool's route table: the default route to the hub's firewall, nothing else. Traffic to the
# cell's own address space takes the virtual network's system route, which is more specific, so the
# system pool reaches every zone's nodes directly: the kubelet tunnel, metrics-server and the API
# server's private endpoint stay inside the cell (design section 2.4, flows 1 to 4).
resource "azurerm_route_table" "cell" {
  for_each = var.hub == null ? {} : local.cells

  name                          = local.names["route_table/${each.key}"]
  location                      = var.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-via-hub-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.hub.next_hop_ip
  }
}

# A zone's route table (design D73): the default route, plus every other zone's slot - occupied or
# free, so that a new zone changes no existing table - with the hub's firewall as the next hop. A
# slot's route is more specific than the virtual network's system route, so what one zone sends to
# another leaves for the firewall, which denies and logs it (nothing is allowed between zones, design
# R5 and section 2.4); a flow the firewall did allow would come back through the hub's peering. Not
# the zone's own slot: Azure applies a route to the traffic within a subnet too, and the nodes of one
# zone talk to each other directly. Not the system pool's slot either, for the flows above. And not
# the pods of an overlay cell, whose addresses Azure routes between the nodes in a routing domain of
# their own that no route table reaches - between zones those are Cilium's alone. A pod-subnet cell
# (`pod_network = "pod-subnet"`, design D74) routes the other zones' pod slots the same way, and its pod
# subnets take their pool's table, so there the firewall sees the pods too. Each route is named after
# the zone that holds the slot (enabled or not), or `slot-<n>` while it is free; a pod slot's adds `-pods`.
locals {
  cell_zone_route_tables = var.hub == null ? {} : merge([
    for cell, settings in local.cells : {
      for zone, z in local.isolation_zones : "${cell}/${zone}" => {
        cell = cell
        zone = zone
        routes = merge(
          {
            for index in range(1, 15) :
            "${coalesce(one([for other, o in var.isolation_zones : other if o.index == index]), "slot-${index}")}-via-hub-firewall" => local.cell_slots[cell][index]
            if index != z.index
          },
          {
            for index in range(1, 15) :
            "${coalesce(one([for other, o in var.isolation_zones : other if o.index == index]), "slot-${index}")}-pods-via-hub-firewall" => local.cell_pod_slots[cell][index]
            if index != z.index && settings.pod_network == "pod-subnet"
          },
        )
      }
    }
  ]...)
}

resource "azurerm_route_table" "zone" {
  for_each = local.cell_zone_route_tables

  name                          = local.names["route_table/${each.key}"]
  location                      = var.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-via-hub-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.hub.next_hop_ip
  }

  dynamic "route" {
    for_each = each.value.routes
    content {
      name                   = route.key
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = var.hub.next_hop_ip
    }
  }
}

# Node and pod subnets only: an internal load balancer's subnet holds no NICs, and the API server's answers
# its clients by the system routes (the hub's peering). The system pool's subnets take the cell's table, a
# zone's node and pod subnets the zone's.
resource "azurerm_subnet_route_table_association" "cell" {
  for_each = var.hub == null ? {} : { for key, subnet in local.cell_subnets : key => subnet if contains(local.cell_host_kinds, subnet.kind) }

  subnet_id      = azurerm_subnet.cell[each.key].id
  route_table_id = contains(local.cell_system_kinds, each.value.kind) ? azurerm_route_table.cell[each.value.cell].id : azurerm_route_table.zone["${each.value.cell}/${each.value.zone}"].id
}

resource "azurerm_virtual_network_peering" "cell_to_hub" {
  for_each = var.hub == null ? {} : local.cells

  name                         = "peer-${each.key}-to-hub"
  resource_group_name          = local.resource_group_name
  virtual_network_name         = azurerm_virtual_network.cell[each.key].name
  remote_virtual_network_id    = local.hub_virtual_network.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_cell" {
  provider = azurerm.hub
  for_each = var.hub == null ? {} : local.cells

  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = local.hub_virtual_network.resource_group_name
  virtual_network_name         = local.hub_virtual_network.name
  remote_virtual_network_id    = azurerm_virtual_network.cell[each.key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
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
  for_each = { for pair in setproduct(var.internal_dns_zones, keys(local.cells)) : "${pair[0]}/${pair[1]}" => { zone = pair[0], cell = pair[1] } }

  name                  = "vnet-${each.value.cell}"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.internal[each.value.zone].name
  virtual_network_id    = azurerm_virtual_network.cell[each.value.cell].id
}

# With `hub`, the hub too: the cells resolve through the hub firewall's DNS proxy, which answers from
# the hub's links (and so does the corporate network behind it).
resource "azurerm_private_dns_zone_virtual_network_link" "internal_hub" {
  for_each = var.hub == null ? toset([]) : toset(var.internal_dns_zones)

  name                  = local.hub_virtual_network.name
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.internal[each.key].name
  virtual_network_id    = local.hub_virtual_network.id
}

check "cells_have_room_for_every_zone" {
  assert {
    condition     = alltrue([for zone in values(var.isolation_zones) : zone.index >= 1 && zone.index <= 14])
    error_message = "An isolation zone's index picks its /24 in each cell's address space: 1 to 14 (0 is the system pool's, 15 the API server's)."
  }
}
