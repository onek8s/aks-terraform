# The managed namespaces: AKS creates and keeps each inside its cell, with its labels, annotations,
# default NetworkPolicy and ResourceQuota, so a namespace survives being deleted by hand and Azure RBAC
# can be scoped to it. Written with AzAPI, which tracks only what the body declares (the repository
# root's README, "Managed namespaces", explains why each part is sent the way it is).

locals {
  # Every tenant's properties that do not depend on the cell, with the defaults filled in wherever the
  # tenant says nothing. Labels and annotations merge key by key.
  namespace_pod_security = {
    for name, tenant in local.tenants : name => {
      audit   = coalesce(tenant.pod_security.audit, var.namespace_defaults.pod_security.audit)
      enforce = coalesce(tenant.pod_security.enforce, var.namespace_defaults.pod_security.enforce)
      version = coalesce(tenant.pod_security.version, var.namespace_defaults.pod_security.version)
      warn    = coalesce(tenant.pod_security.warn, var.namespace_defaults.pod_security.warn)
    }
  }

  # ... as the labels the API server's Pod Security Admission reads; a mode set to `none` leaves its
  # label off.
  namespace_pod_security_labels = {
    for name, pod_security in local.namespace_pod_security : name => merge(
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

  pod_security_strictness = {
    none       = -1
    privileged = 0
    baseline   = 1
    restricted = 2
  }

  # Tenants that relax what they enforce below the default and record nothing in its place.
  tenants_with_silent_pod_security_exceptions = [
    for name, pod_security in local.namespace_pod_security : name
    if local.pod_security_strictness[pod_security.enforce] < local.pod_security_strictness[var.namespace_defaults.pod_security.enforce]
    && max(
      local.pod_security_strictness[pod_security.audit],
      local.pod_security_strictness[pod_security.warn],
    ) < local.pod_security_strictness[var.namespace_defaults.pod_security.enforce]
  ]

  namespace_labels = {
    for name, tenant in local.tenants : name => tomap(merge(
      var.namespace_defaults.labels,
      tenant.labels,
      { "platform/zone" = tenant.zone },
      tenant.owner == null ? tomap({}) : tomap({
        "platform/team"        = tenant.owner.team
        "platform/cost-center" = tenant.owner.cost_center
      }),
      local.namespace_pod_security_labels[name],
    ))
  }

  # The quota every managed namespace must carry, the CPU figures as the milliCPU Azure takes (worked
  # out on the digits: binary floating point holds no decimal fraction of a core exactly).
  namespace_resource_quota_inputs = {
    for name, tenant in local.tenants : name => {
      cpuLimit      = coalesce(tenant.resource_quota.cpu_limit, var.namespace_defaults.resource_quota.cpu_limit)
      cpuRequest    = coalesce(tenant.resource_quota.cpu_request, var.namespace_defaults.resource_quota.cpu_request)
      memoryLimit   = coalesce(tenant.resource_quota.memory_limit, var.namespace_defaults.resource_quota.memory_limit)
      memoryRequest = coalesce(tenant.resource_quota.memory_request, var.namespace_defaults.resource_quota.memory_request)
    }
  }
  namespace_cpu_quantities = toset(flatten([
    for quota in local.namespace_resource_quota_inputs : [
      for field, quantity in quota : quantity if startswith(field, "cpu")
    ]
  ]))
  namespace_cpu_millicores = {
    for quantity in local.namespace_cpu_quantities : quantity => format("%dm", tonumber(
      endswith(quantity, "m")
      ? trimsuffix(quantity, "m")
      : "${split(".", quantity)[0]}${substr("${try(split(".", quantity)[1], "")}000", 0, 3)}"
    ))
  }
  namespace_resource_quotas = {
    for name, quota in local.namespace_resource_quota_inputs : name => {
      for field, quantity in quota :
      field => startswith(field, "cpu") ? local.namespace_cpu_millicores[quantity] : quantity
    }
  }

  # Placement (design section 2.3), per cell: Kubernetes' PodNodeSelector and PodTolerationRestriction
  # admission plugins read the namespace's annotations. Every tenant of a zone with node pools in the
  # cell gets a tolerations whitelist - its zone's taint, spot (platform/capacity and AKS's own), GPU,
  # the node conditions Kubernetes tolerates by default and, on a dedicated pool, its own pool - so no
  # other namespace's pods tolerate that pool. A dedicated tenant also gets the pool's node selector and
  # toleration on every pod, so the application states nothing. The pools are the cell's
  # (namespace_node_pools); a dedicated tenant whose cell has none is refused below.
  zone_has_pools = {
    for key, pair in local.cell_tenants : key => anytrue([
      for labels in local.pool_labels[pair.cell] : lookup(labels, "platform/zone", null) == pair.tenant.zone
    ])
  }
  dedicated_pool_exists = {
    for key, pair in local.cell_tenants : key => anytrue([
      for labels in local.pool_labels[pair.cell] : lookup(labels, "platform/pool", null) == pair.namespace
    ])
  }
  pool_tolerations = {
    for name in keys(local.tenants) : name => [
      { key = "platform/pool", operator = "Equal", value = name, effect = "NoSchedule" }
    ]
  }
  placement_annotations = {
    for key, pair in local.cell_tenants : key => (
      !local.zone_has_pools[key] ? tomap({}) : tomap(merge(
        {
          "scheduler.alpha.kubernetes.io/tolerationsWhitelist" = jsonencode(concat(
            [
              { key = "platform/zone", operator = "Equal", value = pair.tenant.zone, effect = "NoSchedule" },
              { key = "platform/capacity", operator = "Equal", value = "spot", effect = "NoSchedule" },
              { key = "kubernetes.azure.com/scalesetpriority", operator = "Equal", value = "spot", effect = "NoSchedule" },
              { key = "platform/accelerator", operator = "Equal", value = "nvidia-gpu", effect = "NoSchedule" },
              { key = "nvidia.com/gpu", operator = "Exists" },
            ],
            [for condition in ["not-ready", "unreachable", "memory-pressure", "disk-pressure", "pid-pressure", "network-unavailable", "unschedulable"] : { key = "node.kubernetes.io/${condition}", operator = "Exists" }],
            pair.tenant.dedicated_node_pool ? local.pool_tolerations[pair.namespace] : [],
          ))
        },
        pair.tenant.dedicated_node_pool ? {
          "scheduler.alpha.kubernetes.io/node-selector"      = "platform/pool=${pair.namespace}"
          "scheduler.alpha.kubernetes.io/defaultTolerations" = jsonencode(local.pool_tolerations[pair.namespace])
        } : {},
      ))
    )
  }

  namespace_annotations = {
    for key, pair in local.cell_tenants : key => tomap(merge(
      var.namespace_defaults.annotations,
      pair.tenant.annotations,
      pair.tenant.owner == null ? tomap({}) : tomap({ "platform/contact" = pair.tenant.owner.contact }),
      pair.tenant.flux == null ? tomap({}) : tomap({ "platform/repository" = pair.tenant.flux.url }),
      local.placement_annotations[key],
    ))
  }

  # The request body of each namespace in each cell. The optional parts are merged in rather than sent
  # as null; the quota is always sent, as Azure requires one.
  namespace_properties = {
    for key, pair in local.cell_tenants : key => merge(
      {
        adoptionPolicy = coalesce(pair.tenant.adoption_policy, var.namespace_defaults.adoption_policy)
        defaultNetworkPolicy = {
          egress  = coalesce(pair.tenant.network_policy.egress, var.namespace_defaults.network_policy.egress)
          ingress = coalesce(pair.tenant.network_policy.ingress, var.namespace_defaults.network_policy.ingress)
        }
        defaultResourceQuota = local.namespace_resource_quotas[pair.namespace]
        deletePolicy         = coalesce(pair.tenant.delete_policy, var.namespace_defaults.delete_policy)
      },
      length(local.namespace_annotations[key]) == 0 ? {} : { annotations = local.namespace_annotations[key] },
      length(local.namespace_labels[pair.namespace]) == 0 ? {} : { labels = local.namespace_labels[pair.namespace] },
    )
  }

  # Tenants whose default policies restrict something, in cells without a network policy engine.
  namespaces_without_a_policy_engine = [
    for key, properties in local.namespace_properties : key
    if contains(["none", ""], coalesce(local.network_policies[local.cell_tenants[key].cell], "none"))
    && (properties.defaultNetworkPolicy.egress != "AllowAll" || properties.defaultNetworkPolicy.ingress != "AllowAll")
  ]

  # The RoleBindings of each tenant's groups, keyed `<namespace>-<role>`, and the `Azure Kubernetes
  # Service Namespace User` grant of each group on its namespace in each cell.
  role_bindings = {
    for binding in flatten([
      for name, tenant in local.tenants : [
        for role in ["view", "edit", "admin"] : {
          namespace       = name
          role            = role
          group_object_id = lower(tenant.groups[role])
        } if tenant.groups[role] != null
      ]
    ]) : "${binding.namespace}-${binding.role}" => binding
  }
  namespace_user_grants = {
    for grant in distinct(flatten([
      for key, pair in local.cell_tenants : [
        for binding in values(local.role_bindings) : { key = key, group_object_id = binding.group_object_id } if binding.namespace == pair.namespace
      ]
    ])) : "${grant.key}/namespace_user/${grant.group_object_id}" => grant
  }
}

resource "azapi_resource" "namespace" {
  for_each = local.cell_tenants

  location  = var.location
  name      = each.value.namespace
  parent_id = local.cluster_ids[each.value.cell]
  type      = "Microsoft.ContainerService/managedClusters/managedNamespaces@${local.aks_api_version}"
  body = {
    properties = local.namespace_properties[each.key]
  }
  # AzAPI's embedded AKS schema does not cover that API version yet. Azure still validates it.
  schema_validation_enabled = false

  lifecycle {
    precondition {
      condition     = !each.value.tenant.dedicated_node_pool || local.dedicated_pool_exists[each.key]
      error_message = "${each.value.namespace} asks for a dedicated node pool, and ${each.value.cell} has no node pool labelled platform/pool=${each.value.namespace}: add the namespace to the cell's namespace_node_pools and apply the cell first."
    }
  }
}

# A kubeconfig for the namespace alone, for each group: `Azure Kubernetes Service Namespace User` on
# the namespace resource lets a member run `az aks namespace get-credentials`, with the rights its
# RoleBinding gives it there - no cluster-wide grant at all.
resource "azurerm_role_assignment" "namespace_user" {
  for_each = local.namespace_user_grants

  principal_id         = each.value.group_object_id
  scope                = azapi_resource.namespace[each.value.key].id
  role_definition_name = "Azure Kubernetes Service Namespace User"
  # A group created moments ago has not replicated everywhere yet.
  principal_type = "Group"
}

check "namespaces_have_something_enforcing_their_network_policies" {
  assert {
    condition     = length(local.namespaces_without_a_policy_engine) == 0
    error_message = "${join(", ", local.namespaces_without_a_policy_engine)}: the cell has no network policy engine, so the namespace's restricted default policies are written but never applied. Give the cell one, or set network_policy = { egress = \"AllowAll\", ingress = \"AllowAll\" } to say that the boundary is drawn somewhere else."
  }
}

check "pod_security_exceptions_stay_on_the_record" {
  assert {
    condition     = length(local.tenants_with_silent_pod_security_exceptions) == 0
    error_message = "${join(", ", local.tenants_with_silent_pod_security_exceptions)} enforce a weaker Pod Security Standard than namespace_defaults.pod_security.enforce (${var.namespace_defaults.pod_security.enforce}) and audit or warn nothing at that standard either, so a pod that breaks it is neither refused nor recorded. Leave pod_security.audit or pod_security.warn at \"${var.namespace_defaults.pod_security.enforce}\"."
  }
}
