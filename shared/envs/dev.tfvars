# The dev environment's shared resources: what its clusters - aks-dev-stateful
# (envs/dev-stateful.tfvars), aks-dev-stateless-az1 and aks-dev-stateless-az2
# (envs/dev-stateless-az<N>.tfvars) - all use, in a state of its own. Applied first - the clusters
# look all of this up by name.
#
#   cd shared
#   terraform apply -var-file=envs/dev.tfvars
#
# The subscription is sub-aks-dev of the OneK8s build tenant, which onek8s/azure-landing-zone
# places in the `corp` landing zone. Everything below starts from an empty subscription: the resource
# group and the network are created here too.

environment = "dev"
location    = "swedencentral"

resource_group_name   = "rg-aks-dev"
resource_group_create = true

# The stateful cluster's network (envs/dev-stateful.tfvars, defined but not deployed). Azure CNI
# overlay: only the nodes take addresses from the subnet.
virtual_network_name          = "vnet-aks-dev"
virtual_network_create        = true
virtual_network_address_space = ["172.20.0.0/22"]
subnets = {
  snet-aks-nodes = "172.20.0.0/23"
}

# The isolation zones (OneK8s design, "Isolation zone"): internal and external workloads of Finland
# and Sweden. Each has its own address range in every cell, its own node subnet and NAP NodePools, its
# own Key Vault, gateway and External Secrets Operator. `index` is the zone's /24 in each cell's
# address space and never changes.
isolation_zones = {
  int-fi = { exposure = "int", index = 1 }
  int-se = { exposure = "int", index = 2 }
  ext-fi = { exposure = "ext", index = 3 }
  ext-se = { exposure = "ext", index = 4 }
}

# The stateless cells' networks, one per cluster - see cells.tf for the layout: snet-system, and per
# zone snet-<zone>-nodes and snet-<zone>-ilb, each with its own NSG; VNet encryption on.
cells = {
  dev-stateless-az1 = { address_space = "172.21.0.0/20" }
  dev-stateless-az2 = { address_space = "172.21.16.0/20" }
}

# The internal zones' names resolve only inside the cells.
internal_dns_zones = ["int-fi.dev.onek8s.lol", "int-se.dev.onek8s.lol"]

# The environment's platform Key Vault (OneK8s design sections 13 and 18), which the clusters name
# in key_vault_name with key_vault_create = false: the gateways' certificates, the clusters'
# customer-managed keys (so purge protection - a disk encryption set needs it) and the Flux webhook
# token. Key Vault names are global; pick another if this one is taken.
key_vault_name                     = "kv-onek8s-dev-platform"
key_vault_purge_protection_enabled = true

# One vault per isolation zone, for the secrets of the zone's applications (design section 6).
zone_key_vault_names = {
  int-fi = "kv-onek8s-dev-int-fi"
  int-se = "kv-onek8s-dev-int-se"
  ext-fi = "kv-onek8s-dev-ext-fi"
  ext-se = "kv-onek8s-dev-ext-se"
}

# The environment's Log Analytics workspace (design section 19): every cluster's Kubernetes audit log
# (CIS AKS Benchmark 2.1.1), 30 days, at most 1 GB a day.
log_analytics_workspace_name = "log-dev-platform"

# The environment's container registry, which every cluster pulls from as its kubelet identity. Not
# part of the landing zone. Registry names are global; pick another if this one is taken.
container_registry_name = "acronek8sdev"

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
}

# Every image the registry builds is signed with this certificate in the platform vault (the Sign
# images workflow), and the clusters' AKS Image Integrity audits the signatures at admission.
image_signing = {
  subject = "CN=OneK8s dev image signing, O=OneK8s, ST=Uusimaa, C=FI"
}

# Every namespace with a share of a vault in any of the clusters. In the platform vault: flux-system
# (the Flux webhook's token), platform-gateway and each zone's `<zone>-gateway` (their listener
# certificates, `<namespace>--wildcard`). In a zone's vault: every application namespace of the zone -
# `<zone>-<app>`, a managed namespace of the clusters. A cluster's plan fails on a namespace missing
# here, since its identity is not there to look up.
key_vault_namespaces = {
  flux-system      = {}
  platform-gateway = {}
  int-fi-gateway   = {}
  int-se-gateway   = {}
  ext-fi-gateway   = {}
  ext-se-gateway   = {}
  ext-fi-example   = { zone = "ext-fi" }
}

# The token every cluster's Flux webhook receiver checks GitHub's deliveries against.
flux_github_webhook = true
# ... and the `example` team's Receiver, for its own repository (aks-fluxcd-platform,
# tenants/ext-fi-example/webhook.yaml), in the team's share of the ext-fi vault.
flux_github_webhook_namespaces = ["ext-fi-example"]

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

# hello.ext-fi.dev.onek8s.lol, served by the ext-fi zone of every stateless cell at once: Azure Traffic
# Manager (design section 8) hands out one cell or the other and leaves out a cell whose probe fails;
# the page says which one answered. Each endpoint is the app's own hostname in a cell, an A record of
# that cell's ext-fi gateway, published by the cell's external-dns.
global_hostnames = {
  "hello.ext-fi.dev" = {
    endpoints = [
      "hello-aks-dev-stateless-az1.ext-fi.dev.onek8s.lol",
      "hello-aks-dev-stateless-az2.ext-fi.dev.onek8s.lol",
    ]
    health_path = "/healthz"
  }
}
