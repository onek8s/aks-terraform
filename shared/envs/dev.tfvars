# The dev environment's shared resources of the internal exposure (OneK8s design decision D52:
# internal and external workloads have a subscription and clusters each): what its clusters -
# aks-dev-int-stateless-az3 (envs/dev-int-stateless-az3.tfvars) and aks-dev-int-stateful
# (envs/dev-int-stateful.tfvars) - all use, in a state of its own. Applied first - the clusters
# look all of this up by name.
#
#   cd shared
#   terraform apply -var-file=envs/dev.tfvars
#
# The subscription is sub-aks-dev of the OneK8s build tenant, which onek8s/azure-landing-zone
# places in the `corp` landing zone; it plays sub-aks-dev-int since 2026-10-15 (before, sub-aks-dev-ext
# in swedencentral). The lab has no external subscription now: that would be this configuration
# applied once more, with exposure = "ext" and the external zones, in sub-aks-dev-ext. Everything
# below starts from an empty subscription: the resource group and the network are created here too.

environment = "dev"
exposure    = "int"
location    = "germanywestcentral"

# Names come from the naming policy (variable `naming`, modules/conventions): its defaults are the lab's
# names - rg-aks-dev, kv-onek8s-gwc-platform and kv-onek8s-gwc-<zone>, acronek8sdev, log-dev-platform,
# ais-onek8s-dev-agents, vnet-/nsg-/rt-<cell>, id-gwc-dev-shared-* - so nothing here names them. A real
# estate passes its own policy from outside the repository (README, "Naming policy"); a variable that
# names a resource itself still wins.
resource_group_create = true

# The stateful cluster's network (envs/dev-int-stateful.tfvars, defined but not deployed): its nodes'
# subnet and its pods' (Azure CNI Pod Subnet, delegated to AKS).
virtual_network_name          = "vnet-aks-dev"
virtual_network_create        = true
virtual_network_address_space = ["172.20.0.0/22"]
subnets = {
  snet-aks-nodes = "172.20.0.0/23"
  snet-aks-pods  = "172.20.3.0/24"
}

# The environment's services on private endpoints in that network (snet-shared-pe, design section 3.1):
# the platform vault and the zone vaults (Standard - a vault's endpoint needs no higher tier), the
# agents' Foundry resource and the Terraform state account, registered in the hub's private link
# zones - not the registry: Basic in dev, public (design D62, below). The cells and the labfw VPN's
# clients - the GitHub-hosted runners too (.github/actions/labfw-vpn) - resolve them to these addresses
# through labfw's DNS proxy. public_network_access = false: none of them, nor the Log Analytics
# workspace (the landing zone's Azure Monitor Private Link scope), answers on a public endpoint (the
# user's ask, 2026-10-15).
private_endpoints = {
  address_prefix             = "172.20.2.0/26"
  dns_zone_resource_group_id = "/subscriptions/56b07081-ca7e-4343-b000-bc0998a8c347/resourceGroups/rg-hub-dns-germanywestcentral"
  state_storage_account_id   = "/subscriptions/3b9f032a-0165-4b8c-9e1e-d7a664c661a8/resourceGroups/rg-aks-dev-tfstate/providers/Microsoft.Storage/storageAccounts/stonek8sdevtfstate"
  public_network_access      = false
}

# The isolation zones (OneK8s design, "Isolation zone") of the internal exposure: the internal
# workloads of Finland and Sweden. The external ones (ext-fi index 3, ext-se index 4) belong to the
# external subscription and its clusters; their indexes stay reserved. Each has its own address
# range in every cell, its own node and pod subnets and node pools, its own Key Vault, gateway and External
# Secrets Operator. `index` is the zone's slot in each cell's address spaces and never changes.
#
# The lab's one cell, az3, runs Sweden only: every cell gets both zones' subnets, but only az3's tfvars and
# the fleet's zones.yaml name int-se. Finland keeps its vault, private DNS and subnets for the stateful
# cluster and a later cell. `enabled = false` would take a zone's subnets, vault and private DNS away.
isolation_zones = {
  int-fi = { exposure = "int", index = 1 }
  int-se = { exposure = "int", index = 2 }
}

# The stateless cells' networks, one per cluster - see cells.tf for the layout: snet-system(-pods), and per
# zone snet-<zone>-nodes, snet-<zone>-pods and snet-<zone>-ilb, each with its own NSG; VNet encryption on.
# The design's cells, one per availability zone; the lab runs one, az3 (germanywestcentral's zone 1 is
# "NotAvailableForSubscription" for every VM size in sub-aks-dev). Azure CNI Pod Subnet with dynamic IP
# allocation: its pods take addresses of their pool's pod subnet in 100.64.0.0/16 (RFC 6598 shared address space, never routed outside the landing zone), keep them up to labfw,
# and labfw - not Cilium - decides every flow that leaves the cluster, by zone and by the pod's address. Cilium
# keeps the policies inside the cluster. Nodes and load balancers have /24 slots of 10.100.0.0/16 like any cell:
# snet-system 10.100.0.0/24, int-fi 10.100.1.0/24, int-se 10.100.2.0/24 (nodes the /25, ILB 10.100.<n>.128/27);
# pods: snet-system-pods 100.64.0.0/20, snet-int-fi-pods 100.64.16.0/20, snet-int-se-pods 100.64.32.0/20.
cells = {
  dev-int-stateless-az3 = { address_space = "10.100.0.0/16", pod_address_space = "100.64.0.0/16" }
}

# The landing zone's hub (azure-landing-zone network mode labfw): every cell is peered with it, sends
# 0.0.0.0/0 to labfw at 10.0.1.4 - the stand-in for the hub's Azure Firewall, enforcing the internal
# exposure's Firewall Policy - and uses labfw's DNS proxy. The internal zones' private DNS is linked
# to the hub too. The cells' clusters egress through it (outbound type userDefinedRouting).
hub = {
  virtual_network_id = "/subscriptions/56b07081-ca7e-4343-b000-bc0998a8c347/resourceGroups/rg-hub-germanywestcentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-germanywestcentral"
  next_hop_ip        = "10.0.1.4"
  dns_servers        = ["10.0.1.4"]
}

# The internal zones' names (int-fi.dev.onek8s.lol), resolved in the cells and - through labfw's DNS
# proxy - in the corporate network behind the hub.
internal_dns_zones = ["int-fi.dev.onek8s.lol", "int-se.dev.onek8s.lol"]

# The environment's platform Key Vault (OneK8s design sections 4.1 and 4.2), kv-onek8s-gwc-platform by
# the naming policy, which the clusters name in key_vault_name: the
# gateways' certificates and the clusters' customer-managed keys (so purge protection - a disk encryption
# set needs it). Key Vault names are global; name it in key_vault_name if
# this one is taken. kv-onek8s-gwc-* since the move to germanywestcentral: kv-onek8s-dev-platform is
# soft-deleted with purge protection in swedencentral (until 2027-01) and cannot be recovered into
# another region.
key_vault_purge_protection_enabled = true

# One vault per enabled isolation zone, for the secrets of the zone's applications (design section
# 2.5): kv-onek8s-gwc-int-fi and kv-onek8s-gwc-int-se by the naming policy (zone_key_vault_names would
# name one otherwise).

# The environment's Log Analytics workspace (design section 6.2), log-dev-platform by the naming policy:
# every cluster's Kubernetes audit log (CIS AKS Benchmark 2.1.1), 30 days, at most 1 GB a day.
log_analytics_workspace_create = true

# The environment's container registry, acronek8sdev by the naming policy, which every cluster pulls from
# as its kubelet identity. Not part of the landing zone. Registry names are global; name it in
# container_registry_name if this one is taken.
container_registry_create = true
# Basic, on its public endpoint with Entra ID only (the default below prd, design D62, 2026-10-16): a
# private endpoint needs Premium, about 1.7 USD a day against Basic's 0.2 - prd's registry alone is
# Premium and private. The hub firewall lets the cells reach the public endpoint and its storage
# (azure-landing-zone `container_registry` of the exposure).

# The images the registry builds itself, from the apps' public repositories at a pinned commit.
# Releasing an image is adding its tag here.
container_registry_builds = {
  "aks-hello:0.2.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "901b314408bb7aad2633e2f16798e17af57b3fd9"
  }
  # For the clusters' Arm64 nodes
  "aks-hello:0.2.1" = {
    repository   = "https://github.com/onek8s/aks-hello.git"
    commit       = "9eed390f777935b919e4fcf90c6eb0a0e9ef14e7"
    dockerfile   = "Dockerfile.arm64" # cross-compiles on the registry's amd64 host
    architecture = "arm64"
  }
  # /status, /health/live and /health/ready
  "aks-hello:0.3.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "260b0ca972b5d1949d7fde4b86c077dd98b50258"
  }
  # A weather forecast from the internet (/weather): the lab cell's example of an
  # application's own outbound dependency (design section 5.2)
  "aks-hello:0.4.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "63594f30e4a0b770aef7e797ce819300c4be3420"
  }
  # The forecast refreshed in the background, so the dependency shows without visitors
  "aks-hello:0.4.1" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "86e8752ea3e903be07d49246e3ed021846df263b"
  }
  # The node's public IP (/public-ip, api.ipify.org once at start): which address the platform's egress
  # gave the pod, and a second outbound dependency for the firewall-egress cell
  "aks-hello:0.5.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "553980c84d1eeeed34060eff76f9b8b2c539a2ed"
  }
  # Reports the request's protocol in /status (`protocol`): HTTP/2 from the gateway over h2c (design D69, V28)
  "aks-hello:0.5.1" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "b3b282ca272b3554fc39c90479bc76d9bc688543"
  }
  # h2c on its own port 8081, HTTP/1.1 on 8080 for the kubelet's probes: 0.5.1's one port spoke HTTP/1.1 only
  # (Kestrel's default on a port without TLS), so Traefik's h2c to it answered 500 on every route
  "aks-hello:0.5.2" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "b9ad11f879cf97186359fa8b97f2752e6efd9228"
  }
  # The Ubuntu ASP.NET Core runtime image with a shell for debugging (kubectl exec)
  "aks-hello:0.6.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "7f0316f4528348555a2e817893740ea980ab1a33"
  }
  # Network tools in the image (0.7.0) and the peers (0.8.0, /peers): the same application in the cell's other
  # zone polled by its Service name and its published name, so the isolation between zones shows on the page
  # and in labfw's log (design D73)
  "aks-hello:0.8.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "a74539a019122b97ab4e4900900190d97f2907c1"
  }
}

# Every image the registry builds is signed with this certificate in the platform vault (the Sign
# images workflow), and the clusters' AKS Image Integrity audits the signatures at admission.
image_signing = {
  subject = "CN=OneK8s dev image signing, O=OneK8s, ST=Uusimaa, C=FI"
}

# Every namespace with a share of a vault in any of the clusters. In the platform vault: flux-system
# (the Grafana Cloud credentials of the observability chart) and each zone's `<zone>-gateway` (its
# listener certificate, `<namespace>--wildcard`). In a zone's vault: every application namespace of
# the zone - `<zone>-<app>`, a managed namespace of the clusters. A cluster's plan fails on a namespace
# missing here, since its identity is not there to look up. An internal cell has no platform gateway:
# it has no public entry point (behind labfw a public load balancer cannot answer).
key_vault_namespaces = {
  flux-system    = {}
  int-fi-gateway = {}
  int-se-gateway = {}
  # Its groups get on its secrets what their Kubernetes role gets on Secrets (design section 2.5, D49):
  # the same object IDs as managed_namespaces.int-fi-example.groups in the cells' tfvars - the lab
  # groups created for ext-fi-example (grp-onek8s-dev-ext-fi-example-<role>), reused.
  int-fi-example = {
    zone = "int-fi"
    groups = {
      view  = "6d9ae939-5e03-4ddb-b378-baa7fa5b5180"
      edit  = "88ba3f87-2d13-46ea-8cff-eeccf6cbd0bc"
      admin = "71438fbc-0666-4d82-be17-54b61236d657"
    }
  }
  # The example team in Sweden's zone, on the lab's cell az3: no groups yet.
  int-se-example = {
    zone = "int-se"
  }
}

# The platform viewers (design section 2.6, soft multi-tenancy): list the namespaces of the cells and the
# secrets of the vaults - names only - through a custom role at rg-aks-dev, so the Azure portal's
# Kubernetes views can offer a namespace to pick. Lab group grp-onek8s-dev-platform-viewers, with a
# tester application the isolation tests sign in as.
platform_viewer_group_object_ids = ["75353964-033e-4ea2-8ec4-f44e89fee6a6"]

# No Flux webhook token: an internal cell has no public entry point for GitHub's deliveries, so Flux
# polls (every minute). An environment with external cells turns it on for their platform gateways.
flux_github_webhook = false

# The Isolation tests read this namespace's fixture secret as its own identity (R7)
isolation_test_namespaces = ["int-se-example"]

# The one zone the environment publishes in, public or private - the clusters say the same in their
# own dns_zone_private. Public here, so every hostname resolves on the internet: onek8s.lol exists
# already - created once with the Azure CLI in rg-onek8s-dns, outside every state, and delegated at the
# registrar (azure-landing-zone, docs/deployment.md, step 3b). For a private zone instead, set
# dns_zone_private = true and dns_zone_create = true and drop dns_zone_resource_group_name: it is created
# here, in rg-aks-dev, and linked to vnet-aks-dev.
dns_zone_name                = "onek8s.lol"
dns_zone_private             = false
dns_zone_create              = false
dns_zone_resource_group_name = "rg-onek8s-dns"

# The environment's monthly budget (budget.tf): the Owners of sub-aks-dev are told at 80 % and 100 %
# of actual cost and at a forecast of 100 %. The lab's steady cost - one cell's system node, its
# internal load balancer, the vaults, the registry, the workspace - is well below it; a GPU
# node (about 7 per hour) or a second cell left running is what it catches.
monthly_budget = {
  amount     = 600
  start_date = "2026-10-01T00:00:00Z"
}

# The AI agents' model (onek8s/aks-ai-agents, model.provider foundry; design section 6.1): Claude Sonnet 5.5 on
# Microsoft Foundry in swedencentral - germanywestcentral does not offer Anthropic's models - Entra ID only. First
# user: the egress agent (design section 5.2), which proposes the firewall rules of the applications from labfw's denials.
# The deployment signs Anthropic's Azure Marketplace offer in OneK8s's name, billed to sub-aks-dev; the organisation,
# country and industry go to Anthropic with every request (the user's choice, 2026-10-15).
# Not deployed yet: sub-aks-dev has 0 Foundry quota (Tokens Per Minute) for every Claude model in swedencentral
# (InsufficientQuota, 2026-10-15) - a quota request in the Azure portal (Foundry > Quotas) first, then deploy = true.
# ais-onek8s-dev-agents by the naming policy (also its custom subdomain, so global).
ai_foundry = {
  location = "swedencentral"
  deploy   = false
  # The agents' model meanwhile (the user's choice, 2026-10-15): created in the portal, imported here
  openai_deployments = {
    "gpt-4.1-mini" = { version = "2025-04-14", capacity = 100, import = true }
  }
  model_provider = {
    organization_name = "OneK8s"
    country_code      = "FI"
    industry          = "technology"
  }
}
