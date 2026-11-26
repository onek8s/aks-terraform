# The catalogue as the stack read it - and the rules every tenant must meet, as preconditions: a
# failing one stops the plan and names what is wrong.
output "tenants" {
  description = "Every tenant, with the cells it is in."
  value = {
    for name, tenant in local.tenants : name => merge(tenant, {
      cells = sort([for key, pair in local.cell_tenants : pair.cell if pair.namespace == name])
    })
  }

  precondition {
    condition     = alltrue([for name in keys(local.tenants) : can(regex("^[a-z0-9]([-a-z0-9]{0,46}[a-z0-9])?$", name)) && !strcontains(name, "--")])
    error_message = "A tenant is a Kubernetes namespace name of at most 48 characters (lowercase letters, digits and hyphens, starting and ending with a letter or digit) with no `--`: its Flux Kustomizations are named <namespace>-access-<role>, which Flux uses as a label value, and it owns the vault's secrets named `<namespace>--...`, which another namespace's prefix must not overlap."
  }
  precondition {
    condition     = alltrue([for name, tenant in local.tenants : startswith(name, "${tenant.zone}-") && length(name) > length(tenant.zone) + 1])
    error_message = "A tenant is an application namespace of its isolation zone, named <zone>-<app> (design section 2.6): ${join(", ", [for name, tenant in local.tenants : name if !startswith(name, "${tenant.zone}-")])}."
  }
  # Microsoft documents system namespaces as not on-boardable, and the platform's Flux configurations
  # share one name space with the tenants' (`platform`).
  precondition {
    condition = alltrue([
      for name in keys(local.tenants) :
      !startswith(name, "kube-")
      && !contains(["app-routing-system", "gatekeeper-system", "istio-system", "flux-system", "platform"], name)
    ])
    error_message = "A tenant cannot be a system namespace (kube-*, app-routing-system, gatekeeper-system, istio-system, flux-system) nor share a name with the platform's Flux configuration (platform)."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [for cell in coalesce(tenant.cells, []) : contains(keys(var.cells), cell) && contains(try(var.cells[cell].zones, []), tenant.zone)]
    ]))
    error_message = "A tenant's cells must be cells of the environment (cells) that hold its zone."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.owner == null || (
        can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", tenant.owner.team))
        && can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", tenant.owner.cost_center))
        && trimspace(tenant.owner.contact) != ""
      )
    ])
    error_message = "owner.team and .cost_center must be Kubernetes label values (1 to 63 letters, digits, '-', '_' or '.', starting and ending with a letter or digit), and .contact must not be empty."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : length(setintersection(keys(tenant.labels), ["platform/team", "platform/cost-center", "platform/zone"])) == 0
    ])
    error_message = "labels must not set platform/team, platform/cost-center or platform/zone: owner and zone are where they are set."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [for key in keys(tenant.labels) : !startswith(key, "pod-security.kubernetes.io/")]
    ]))
    error_message = "labels must not set a pod-security.kubernetes.io/* label. Use pod_security, which is where the Pod Security Standard of a namespace is decided."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [
        for level in [tenant.pod_security.audit, tenant.pod_security.enforce, tenant.pod_security.warn] :
        level == null || contains(["baseline", "none", "privileged", "restricted"], coalesce(level, "-"))
      ]
    ]))
    error_message = "pod_security.audit, .enforce and .warn must each be one of \"restricted\", \"baseline\", \"privileged\" or \"none\", or left unset to follow namespace_defaults."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.pod_security.version == null || can(regex("^(latest|v[0-9]+\\.[0-9]+)$", coalesce(tenant.pod_security.version, "-")))
    ])
    error_message = "pod_security.version must be \"latest\" or a pinned Kubernetes minor version such as \"v1.31\"."
  }
  # The group's object ID is the Kubernetes group name AKS gives its members - not its display name.
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [
        for group in [tenant.groups.view, tenant.groups.edit, tenant.groups.admin] :
        group == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", coalesce(group, "-")))
      ]
    ]))
    error_message = "groups.view, .edit and .admin must each be the object ID of an Entra ID group, for example \"00000000-0000-0000-0000-000000000000\", or left unset."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.adoption_policy == null || contains(["Always", "IfIdentical", "Never"], coalesce(tenant.adoption_policy, "-"))
    ])
    error_message = "adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\", or left unset to follow namespace_defaults."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.delete_policy == null || contains(["Delete", "Keep"], coalesce(tenant.delete_policy, "-"))
    ])
    error_message = "delete_policy must be either \"Delete\" or \"Keep\", or left unset to follow namespace_defaults."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [
        for rule in [tenant.network_policy.egress, tenant.network_policy.ingress] :
        rule == null || contains(["AllowAll", "AllowSameNamespace", "DenyAll"], coalesce(rule, "-"))
      ]
    ]))
    error_message = "network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\", or left unset to follow namespace_defaults."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [
        for quantity in [tenant.resource_quota.cpu_limit, tenant.resource_quota.cpu_request] :
        quantity == null || (can(regex("^([0-9]+(\\.[0-9]{1,3})?|[0-9]+m)$", coalesce(quantity, "-"))) && try(tonumber(trimsuffix(quantity, "m")) > 0, false))
      ]
    ]))
    error_message = "resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities of at least 1 milliCPU, for example \"500m\", \"0.5\" or \"2\"."
  }
  precondition {
    condition = alltrue(flatten([
      for tenant in values(local.tenants) : [
        for quantity in [tenant.resource_quota.memory_limit, tenant.resource_quota.memory_request] :
        quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", coalesce(quantity, "-")))
      ]
    ]))
    error_message = "resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.flux == null || try(
        can(regex("^https://", tenant.flux.url)) && trimspace(tenant.flux.branch) != "" && tenant.flux.sync_interval_seconds >= 60,
        false,
      )
    ])
    error_message = "flux.url must start with https://, flux.branch must not be empty and flux.sync_interval_seconds must be at least 60."
  }
  precondition {
    condition = alltrue([
      for tenant in values(local.tenants) : tenant.flux == null || try(tenant.flux.secret_name == null || can(regex("^[a-z0-9]([-.a-z0-9]{0,251}[a-z0-9])?$", tenant.flux.secret_name)), false)
    ])
    error_message = "flux.secret_name must be the name of a Kubernetes Secret: lowercase letters, digits, hyphens and dots, starting and ending with a letter or digit."
  }
  # The home cell is one of the tenant's cells, and its path is in the repository (design section 3.1).
  precondition {
    condition = alltrue([
      for name, tenant in local.tenants : try(tenant.flux.home, null) == null || try(
        anytrue([for pair in values(local.cell_tenants) : pair.namespace == name && pair.cell == tenant.flux.home.cell]) && startswith(tenant.flux.home.path, "./"),
        false,
      )
    ])
    error_message = "flux.home.cell must be one of the tenant's cells and flux.home.path a path in the repository starting with ./: ${join(", ", [for name, tenant in local.tenants : name if try(tenant.flux.home, null) != null && !try(anytrue([for pair in values(local.cell_tenants) : pair.namespace == name && pair.cell == tenant.flux.home.cell]), false)])}."
  }
}

output "namespace_ids" {
  description = "Each managed namespace's resource ID, keyed `<cell>/<namespace>`."
  value       = { for key, namespace in azapi_resource.namespace : key => namespace.id }
}

check "every_tenant_is_in_a_cell" {
  assert {
    condition     = alltrue([for name in keys(local.tenants) : anytrue([for pair in values(local.cell_tenants) : pair.namespace == name])])
    error_message = "No cell holds the zone of ${join(", ", [for name in keys(local.tenants) : name if !anytrue([for pair in values(local.cell_tenants) : pair.namespace == name])])}: the tenant is defined and deployed nowhere."
  }
}
