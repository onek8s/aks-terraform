# Two kinds of Flux configuration, all in the cell's Flux extension (the cell's, installed with its
# platform configuration):
#
# - `<namespace>`: the team's own repository, namespace-scoped in its namespace - the extension applies
#   it as that namespace's `flux-applier` and refuses references across namespaces.
# - `<namespace>-access`: the platform's part of the namespace, cluster scope in flux-system, read from
#   the cell's platform repository and branch: one Kustomization per group role (a RoleBinding from
#   namespace_access_path/<role>) and `store` (tenant_path: the namespace's default ServiceAccount, and
#   the `key-vault` ServiceAccount and SecretStore of its vault share). One configuration per namespace
#   because Azure refuses two Kustomizations of one configuration on the same path.

locals {
  team_flux_configurations = {
    for key, pair in local.cell_tenants : key => {
      properties = {
        gitRepository = merge({
          repositoryRef = {
            branch = pair.tenant.flux.branch
          }
          syncIntervalInSeconds = pair.tenant.flux.sync_interval_seconds
          url                   = pair.tenant.flux.url
        }, pair.tenant.flux.secret_name == null ? {} : { localAuthRef = pair.tenant.flux.secret_name })
        kustomizations = merge(
          {
            apps = {
              path                   = lookup(pair.tenant.flux.cell_paths, pair.cell, pair.tenant.flux.path)
              prune                  = true
              syncIntervalInSeconds  = pair.tenant.flux.sync_interval_seconds
              retryIntervalInSeconds = pair.tenant.flux.sync_interval_seconds
              wait                   = true
              # The few facts a team's manifests may use as `$${...}`: its zone, the cell's name and what the
              # tenant names. Nothing secret, nothing that reaches beyond the namespace.
              postBuild = {
                substitute = merge({ zone = pair.tenant.zone }, pair.tenant.flux.substitute, { cluster_name = pair.cell })
              }
            }
          },
          # The routes only the home cell serves (its internal names): the route is the DNS switch, so
          # exactly one cell publishes each name (design section 3.1).
          try(pair.tenant.flux.home.cell, null) == pair.cell ? {
            home = {
              path                   = pair.tenant.flux.home.path
              prune                  = true
              syncIntervalInSeconds  = pair.tenant.flux.sync_interval_seconds
              retryIntervalInSeconds = pair.tenant.flux.sync_interval_seconds
              wait                   = true
              # The few facts a team's manifests may use as `$${...}`: its zone, the cell's name and what the
              # tenant names. Nothing secret, nothing that reaches beyond the namespace.
              postBuild = {
                substitute = merge({ zone = pair.tenant.zone }, pair.tenant.flux.substitute, { cluster_name = pair.cell })
              }
            }
          } : {},
        )
        namespace  = pair.namespace
        scope      = "namespace"
        sourceKind = "GitRepository"
      }
    } if pair.tenant.flux != null
  }

  # The platform's repository as the cell's own configuration reads it.
  platform_git_repository = {
    for cell, repository in local.platform_repository : cell => {
      repositoryRef = {
        branch = repository.branch
      }
      syncIntervalInSeconds = repository.sync_interval_seconds
      url                   = repository.url
    }
  }

  platform_flux_configurations = {
    for key, pair in local.cell_tenants : key => {
      properties = {
        gitRepository = local.platform_git_repository[pair.cell]
        kustomizations = merge(
          {
            for binding in values(local.role_bindings) : binding.role => {
              path                   = "${trimsuffix(var.namespace_access_path, "/")}/${binding.role}"
              prune                  = true
              syncIntervalInSeconds  = local.platform_repository[pair.cell].sync_interval_seconds
              retryIntervalInSeconds = local.platform_repository[pair.cell].sync_interval_seconds
              wait                   = true
              postBuild = {
                substitute = {
                  namespace       = binding.namespace
                  role            = binding.role
                  group_object_id = binding.group_object_id
                }
              }
            } if binding.namespace == pair.namespace
          },
          {
            store = {
              path                   = var.tenant_path
              prune                  = true
              syncIntervalInSeconds  = local.platform_repository[pair.cell].sync_interval_seconds
              retryIntervalInSeconds = local.platform_repository[pair.cell].sync_interval_seconds
              wait                   = true
              postBuild = {
                substitute = {
                  namespace           = pair.namespace
                  zone                = pair.tenant.zone
                  key_vault_url       = data.azurerm_key_vault.zone[pair.tenant.zone].vault_uri
                  key_vault_client_id = data.azurerm_user_assigned_identity.key_vault[pair.namespace].client_id
                  azure_tenant_id     = data.azurerm_client_config.current.tenant_id
                }
              }
            }
          },
        )
        namespace  = "flux-system"
        scope      = "cluster"
        sourceKind = "GitRepository"
      }
    }
  }
}

resource "azapi_resource" "team_flux_configuration" {
  for_each = local.team_flux_configurations

  name      = local.cell_tenants[each.key].namespace
  parent_id = local.cluster_ids[local.cell_tenants[each.key].cell]
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = each.value

  # The namespace is AKS's to create, with its quota and default policies, before Flux puts anything in it.
  depends_on = [azapi_resource.namespace]
}

resource "azapi_resource" "platform_flux_configuration" {
  for_each = local.platform_flux_configurations

  name      = "${local.cell_tenants[each.key].namespace}-access"
  parent_id = local.cluster_ids[local.cell_tenants[each.key].cell]
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = each.value

  # The namespace is there before a binding or the store is put into it, and the store's identity is
  # federated with the cell before ESO asks for a token.
  depends_on = [azapi_resource.namespace, azurerm_federated_identity_credential.key_vault]
}
