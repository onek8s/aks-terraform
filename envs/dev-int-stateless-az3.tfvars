# Internal cell `int-stateless-az3` of the OneK8s dev environment (design section 3.1), the lab's one cell:
# availability zone 3, Sweden's and Finland's zones. Azure CNI Pod Subnet with dynamic IP allocation - the pods take
# addresses of their pool's pod subnet in 100.64.0.0/16 and keep them up to the hub's firewall (labfw),
# which decides every flow that leaves the cluster by zone (the subnet) and by application (the pod's
# address, which the egress agent of onek8s/aks-ai-agents maps to its namespace). The zone's nodes come
# from classic node pools with the cluster autoscaler. envs/dev-int-stateless.tfvars holds what every cell shares and is applied with this file:
#
#   terraform workspace select -or-create dev-int-stateless-az3
#   terraform apply -var-file=envs/dev-int-stateless.tfvars -var-file=envs/dev-int-stateless-az3.tfvars

name                 = "aks-dev-int-stateless-az3"
virtual_network_name = "vnet-dev-int-stateless-az3"

# The system pool: TWO amd64 nodes in availability zone 3, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption; two, because App Routing's istiod takes 2 x 2 GiB) - fits only with the cost savings of the shared file - on an ephemeral OS disk on the size's
# local NVMe disk: no managed OS disk, so no Premium SSD. Production: node_count = 2 on the default
# Standard_D4ds_v5 (16 GiB) - room for istiod and the VPA add-on, and a node to spare during an upgrade
# (design section 2.3). Azure Linux 3.0, encryption at host, SSH off and the CriticalAddonsOnly taint - only
# the platform's own controllers run here, every isolation zone's pods on that zone's nodes - are the
# defaults, the design's in every environment.
# The system pool's pods take addresses of snet-system-pods (100.64.0.0/20), handed to the node in batches
# of 16 as it needs them (dynamic IP allocation), so a high limit reserves nothing. 250 pods a node, the most
# AKS allows; it cannot change on a running pool.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["3"]
  enable_auto_scaling = false
  node_count          = 2
  max_pods            = 250
}
pod_subnet_name = "snet-system-pods"

# Egress through the hub firewall: the
# cell's subnets send 0.0.0.0/0 there (shared/: hub), so AKS creates no outbound load balancer rule, and
# labfw translates every flow that leaves the landing zone. Neither can change on a running cluster.
network_profile = {
  outbound_type = "userDefinedRouting"
}

# The zones - Sweden's int-se and, since 2026-10-20, Finland's int-fi, so that the lab has two zones in one
# cell to test the isolation between them (design D73, V31): each zone's nodes in snet-<zone>-nodes with
# their pods in snet-<zone>-pods, from classic node pools - se2, se2spot, se2arm, se2armspot per generation,
# from zero nodes in availability zone 3 - scaled by the cluster autoscaler, whose priority expander takes
# the spot pools first (aks-fluxcd-platform, clusters/dev-int-stateless-az3). Sized for the lab's quotas in
# germanywestcentral: Daldv6 12 vCPUs (the system node takes 4, so four 2-vCPU amd64 nodes in all - one per
# zone and generation during a blue/green pool upgrade), low-priority (spot) 3 vCPUs (one spot node; the
# other zone's spot pod falls back to on-demand).
# Each gateway reads its listener certificate from the platform vault (<zone>-gateway--wildcard);
# flux-system the observability chart's credentials; the zones' names are in shared/'s private DNS zones.
zone_node_pools = {
  max_count      = 1
  spot_max_count = 1
  # Generation 2 since the lab's blue/green node pool upgrade of 2026-11-09 (design section 3.6, README
  # "Blue/green node pool upgrades"): generation 1 retired, then removed.
  generations = {
    "2" = {}
  }
}
isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
  int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
}
key_vault_namespaces    = ["flux-system", "int-fi-gateway", "int-se-gateway"]
internal_dns_zone_names = ["int-fi.dev.onek8s.lol", "int-se.dev.onek8s.lol"]

# The tenants - the application namespaces, int-se-example and int-fi-example in the lab - are not this
# cell's: tenants/ deploys each into every cell of its zone (tenants/catalogue/dev/, design section 3.3).
# What is the cell's is the capacity a tenant asks for: int-se-example's node pools of its own (README
# "Namespace node pools", design section 2.3) - se2ex and se2exspot, tainted and labelled
# platform/pool=int-se-example; its catalogue file says dedicated_node_pool, and its namespace's
# annotations place its pods.
namespace_node_pools = {
  int-se-example = {
    name  = "ex"
    kinds = ["", "spot"]
  }
}

flux_git_repository = {
  url    = "https://github.com/onek8s/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/dev-int-stateless-az3"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}
