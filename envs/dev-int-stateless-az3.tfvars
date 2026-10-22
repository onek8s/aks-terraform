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

# The system pool: ONE amd64 node in availability zone 3, Standard_D4alds_v6 (4 vCPU, 8 GiB, VNet
# encryption) - fits only with the cost savings of the shared file - on an ephemeral OS disk on the size's
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
  node_count          = 1
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
# their pods in snet-<zone>-pods, from classic node pools - <zone>, <zone>spot, <zone>arm, <zone>armspot,
# from zero nodes in availability zone 3 - scaled by the cluster autoscaler, whose priority expander takes
# the spot pools first (aks-fluxcd-platform, clusters/dev-int-stateless-az3). Sized for the lab's quotas in
# germanywestcentral: Daldv6 8 vCPUs (the system node takes 4, so two 2-vCPU amd64 nodes in all - one per
# zone), low-priority (spot) 3 vCPUs (one spot node; the other zone's spot pod falls back to on-demand).
# Each gateway reads its listener certificate from the platform vault (<zone>-gateway--wildcard);
# flux-system the observability chart's credentials. The application namespaces' shares are in their
# zone's vault; the zones' names are in shared/'s private DNS zones.
zone_node_pools = {
  max_count      = 1
  spot_max_count = 1
}
isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes", pod_subnet_name = "snet-int-fi-pods" }
  int-se = { node_subnet_name = "snet-int-se-nodes", pod_subnet_name = "snet-int-se-pods" }
}
key_vault_namespaces = ["flux-system", "int-fi-gateway", "int-se-gateway"]
key_vault_namespace_vaults = {
  int-fi-example = "kv-onek8s-gwc-int-fi"
  int-se-example = "kv-onek8s-gwc-int-se"
}
internal_dns_zone_names = ["int-fi.dev.onek8s.lol", "int-se.dev.onek8s.lol"]

# The `example` team's application, once per zone (design section 2.6: one namespace per application
# and zone, `<zone>-<app>`). Each namespace's own Flux configuration deploys onek8s/aks-fluxcd-example
# into it - aks-hello on the zone's own nodes, with its weather forecast from the internet - and its
# routes attach to the zone's gateway: firewall-egress/ into int-se-example, firewall-egress-int-fi/
# (the same with Helsinki's forecast) into int-fi-example. Ingress and egress inside the cluster are
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
  int-fi-example = {
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-fi"
    }
    # The lab groups of shared/'s key_vault_namespaces.int-fi-example (design D49): view, edit and admin
    # in the namespace, and the same roles on the namespace's share of the zone's vault.
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
      url                   = "https://github.com/onek8s/aks-fluxcd-example"
      path                  = "./firewall-egress-int-fi"
      sync_interval_seconds = 60
      substitute = {
        zone        = "int-fi"
        zone_domain = "int-fi.dev.onek8s.lol"
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
