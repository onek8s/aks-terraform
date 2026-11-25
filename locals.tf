locals {
  # API version of the AKS resource provider used by the resources written directly rather than
  # through the module. One place to bump, so that the two cannot drift apart.
  aks_api_version = "2026-05-02-preview"

  # API version of the Kubernetes Configuration resource provider, which owns cluster extensions.
  kubernetes_configuration_api_version = "2024-11-01"

  # How long to wait after creating the role assignments before creating the cluster: Azure RBAC is
  # eventually consistent, and a cluster created the moment the assignment returns is regularly refused
  # the subnet it is supposed to join.
  role_assignment_propagation_delay = "60s"

  # Flux is installed only for a cluster that names a repository for it to sync. The tenants'
  # configurations (tenants/) run on the same extension.
  flux_enabled           = var.flux_git_repository != null
  flux_extension_enabled = local.flux_enabled

  # What the cluster's Flux repository is told about the Azure side of the cluster, as post-build
  # variables of the `platform` Kustomization: the facts it cannot know on its own and should not
  # have copied into it by hand. clusters/<cluster>/ in the repository passes them on to whatever
  # needs them. A value the cluster does not have is left out rather than sent empty.
  #
  # Which variables there are follows from the inputs alone, never from the values: the client IDs
  # are unknown until the identities exist, and a key that hangs on one would leave the whole set
  # unknown at plan time.
  flux_cluster_settings = merge(
    {
      cluster_name    = var.name
      azure_tenant_id = data.azurerm_client_config.current.tenant_id
      # A double quote, for values that look like booleans or numbers: kustomize drops the quotes
      # around "${var}", so a field that must be a string is written ${quote}${var}${quote} (Flux,
      # "Post build substitution of numbers and booleans").
      quote = "\""
    },
    # The environment's platform vault, and for each namespace with a share of a vault the identity
    # that reads that share: `key_vault_client_id_<namespace>`, the namespace's hyphens as
    # underscores, since a Flux variable name has no hyphens.
    local.key_vault_enabled ? { key_vault_url = local.key_vault_uri } : {},
    {
      for namespace in local.key_vault_namespaces :
      "key_vault_client_id_${replace(namespace, "-", "_")}" => data.azurerm_user_assigned_identity.key_vault[namespace].client_id
    },
    # The DNS zones the listener hostnames are published in, and the identity that writes them.
    local.external_dns_enabled ? {
      dns_zone_name                = var.dns_zone_name
      dns_zone_resource_group_name = local.dns_zone_resource_group_name
      dns_zone_subscription_id     = split("/", local.dns_zone_id)[2]
      # Whether the zone is public or private, and the external-dns provider that writes it.
      dns_zone_private       = tostring(var.dns_zone_private)
      dns_provider           = var.dns_zone_private ? "azure-private-dns" : "azure"
      dns_identity_client_id = azurerm_user_assigned_identity.external_dns[0].client_id
    } : {},
    # Where the disks of the `portable-disk` StorageClass go, so that they outlive the cluster - see
    # portable_disks_enabled.
    var.portable_disks_enabled ? { portable_disk_resource_group_name = var.resource_group_name } : {},
    # The image signature verifier's identity, the signing certificate in the platform vault and the
    # registry the signatures are in - see image_integrity.tf.
    var.image_integrity_enabled ? {
      image_verification_client_id    = data.azurerm_user_assigned_identity.image_verification[0].client_id
      image_signing_certificate_name  = module.conventions.image_signing_certificate_name
      image_signing_subject           = one(one(data.azurerm_key_vault_certificate.image_signing[0].certificate_policy).x509_certificate_properties).subject
      container_registry_login_server = data.azurerm_container_registry.this[0].login_server
    } : {},
    # Each isolation zone's node subnet, each namespace's vault and the internal zones' DNS - see
    # zones.tf.
    local.flux_zone_settings,
    # The GatewayClass each Gateway names - see traefik.tf.
    local.flux_gateway_settings,
  )

  # The Flux configuration as sent to Azure. A local, because the namespace access configurations
  # below are made from it.
  flux_configuration_body = {
    properties = {
      gitRepository = {
        repositoryRef = {
          branch = try(var.flux_git_repository.branch, null)
        }
        syncIntervalInSeconds = try(var.flux_git_repository.sync_interval_seconds, null)
        url                   = try(var.flux_git_repository.url, null)
      }
      kustomizations = {
        platform = {
          path                  = try(var.flux_git_repository.path, null)
          prune                 = true
          syncIntervalInSeconds = try(var.flux_git_repository.sync_interval_seconds, null)
          # A failed run is retried as often as the repository is read, not after a quarter of an hour.
          retryIntervalInSeconds = try(var.flux_git_repository.sync_interval_seconds, null)
          # No health checks: `platform` applies the Kustomizations of clusters/<cluster>/ and is done,
          # and each of those waits for its own objects. Waiting here as well kept every new commit
          # queued behind whichever of them was unhealthy, for up to the full timeout.
          wait = false
          postBuild = {
            substitute = local.flux_cluster_settings
          }
        }
      }
      namespace  = "flux-system"
      scope      = "cluster"
      sourceKind = "GitRepository"
    }
  }

  # The Kubernetes service accounts the workload identities are federated with. They are created by
  # the Flux repository, which has to use exactly these names and namespaces: a federated credential
  # trusts one subject and nothing else. Every namespace with a share of the Key Vault reads it as a
  # service account of this name.
  key_vault_service_account    = "key-vault"
  external_dns_service_account = "system:serviceaccount:external-dns:external-dns"

  # The DNS zone, public or private. Null when no zone is named.
  dns_zone_resource_group_name = coalesce(var.dns_zone_resource_group_name, var.resource_group_name)
  dns_zone_id                  = one(concat(data.azurerm_dns_zone.this[*].id, data.azurerm_private_dns_zone.zone[*].id))

  # external-dns, and the identity it writes as, are there for the zone.
  external_dns_enabled = var.dns_zone_name != null

  # The environment's platform vault, created by shared/ and looked up for a cluster that names it -
  # see key_vault.tf.
  key_vault_enabled = var.key_vault_name != null
  key_vault_id      = one(data.azurerm_key_vault.this[*].id)
  key_vault_uri     = one(data.azurerm_key_vault.this[*].vault_uri)

  # The platform's namespaces with a share of the vault: those key_vault_namespaces names, and
  # flux-system for the webhook's token. None without a vault. The tenants' are tenants/'.
  key_vault_namespaces = local.key_vault_enabled ? toset(concat(tolist(var.key_vault_namespaces), local.flux_github_webhook_enabled ? ["flux-system"] : [])) : toset([])

  # The Flux GitHub webhook's token is in the vault, for the Receiver in flux-system to read.
  flux_github_webhook_enabled = var.flux_github_webhook && local.flux_enabled && local.key_vault_enabled

  # The environment a cluster belongs to, for the names of the environment's shared resources: the
  # variable, or else from the cluster's name - <what it is>-<environment>-<which one> -
  # `aks-dev-int-stateless-az3` is in `dev`.
  environment = coalesce(var.environment, length(local.name_segments) < 2 ? var.name : local.name_segments[1])

  # Tags the cluster already carries in Azure, or null while it does not exist yet or carries none.
  # Feeding them back keeps the tags out of the plan instead of having Terraform delete them.
  cluster_tags = try(data.azapi_resource_list.managed_clusters.output.tags, null)

  # The system pool as sent. The upgrade settings belong to the pool: the cluster level
  # upgrade_settings of the module only carries the force-upgrade override.
  default_agent_pool = {
    availability_zones  = var.default_node_pool.availability_zones
    count_of            = var.default_node_pool.node_count
    enable_auto_scaling = var.default_node_pool.enable_auto_scaling
    max_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.max_count : null
    max_pods            = var.default_node_pool.max_pods
    min_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.min_count : null
    name                = var.default_node_pool.name
    os_disk_size_gb     = var.default_node_pool.os_disk_size_gb
    os_disk_type        = var.default_node_pool.os_disk_type
    type                = "VirtualMachineScaleSets"
    upgrade_settings = {
      drain_timeout_in_minutes      = var.default_node_pool.drain_timeout_minutes
      max_surge                     = var.default_node_pool.max_surge
      node_soak_duration_in_minutes = var.default_node_pool.node_soak_duration_minutes
    }
    vm_size        = var.default_node_pool.vm_size
    vnet_subnet_id = data.azurerm_subnet.node.id
    # The system pool's pods in their own subnet (Azure CNI Pod Subnet)
    pod_subnet_id = data.azurerm_subnet.system_pods.id

    os_sku                    = var.default_node_pool.os_sku
    enable_encryption_at_host = var.default_node_pool.encryption_at_host
    node_taints               = var.default_node_pool.node_taints
    security_profile = var.default_node_pool.ssh_access == null ? null : {
      ssh_access = var.default_node_pool.ssh_access
    }
    # Stated, not inherited (design section 2.3): AKS turns LocalDNS on by itself where it can.
    local_dns_profile = local.local_dns_profile
  }

  local_dns_profile = { mode = "Disabled" }

  # The cluster's identity, by the naming policy's `user_assigned_identity` (modules/conventions) -
  # `id-<region code>-<environment>-<function>` by default - worked out from the cluster name and the
  # region rather than stated per environment. Its `{name}` is the cluster's name without the
  # environment's segment, so `aks-dev-int-stateless-az3` in germanywestcentral is run by
  # `id-gwc-dev-aks-int-stateless-az3`: the environment moves to the front of the function, and everything
  # past it distinguishes the cluster from its siblings in the same environment. A name with nothing to
  # split is its own environment and becomes `id-<region code>-<name>`. The policy refuses a region
  # with no code rather than name the identity with a guess.
  managed_identity_name = module.conventions.names.identity
  name_segments         = split("-", var.name)
  identity_name_part = join("-", [
    for i, segment in local.name_segments : segment if i != try(index(local.name_segments, local.environment), -1)
  ])

  # The zones' node pools create nodes outside the system pool's subnet, so Microsoft documents the
  # whole virtual network as the scope they need. A cluster without
  # zones joins only the system pool's subnet, so it keeps the narrower grant.
  network_role_assignment_scope = var.zone_node_pools != null ? "virtual_network" : "subnet"

  # Scopes the cluster identity is granted Network Contributor on. Keyed by role rather than by
  # resource ID, so that renaming a subnet does not churn the state addresses of the assignments.
  network_role_assignment_scopes = merge(
    local.network_role_assignment_scope == "virtual_network"
    ? { virtual_network = data.azurerm_virtual_network.this.id }
    : { node_subnet = data.azurerm_subnet.node.id, pod_subnet = data.azurerm_subnet.system_pods.id },
    # The node subnet's route table - a cell routed through the hub's firewall (`userDefinedRouting`):
    # AKS reads and joins it, and the table is a resource of its own, outside the network's scope.
    startswith(lower(try(data.azurerm_subnet.node.route_table_id, "")), "/subscriptions/") ? { route_table = data.azurerm_subnet.node.route_table_id } : {},
    # The zones' route tables, for the same reason: a zone's node subnet has a table of its own, with
    # the other zones' slots routed to the hub's firewall (design D73). A zone whose subnet shares the
    # node subnet's table is covered above.
    { for zone, subnet in data.azurerm_subnet.zone : "route_table_${zone}" => subnet.route_table_id
      if startswith(lower(try(subnet.route_table_id, "")), "/subscriptions/") && lower(try(subnet.route_table_id, "")) != lower(try(data.azurerm_subnet.node.route_table_id, ""))
    },
  )

  # Cluster-internal ranges that collide with the address space of the cell's network. Two CIDRs
  # overlap when they share a network address at the shorter of their two prefix lengths. IPv6
  # ranges are skipped rather than compared against IPv4 ones.
  cluster_cidrs = [var.network_profile.service_cidr]
  overlapping_cluster_cidrs = [
    for pair in setproduct(
      [for range in data.azurerm_virtual_network.this.address_space : range if !strcontains(range, ":")],
      local.cluster_cidrs
    ) : "${pair[1]} overlaps ${pair[0]}"
    if try(
      cidrhost(format("%s/%d", cidrhost(pair[0], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0)
      ==
      cidrhost(format("%s/%d", cidrhost(pair[1], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0),
      false
    )
  ]
}
