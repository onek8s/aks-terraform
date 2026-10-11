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

# The clusters' network. Azure CNI overlay: only the nodes take addresses from the subnet, so every
# cluster of the environment shares it, and the pod range is each cluster's own.
virtual_network_name          = "vnet-aks-dev"
virtual_network_create        = true
virtual_network_address_space = ["172.20.0.0/22"]
subnets = {
  snet-aks-nodes = "172.20.0.0/23"
}

# The environment's Key Vault, which the clusters name in key_vault_name with key_vault_create =
# false. Key Vault names are global; pick another if this one is taken.
key_vault_name = "kv-onek8s-dev-shared"

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
}

# Every namespace with a share of the vault in any of the clusters: the platform's ingress-gateway
# (listener certificates), flux-system (the Flux webhook's token) and every managed namespace of the
# clusters. A cluster's plan fails on a namespace missing here, since its identity is not there to
# look up.
key_vault_namespaces = {
  ingress-gateway = {}
  flux-system     = {}
  example         = {}
}

# The token every cluster's Flux webhook receiver checks GitHub's deliveries against.
flux_github_webhook = true

# The public zone exists already: created once with the Azure CLI in rg-onek8s-dns, outside every
# state, and delegated at the registrar (azure-landing-zone, docs/deployment.md, step 3b). The private
# zone is created here and linked to the clusters' network.
dns_zone_name                = "onek8s.lol"
dns_zone_create              = false
dns_zone_resource_group_name = "rg-onek8s-dns"
internal_dns_zone_name       = "internal.onek8s.lol"

# hello.onek8s.lol, served by every stateless cluster at once: DNS hands out one cluster or the other,
# and the page says which one answered. Each endpoint is a cluster's public address, published by its
# own external-dns (aks-fluxcd-platform, clusters/<cluster>/cluster-settings.yaml: public_hostname).
global_hostnames = {
  hello = {
    endpoints = [
      "public-dev-stateless-az1.onek8s.lol",
      "public-dev-stateless-az2.onek8s.lol",
    ]
    health_path = "/healthz"
  }
}
