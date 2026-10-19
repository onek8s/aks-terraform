# Internal cell `int-stateless-az1` of the OneK8s dev environment (design section 3.1): availability
# zone 1, Finland's zone, an overlay cell with ACNS like the design's default before D61. DISABLED in the
# lab (shared/envs/dev.tfvars, cells.dev-int-stateless-az1.enabled = false): germanywestcentral's logical
# zone 1 is "NotAvailableForSubscription" for every VM size in sub-aks-dev; az2 runs instead. Enable it in
# shared/ before deploying it. envs/dev-int-stateless.tfvars holds what every cell shares and is applied
# with this file:
#
#   terraform workspace select -or-create dev-int-stateless-az1
#   terraform apply -var-file=envs/dev-int-stateless.tfvars -var-file=envs/dev-int-stateless-az1.tfvars

name                 = "aks-dev-int-stateless-az1"
virtual_network_name = "vnet-dev-int-stateless-az1"

# The system pool: ONE amd64 node in availability zone 1, Standard_D4alds_v6 - see az2's file.
default_node_pool = {
  vm_size             = "Standard_D4alds_v6"
  os_disk_type        = "Ephemeral"
  availability_zones  = ["1"]
  enable_auto_scaling = false
  node_count          = 1
  os_sku              = "AzureLinux"
  encryption_at_host  = true
  ssh_access          = "Disabled"
  node_taints         = ["CriticalAddonsOnly=true:NoSchedule"]
}

# ACNS without container network observability (Hubble), design D56: FQDN network policies and eBPF
# host routing stay on. Production: advanced_networking = {} (all on, the default).
advanced_networking = {
  observability = false
}

# Azure CNI Overlay, egress through the hub firewall (shared/: hub). Cannot change on a running cluster.
network_profile = {
  outbound_type = "userDefinedRouting"
}

# Finland's zone, its nodes from node auto provisioning - see az2's file.
node_auto_provisioning_enabled = true
isolation_zones = {
  int-fi = { node_subnet_name = "snet-int-fi-nodes" }
}
key_vault_namespaces = ["flux-system", "int-fi-gateway"]
key_vault_namespace_vaults = {
  int-fi-example = "kv-onek8s-gwc-int-fi"
}
internal_dns_zone_names = ["int-fi.dev.onek8s.lol"]

# The `example` team's application in the int-fi zone - see az2's file. home_cell stays az2: one home
# cell per internal application (design section 3.1), the same in every cell.
managed_namespaces = {
  int-fi-example = {
    owner = {
      team        = "example"
      cost_center = "example"
      contact     = "https://github.com/onek8s/aks-fluxcd-example/issues"
    }
    labels = {
      "platform/zone" = "int-fi"
    }
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
        home_cell   = "aks-dev-int-stateless-az2"
      }
    }
  }
}

flux_git_repository = {
  url                   = "https://github.com/onek8s/aks-fluxcd-platform"
  branch                = "main"
  path                  = "./clusters/dev-int-stateless-az1"
  sync_interval_seconds = 60
}
