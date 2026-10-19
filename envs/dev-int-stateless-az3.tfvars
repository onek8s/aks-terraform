# Internal cell `int-stateless-az3` of the OneK8s dev environment (design section 3.1), the lab's one cell:
# availability zone 3, Sweden's zone. Azure CNI Pod Subnet with dynamic IP allocation - the pods take
# addresses of their pool's pod subnet in 100.64.0.0/16 and keep them up to the hub's firewall (labfw),
# which decides every flow that leaves the cluster by zone (the subnet) and by application (the pod's
# address, which the egress agent of onek8s/aks-ai-agents maps to its namespace). The zone's nodes come
# from classic node pools with the cluster autoscaler. envs/dev-int-stateless.tfvars holds what every cell shares and is applied with this file:
#
#   terraform workspace select -or-create dev-int-stateless-az3
#   terraform apply -var-file=envs/dev-int-stateless.tfvars -var-file=envs/dev-int-stateless-az3.tfvars

name                 = "aks-dev-int-stateless-az3"
virtual_network_name = "vnet-dev-int-stateless-az3"

# The system pool: ONE amd64 node in availability zone 3, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption) - fits only with the cost savings of the shared file - on an ephemeral OS disk on the size's
# local NVMe disk: no managed OS disk, so no Premium SSD. Production: node_count = 2 on the default
# Standard_D4ds_v5 (16 GiB) - room for istiod and the VPA add-on, and a node to spare during an upgrade
# (design section 2.3). The other attributes are the design's in every environment: Azure Linux 3.0 (eBPF
# host routing needs it on every node), encryption at host, SSH off, and the CriticalAddonsOnly taint - only
# the platform's own controllers run here, every isolation zone's pods on that zone's nodes.
# The system pool's pods take addresses of snet-system-pods (100.64.0.0/20), handed to the node in batches
# of 16 as it needs them (dynamic IP allocation), so a high limit reserves nothing. 250 pods a node, the most
# AKS allows; it cannot change on a running pool.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["3"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
  max_pods            = 250
}
pod_subnet_name = "snet-system-pods"

# Egress through the hub firewall: the
# cell's subnets send 0.0.0.0/0 there (shared/: hub), so AKS creates no outbound load balancer rule, and
# labfw translates every flow that leaves the landing zone. Neither can change on a running cluster.
network_profile = {
  outbound_type = "userDefinedRouting"
}

# Sweden's zone: its nodes in snet-int-se-nodes with their pods in snet-int-se-pods, from classic node
# pools - intse, intsespot, intsearm, intsearmspot, from zero nodes in availability zone 3 - scaled by the
# cluster autoscaler, whose priority expander takes the spot pools first (aks-fluxcd-platform,
# clusters/dev-int-stateless-az3). Sized for the lab's quotas in germanywestcentral: Daldv6
# 8 vCPUs (the system node takes 4, so two 2-vCPU amd64 nodes), low-priority (spot) 3 vCPUs (one spot
# node). Its gateway reads its listener certificate from the platform vault (int-se-gateway--wildcard);
# flux-system the observability chart's credentials. The application namespace's share is in the zone's
# vault; the zone's names are in shared/'s private DNS zone.
zone_node_pools = {
  max_count      = 2
  spot_max_count = 1
}
isolation_zones = {
  int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
}
key_vault_namespaces = ["flux-system", "int-se-gateway"]
key_vault_namespace_vaults = {
  int-se-example = "kv-onek8s-gwc-int-se"
}
internal_dns_zone_names = ["int-se.dev.onek8s.lol"]

# The `example` team's application, in the int-se zone (design section 2.6: one namespace per
# application and zone, `<zone>-<app>`). Its own Flux configuration deploys firewall-egress/ of
# onek8s/aks-fluxcd-example into it - aks-hello on the zone's own nodes, with its weather forecast from
# the internet - and its routes attach to the int-se gateway. Ingress and egress inside the cluster are
# closed to its own namespace by the namespace's default policies; egress outside the cluster is left
# to labfw (design section 5.2): the zone's platform policy lets it leave, and the firewall allows only what the
# zone's and the application's firewall rules name - anything else is denied there, and the egress agent
# proposes the rule.
managed_namespaces = {
  int-se-example = {
    # Who owns the application and pays for it: labels platform/team and platform/cost-center, the
    # annotation platform/contact (design section 2.6; Azure Policy namespace-ownership).
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-se"
    }
    # Inside the cluster, its own namespace only; outside it, the zone's platform policy lets everything
    # through to labfw (aks-fluxcd-platform, infrastructure/zones/firewall-egress).
    network_policy = {
      ingress = "AllowSameNamespace"
      egress  = "AllowSameNamespace"
    }
    flux = {
      url  = "https://github.com/onek8s/aks-fluxcd-example"
      path = "./firewall-egress"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
      # The zone and its domain, for the team's routes; home_cell: the cluster that publishes the team's
      # internal names (design section 3.1) - this one, the only cell of int-se.
      substitute = {
        zone        = "int-se"
        zone_domain = "int-se.dev.onek8s.lol"
        home_cell   = "aks-dev-int-stateless-az3"
      }
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateless-az3"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}
