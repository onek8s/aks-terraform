# Internal cell `int-stateless-az2` of the OneK8s dev environment (design section 3.1): availability
# zone 2, Finland's zone, the lab's OVERLAY cell (design D61, A in 5.2) - Azure CNI Overlay without ACNS,
# node auto provisioning for the zone's nodes, the hub firewall (labfw) deciding egress by the zone's node
# addresses. Its sibling az3 is the pod-subnet cell; the two stay for the security discussion (H15).
# envs/dev-int-stateless.tfvars holds what every cell shares and is applied with this file:
#
#   terraform workspace select -or-create dev-int-stateless-az2
#   terraform apply -var-file=envs/dev-int-stateless.tfvars -var-file=envs/dev-int-stateless-az2.tfvars

name                 = "aks-dev-int-stateless-az2"
virtual_network_name = "vnet-dev-int-stateless-az2"

# The system pool: ONE amd64 node in availability zone 2, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption) - fits only with the cost savings of the shared file - on an ephemeral OS disk on the size's
# local NVMe disk: no managed OS disk, so no Premium SSD. Production: node_count = 2 on the default
# Standard_D4ds_v5 (16 GiB) - room for istiod and the VPA add-on, and a node to spare during an upgrade
# (design section 2.3). AKS's cilium-operator runs two replicas on different nodes, so with one system
# node its second replica brings up one small zone spot node.
# The other attributes are the design's in every environment: Azure Linux 3.0, encryption at host, SSH
# off, and the CriticalAddonsOnly taint - only the platform's own controllers run here, every isolation
# zone's pods on that zone's nodes.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["2"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
}

# No Advanced Container Networking Services (design D61): no FQDN policies, no Hubble, no eBPF host
# routing - and none of their per-node cost. The hub firewall decides what leaves the cell, per zone (with
# the overlay it sees the zone's node addresses); Cilium keeps the in-cluster policies at layer 4
# (aks-fluxcd-platform clusters/dev-int-stateless-az2 patches them). Decided when the cluster is created.
advanced_networking = null

# Azure CNI Overlay (the default pod range), egress through the hub firewall: the cell's subnets send
# 0.0.0.0/0 there (shared/: hub), so AKS creates no outbound load balancer rule. Cannot change on a
# running cluster.
network_profile = {
  outbound_type = "userDefinedRouting"
}

# Finland's zone: its nodes in snet-int-fi-nodes, from node auto provisioning (NAP, the AKS-managed
# Karpenter): the platform repository's NodePools per zone, on-demand and spot, in this cell's
# availability zone. Its gateway reads its listener certificate from the platform vault
# (int-fi-gateway--wildcard); flux-system the observability chart's credentials. The application
# namespace's share is in the zone's vault; the zone's names are in shared/'s private DNS zone.
node_auto_provisioning_enabled = true
isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes" }
}
key_vault_namespaces = ["flux-system", "int-fi-gateway"]
key_vault_namespace_vaults = {
  int-fi-example = "kv-onek8s-gwc-int-fi"
}
internal_dns_zone_names = ["int-fi.dev.onek8s.lol"]

# The `example` team's application, in the int-fi zone (design section 2.6: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys firewall-egress-int-fi/ of
# onek8s/aks-fluxcd-example into it (aks-hello with a weather forecast, on the zone's nodes), and its routes
# attach to the int-fi gateway. Ingress and egress are closed to its own namespace by the namespace's
# default policies; the platform's Cilium baseline opens DNS and the zone gateway, and the zone's
# firewall-egress policy the way out, where the hub firewall decides (design D61).
managed_namespaces = {
  int-fi-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 2.6; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-fi"
    }
    # Who may work in the namespace (design section 2.6, D49): an Entra ID group per Kubernetes role,
    # bound by RoleBindings platform-<role>. The lab groups grp-onek8s-dev-ext-fi-example-<role>, reused
    # from the external lab, each with a tester application the isolation tests sign in as
    # (tests/isolation/namespace-access-testers.yaml).
    groups = {
      view  = "6d9ae939-5e03-4ddb-b378-baa7fa5b5180"
      edit  = "88ba3f87-2d13-46ea-8cff-eeccf6cbd0bc"
      admin = "71438fbc-0666-4d82-be17-54b61236d657"
    }
    network_policy = {
      ingress = "AllowSameNamespace"
      egress  = "AllowSameNamespace"
    }
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./firewall-egress-int-fi"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
      # The zone and its domain, for the team's routes: the gateway they attach to and their hostnames.
      # home_cell: the cluster that publishes the team's internal names (<app>.<zone domain>; design section 3.1:
      # an internal app runs in one home cell, whose external-dns alone publishes it) - the same in every cell.
      # A lab stand-in for the design's placement artifact; the routes carry it as platform/home-cell.
      substitute = {
        zone        = "int-fi"
        zone_domain = "int-fi.dev.onek8s.lol"
        home_cell   = "aks-dev-int-stateless-az2"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateless-az2"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}
