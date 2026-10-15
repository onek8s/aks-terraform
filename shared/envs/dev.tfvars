# The dev environment's shared resources of the internal exposure (OneK8s design decision D52:
# internal and external workloads have a subscription and clusters each): what its clusters -
# aks-dev-int-stateful (envs/dev-int-stateful.tfvars) and aks-dev-int-stateless-az1
# (envs/dev-int-stateless-az1.tfvars) - all use, in a state of its own. Applied first - the clusters
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

resource_group_name   = "rg-aks-dev"
resource_group_create = true

# The stateful cluster's network (envs/dev-int-stateful.tfvars, defined but not deployed). Azure CNI
# overlay: only the nodes take addresses from the subnet.
virtual_network_name          = "vnet-aks-dev"
virtual_network_create        = true
virtual_network_address_space = ["172.20.0.0/22"]
subnets = {
  snet-aks-nodes = "172.20.0.0/23"
}

# The environment's services on private endpoints in that network (snet-shared-pe, design section 8):
# the platform vault and the zone vaults (Standard - a vault's endpoint needs no higher tier), the
# registry (Premium, the only tier with private endpoints), the agents' Foundry resource and the
# Terraform state account, registered in the hub's private link zones. The cells and the labfw VPN's
# clients - the GitHub-hosted runners too (.github/actions/labfw-vpn) - resolve them to these addresses
# through labfw's DNS proxy. public_network_access = false: none of them, nor the Log Analytics
# workspace (the landing zone's Azure Monitor Private Link scope), answers on a public endpoint (the
# user's ask, 2026-10-15).
private_endpoints = {
  address_prefix             = "172.20.2.0/26"
  dns_zone_resource_group_id = "/subscriptions/56b07081-ca7e-4343-b000-bc0998a8c347/resourceGroups/rg-hub-dns-germanywestcentral"
  state_storage_account_id   = "/subscriptions/3b9f032a-0165-4b8c-9e1e-d7a664c661a8/resourceGroups/rg-aks-dev-tfstate/providers/Microsoft.Storage/storageAccounts/stonek8sdevtfstate"
  public_network_access      = true
}

# The environment's Log Analytics workspace (design section 19): every cluster's Kubernetes audit log
# (CIS AKS Benchmark 2.1.1), 30 days, at most 1 GB a day.
log_analytics_workspace_name = "log-dev-platform"

# The environment's container registry, which every cluster pulls from as its kubelet identity. Not
# part of the landing zone. Registry names are global; pick another if this one is taken.
container_registry_name = "acronek8sdev"
# Premium: a private endpoint and no public network access (about 1.7 USD a day against Basic's 0.2)
container_registry_sku = "Premium"

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
  # A weather forecast from the internet (/weather): the firewall-egress cell's example of an
  # application's own outbound dependency (design D59)
  "aks-hello:0.4.0" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "63594f30e4a0b770aef7e797ce819300c4be3420"
  }
  # The forecast refreshed in the background, so the dependency shows without visitors
  "aks-hello:0.4.1" = {
    repository = "https://github.com/onek8s/aks-hello.git"
    commit     = "86e8752ea3e903be07d49246e3ed021846df263b"
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
  # Its groups get on its secrets what their Kubernetes role gets on Secrets (design section 6, D49):
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
  # The example team in Sweden's zone, on the firewall-egress cell az3 (design D59): no groups yet.
  int-se-example = {
    zone = "int-se"
  }
}

# The platform viewers (design section 7, soft multi-tenancy): list the namespaces of the cells and the
# secrets of the vaults - names only - through a custom role at rg-aks-dev, so the Azure portal's
# Kubernetes views can offer a namespace to pick. Lab group grp-onek8s-dev-platform-viewers, with a
# tester application the isolation tests sign in as.
platform_viewer_group_object_ids = ["75353964-033e-4ea2-8ec4-f44e89fee6a6"]

# No Flux webhook token: an internal cell has no public entry point for GitHub's deliveries, so Flux
# polls (every minute).
flux_github_webhook = false

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

# hello.ext-fi.dev.onek8s.lol would be served by the ext-fi zone of every external cell at once through
# Azure Traffic Manager (design section 8). Kept for an external subscription; no profile is created
# here, because ext-fi is not a zone of this (internal) environment - see global_hostnames.
global_hostnames = {
  "hello.ext-fi.dev" = {
    zone = "ext-fi"
    endpoints = [
      "hello-aks-dev-ext-stateless-az1.ext-fi.dev.onek8s.lol",
      "hello-aks-dev-ext-stateless-az2.ext-fi.dev.onek8s.lol",
    ]
    health_path = "/healthz"
  }
}

# The environment's monthly budget (budget.tf): the Owners of sub-aks-dev are told at 80 % and 100 %
# of actual cost and at a forecast of 100 %. The lab's steady cost - one cell's system node, its
# internal load balancer, the vaults, the registry, the workspace - is well below it; a GPU
# node (about 7 per hour) or a second cell left running is what it catches.
monthly_budget = {
  amount     = 600
  start_date = "2026-10-01T00:00:00Z"
}

# The AI agents' model (onek8s/aks-ai-agents, model.provider foundry; design section 15): Claude Sonnet 5.5 on
# Microsoft Foundry in swedencentral - germanywestcentral does not offer Anthropic's models - Entra ID only. First
# user: the egress agent (design D59), which proposes the firewall rules of the applications from labfw's denials.
# The deployment signs Anthropic's Azure Marketplace offer in OneK8s's name, billed to sub-aks-dev; the organisation,
# country and industry go to Anthropic with every request (the user's choice, 2026-10-15).
# Not deployed yet: sub-aks-dev has 0 Foundry quota (Tokens Per Minute) for every Claude model in swedencentral
# (InsufficientQuota, 2026-10-15) - a quota request in the Azure portal (Foundry > Quotas) first, then deploy = true.
ai_foundry = {
  name     = "ais-onek8s-dev-agents"
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
