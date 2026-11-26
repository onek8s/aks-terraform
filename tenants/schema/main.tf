# The shape of a tenant, with its defaults: the catalogue's YAML files and the stack's `tenants`
# variable both come through here, so that a file says only what it needs and every entry ends up
# with every attribute. Only the conversion is here; the rules a tenant must meet are the
# preconditions of the stack's `tenants` output, where a failing one names the tenant.
variable "tenants" {
  type = map(object({
    zone  = string
    cells = optional(list(string))
    owner = optional(object({
      team        = string
      cost_center = string
      contact     = string
    }))
    groups = optional(object({
      view  = optional(string)
      edit  = optional(string)
      admin = optional(string)
    }), {})
    labels      = optional(map(string), {})
    annotations = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string)
      ingress = optional(string)
    }), {})
    pod_security = optional(object({
      audit   = optional(string)
      enforce = optional(string)
      version = optional(string)
      warn    = optional(string)
    }), {})
    resource_quota = optional(object({
      cpu_limit      = optional(string)
      cpu_request    = optional(string)
      memory_limit   = optional(string)
      memory_request = optional(string)
    }), {})
    adoption_policy     = optional(string)
    delete_policy       = optional(string)
    dedicated_node_pool = optional(bool, false)
    flux = optional(object({
      url    = string
      branch = optional(string, "main")
      path   = optional(string, "./")
      # Another path of the same repository in the cells named here: a cluster of another type, the
      # stateful one's overlay.
      cell_paths            = optional(map(string), {})
      secret_name           = optional(string)
      sync_interval_seconds = optional(number, 300)
      substitute            = optional(map(string), {})
      # An internal application's home cell (design section 3.1) and the path of its routes that only
      # the home cell serves - its internal name. A Kustomization of its own, in that cell alone: moving
      # the application changes the cell, the old cell prunes the routes and the new one creates them.
      home = optional(object({
        cell = string
        path = string
      }))
    }))
    # Read by shared/, which keeps the namespace's identity and its grants on the zone's vault.
    key_vault = optional(object({
      writers = optional(list(object({
        principal_id   = string
        principal_type = optional(string, "Group")
      })), [])
    }), {})
  }))
  nullable = false
}

output "tenants" {
  value = var.tenants
}
