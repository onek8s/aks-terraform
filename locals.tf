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

  # Flux is installed only for a cluster that names a repository for it to sync: its own, or a
  # tenant namespace's.
  flux_enabled           = var.flux_git_repository != null
  flux_extension_enabled = local.flux_enabled || length(local.managed_namespace_flux_configurations) > 0

  # The Flux configuration of each managed namespace that deploys itself from a repository of its
  # own, as sent to Azure. Namespace scope, in the namespace itself: the extension applies it as
  # that namespace's `flux-applier` and refuses references across namespaces, so the repository
  # reaches nothing outside it. Its credential is a Secret already in the namespace, synced from the
  # namespace's share of the Key Vault, so nothing secret passes through here.
  #
  # A failed apply is retried as often as the repository is read, as on the platform's, and the
  # Kustomization waits for what it applied to become ready, so a rollout that never does shows up
  # on it - and in the portal.
  managed_namespace_flux_configurations = {
    for name, namespace in var.managed_namespaces : name => {
      properties = {
        gitRepository = merge({
          repositoryRef = {
            branch = namespace.flux.branch
          }
          syncIntervalInSeconds = namespace.flux.sync_interval_seconds
          url                   = namespace.flux.url
        }, namespace.flux.secret_name == null ? {} : { localAuthRef = namespace.flux.secret_name })
        kustomizations = {
          apps = {
            path                   = namespace.flux.path
            prune                  = true
            syncIntervalInSeconds  = namespace.flux.sync_interval_seconds
            retryIntervalInSeconds = namespace.flux.sync_interval_seconds
            wait                   = true
            # The few facts of the cluster a team's manifests may use, as `${...}` post-build
            # variables: which cluster it is, so an app can say where it runs. Nothing secret, and
            # nothing a team could use to reach beyond its namespace.
            postBuild = {
              substitute = merge(namespace.flux.substitute, {
                cluster_name = var.name
              })
            }
          }
        }
        namespace  = name
        scope      = "namespace"
        sourceKind = "GitRepository"
      }
    } if namespace.flux != null
  }

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

  # The role bindings of managed_namespaces[*].groups, as one Flux configuration per namespace that
  # names a group: cluster scope in flux-system, reading the cluster's own repository, with one
  # Kustomization per role that applies `<namespace_access_path>/<role>` with the namespace and the
  # group filled in. One configuration per namespace because Azure refuses two Kustomizations of one
  # configuration on the same path - and every namespace's view binding is made from the same one.
  # Removing a group removes its Kustomization, and Flux deletes the binding with it.
  managed_namespace_access_flux_configurations = local.flux_enabled ? {
    for name, namespace in var.managed_namespaces : name => {
      properties = merge(local.flux_configuration_body.properties, {
        kustomizations = {
          for binding in values(local.managed_namespace_role_bindings) : binding.role => {
            path                   = "${trimsuffix(var.namespace_access_path, "/")}/${binding.role}"
            prune                  = true
            syncIntervalInSeconds  = var.flux_git_repository.sync_interval_seconds
            retryIntervalInSeconds = var.flux_git_repository.sync_interval_seconds
            wait                   = true
            postBuild = {
              substitute = {
                namespace       = binding.namespace
                role            = binding.role
                group_object_id = binding.group_object_id
              }
            }
          } if binding.namespace == name
        }
      })
    } if length([for role in ["view", "edit", "admin"] : role if namespace.groups[role] != null]) > 0
  } : {}

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

  # The namespaces with a share of a vault: every managed namespace, and the ones the platform
  # creates itself that key_vault_namespaces names. None without a vault.
  key_vault_namespaces = local.key_vault_enabled ? toset(concat(tolist(var.key_vault_namespaces), keys(var.managed_namespaces), local.flux_github_webhook_enabled ? ["flux-system"] : [])) : toset([])

  # The Flux GitHub webhook's token is in the vault, for the Receiver in flux-system to read.
  flux_github_webhook_enabled = var.flux_github_webhook && local.flux_enabled && local.key_vault_enabled

  # The environment a cluster belongs to, for the names of the environment's shared resources: the
  # variable, or else from the cluster's name - <what it is>-<environment>-<which one> -
  # `aks-dev-ext-stateless-az1` is in `dev`.
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
  }

  # The cluster's identity, by the naming policy's `user_assigned_identity` (modules/conventions) -
  # `id-<region code>-<environment>-<function>` by default - worked out from the cluster name and the
  # region rather than stated per environment. Its `{name}` is the cluster's name without the
  # environment's segment, so `aks-dev-ext-stateless-az1` in swedencentral is run by
  # `id-sec-dev-aks-stateless-az1`: the environment moves to the front of the function, and everything
  # past it distinguishes the cluster from its siblings in the same environment. A name with nothing to
  # split is its own environment and becomes `id-<region code>-<name>`. The policy refuses a region
  # with no code rather than name the identity with a guess.
  managed_identity_name = module.conventions.names.identity
  name_segments         = split("-", var.name)
  identity_name_part = join("-", [
    for i, segment in local.name_segments : segment if i != try(index(local.name_segments, local.environment), -1)
  ])

  # Every managed namespace as the request body AKS takes, with the estate-wide defaults filled in
  # wherever the namespace itself says nothing. Labels and annotations merge key by key, so a
  # namespace adds to the default set instead of replacing it; everything else is a plain override.
  #
  # The optional parts - the labels and annotations - are merged in rather than sent as null, because
  # AzAPI only tracks what the body declares: a key written out as null is sent as null and then
  # differs from what Azure answers with, which turns up as an update in every later plan. The quota
  # is not among them: Azure requires one on every managed namespace, so every namespace sends one.
  managed_namespace_properties = {
    for name, namespace in var.managed_namespaces : name => merge(
      {
        adoptionPolicy = coalesce(namespace.adoption_policy, var.managed_namespace_defaults.adoption_policy)
        defaultNetworkPolicy = {
          egress  = coalesce(namespace.network_policy.egress, var.managed_namespace_defaults.network_policy.egress)
          ingress = coalesce(namespace.network_policy.ingress, var.managed_namespace_defaults.network_policy.ingress)
        }
        defaultResourceQuota = local.managed_namespace_resource_quotas[name]
        deletePolicy         = coalesce(namespace.delete_policy, var.managed_namespace_defaults.delete_policy)
      },
      length(local.managed_namespace_annotations[name]) == 0 ? {} : { annotations = local.managed_namespace_annotations[name] },
      length(local.managed_namespace_labels[name]) == 0 ? {} : { labels = local.managed_namespace_labels[name] },
    )
  }

  managed_namespace_annotations = {
    for name, namespace in var.managed_namespaces : name => tomap(merge(
      var.managed_namespace_defaults.annotations,
      namespace.annotations,
      namespace.owner == null ? tomap({}) : tomap({ "platform/contact" = namespace.owner.contact }),
      namespace.flux == null ? tomap({}) : tomap({ "platform/repository" = namespace.flux.url }),
    ))
  }

  # The pod security labels come last, because they are decided by `pod_security` alone - `labels`
  # is refused a `pod-security.kubernetes.io/*` key of its own, so nothing here is being overridden.
  managed_namespace_labels = {
    for name, namespace in var.managed_namespaces : name => tomap(merge(
      var.managed_namespace_defaults.labels,
      namespace.labels,
      local.managed_namespace_owner_labels[name],
      local.managed_namespace_pod_security_labels[name],
    ))
  }

  # Who owns the namespace and pays for it, as the labels OpenCost and the telemetry group by - see
  # managed_namespaces' `owner`.
  managed_namespace_owner_labels = {
    for name, namespace in var.managed_namespaces : name => namespace.owner == null ? tomap({}) : tomap({
      "platform/team"        = namespace.owner.team
      "platform/cost-center" = namespace.owner.cost_center
    })
  }

  # The Pod Security Standard each namespace is held to, with the estate-wide default filled in
  # wherever the namespace says nothing. Relaxing `enforce` for a workload that cannot meet the
  # standard leaves `audit` and `warn` where they were, so the exception stays on the record.
  managed_namespace_pod_security = {
    for name, namespace in var.managed_namespaces : name => {
      audit   = coalesce(namespace.pod_security.audit, var.managed_namespace_defaults.pod_security.audit)
      enforce = coalesce(namespace.pod_security.enforce, var.managed_namespace_defaults.pod_security.enforce)
      version = coalesce(namespace.pod_security.version, var.managed_namespace_defaults.pod_security.version)
      warn    = coalesce(namespace.pod_security.warn, var.managed_namespace_defaults.pod_security.warn)
    }
  }

  # ... as the labels the API server's Pod Security Admission controller reads. This is the whole of
  # the mechanism: admission is built into the API server, there is nothing to install, and a mode
  # set to `none` leaves its label off rather than being sent an empty one.
  #
  # The version label pins the standard to a Kubernetes release. `latest` follows the cluster, so an
  # upgrade can tighten what a namespace enforces under a workload that was passing the day before.
  managed_namespace_pod_security_labels = {
    for name, pod_security in local.managed_namespace_pod_security : name => merge(
      pod_security.audit == "none" ? {} : {
        "pod-security.kubernetes.io/audit"         = pod_security.audit
        "pod-security.kubernetes.io/audit-version" = pod_security.version
      },
      pod_security.enforce == "none" ? {} : {
        "pod-security.kubernetes.io/enforce"         = pod_security.enforce
        "pod-security.kubernetes.io/enforce-version" = pod_security.version
      },
      pod_security.warn == "none" ? {} : {
        "pod-security.kubernetes.io/warn"         = pod_security.warn
        "pod-security.kubernetes.io/warn-version" = pod_security.version
      },
    )
  }

  # How much each Pod Security Standard permits, so that "weaker than the estate default" is
  # something that can be compared rather than guessed at. `none` sits below `privileged`: both
  # permit everything, and `none` additionally leaves no label saying so.
  pod_security_strictness = {
    none       = -1
    privileged = 0
    baseline   = 1
    restricted = 2
  }

  # Namespaces that relax what they enforce below the estate default and record nothing in its
  # place - neither audit nor warn is left at the standard the estate expects, so the pods that
  # break it are neither refused nor written down anywhere.
  managed_namespaces_with_silent_pod_security_exceptions = [
    for name, pod_security in local.managed_namespace_pod_security : name
    if local.pod_security_strictness[pod_security.enforce] < local.pod_security_strictness[var.managed_namespace_defaults.pod_security.enforce]
    && max(
      local.pod_security_strictness[pod_security.audit],
      local.pod_security_strictness[pod_security.warn],
    ) < local.pod_security_strictness[var.managed_namespace_defaults.pod_security.enforce]
  ]

  # Every CPU figure the quotas name, in the milliCPU form Azure takes. AKS refuses a managed
  # namespace that states CPU any other way - "The managed namespace CPU request number is not
  # valid. CPU request of the managed namespace must be in milliCPU form" - where Kubernetes reads
  # "2" and "2000m" as the same two cores. The variables keep both forms, so that a quota reads the
  # way it would in a manifest, and the cores are turned into milliCPU here rather than by hand in
  # every variables file.
  #
  # Worked out on the digits rather than by multiplying by a thousand: these are decimal fractions
  # of a core, binary floating point holds none of them exactly, and 0.1 cores would come out either
  # side of 100m. The fraction is padded out to the three digits a milliCPU figure has - "0.5" is
  # 500m, not 5m - and reading the two halves back as one number drops the leading zeros with them.
  managed_namespace_cpu_millicores = {
    for quantity in local.managed_namespace_cpu_quantities : quantity => format("%dm", tonumber(
      endswith(quantity, "m")
      ? trimsuffix(quantity, "m")
      : "${split(".", quantity)[0]}${substr("${try(split(".", quantity)[1], "")}000", 0, 3)}"
    ))
  }

  # The distinct CPU figures there are to convert, whichever namespace or default they came from.
  managed_namespace_cpu_quantities = toset(flatten([
    for quota in local.managed_namespace_resource_quota_inputs : [
      for field, quantity in quota : quantity if startswith(field, "cpu")
    ]
  ]))

  # The quota figures a namespace ends up with, in the shape the API takes: the CPU ones as
  # milliCPU, the memory ones as they were written, since Azure takes those in the Kubernetes forms.
  managed_namespace_resource_quotas = {
    for name, quota in local.managed_namespace_resource_quota_inputs : name => {
      for field, quantity in quota :
      field => startswith(field, "cpu") ? local.managed_namespace_cpu_millicores[quantity] : quantity
    }
  }

  # ... and the same figures as they were named, before the CPU ones become milliCPU. Every
  # namespace carries all four: Azure requires the quota on a managed namespace even though the API
  # spec has it optional - a namespace sent without one is refused with "The managed namespace CPU
  # request number is not valid" - and `az aks namespace add` asks for all four figures for the same
  # reason. There is therefore no such thing here as a namespace without a quota; what a namespace
  # does not name it takes from managed_namespace_defaults, which names all four.
  managed_namespace_resource_quota_inputs = {
    for name, namespace in var.managed_namespaces : name => {
      cpuLimit      = coalesce(namespace.resource_quota.cpu_limit, var.managed_namespace_defaults.resource_quota.cpu_limit)
      cpuRequest    = coalesce(namespace.resource_quota.cpu_request, var.managed_namespace_defaults.resource_quota.cpu_request)
      memoryLimit   = coalesce(namespace.resource_quota.memory_limit, var.managed_namespace_defaults.resource_quota.memory_limit)
      memoryRequest = coalesce(namespace.resource_quota.memory_request, var.managed_namespace_defaults.resource_quota.memory_request)
    }
  }

  # The Kubernetes RoleBindings of `managed_namespaces[*].groups`: one per namespace and role that
  # names a group, keyed `<namespace>-<role>`. Which ones there are follows from the inputs alone.
  managed_namespace_role_bindings = {
    for binding in flatten([
      for name, namespace in var.managed_namespaces : [
        for role in ["view", "edit", "admin"] : {
          namespace       = name
          role            = role
          group_object_id = lower(namespace.groups[role])
        } if namespace.groups[role] != null
      ]
    ]) : "${binding.namespace}-${binding.role}" => binding
  }

  # Every group of `groups` gets `Azure Kubernetes Service Namespace User` on its namespace, so that
  # its members can fetch a kubeconfig for the namespace. Keyed by what it grants rather than by
  # position, so that a group removed from one role does not renumber the rest.
  managed_namespace_user_grants = {
    for grant in distinct([
      for binding in values(local.managed_namespace_role_bindings) : { namespace = binding.namespace, group_object_id = binding.group_object_id }
    ]) : "${grant.namespace}/namespace_user/${grant.group_object_id}" => grant
  }

  # Namespaces whose default policies actually restrict something, which is what needs a network
  # policy engine in the cluster to be worth anything. A namespace left wide open in both
  # directions is unaffected by whether one is running.
  managed_namespaces_relying_on_network_policy = [
    for name, properties in local.managed_namespace_properties : name
    if properties.defaultNetworkPolicy.egress != "AllowAll" || properties.defaultNetworkPolicy.ingress != "AllowAll"
  ]

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
