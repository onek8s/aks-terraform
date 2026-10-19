# The Gateway API implementation of the cluster's Gateways - see gateway_implementation. App Routing's
# is an AKS setting (main.tf, ingress_profile); Traefik is deployed here, through one Flux
# configuration per Gateway reading gateways/traefik of this repository.

locals {
  # The cluster's Gateways, as the Flux repository runs them: one per isolation zone, `<zone>` in
  # `<zone>-gateway`, behind an internal load balancer for an internal zone.
  gateways = var.gateway_implementation == null ? {} : {
    for zone in keys(var.isolation_zones) : zone => {
      namespace = "${zone}-gateway"
      exposure  = startswith(zone, "int-") ? "int" : "ext"
      internal  = startswith(zone, "int-")
    }
  }

  # The class each Gateway names, told to the Flux repository as `gateway_class_name_<gateway>`, and
  # the implementation itself as `gateway_implementation`: the Flux repository adds what only one
  # implementation takes (App Routing's parametersRef ConfigMap, which Traefik refuses) as a kustomize
  # component of that name.
  flux_gateway_settings = merge(
    {
      for name, gateway in local.gateways : "gateway_class_name_${replace(name, "-", "_")}" => (
        var.gateway_implementation == "traefik" ? "traefik-${name}" : "approuting-istio"
      )
    },
    var.gateway_implementation == null ? {} : { gateway_implementation = var.gateway_implementation },
  )

  # Traefik for each Gateway, as sent to Azure: cluster scope in flux-system, like the platform's
  # configuration, with the Gateway's values filled into gateways/traefik. One configuration per
  # Gateway, because Azure refuses two Kustomizations of one configuration on the same path.
  traefik_flux_configurations = var.gateway_implementation == "traefik" ? {
    for name, gateway in local.gateways : name => {
      properties = {
        gitRepository = {
          repositoryRef = {
            branch = var.traefik_flux_repository.branch
          }
          syncIntervalInSeconds = var.traefik_flux_repository.sync_interval_seconds
          url                   = var.traefik_flux_repository.url
        }
        kustomizations = {
          gateway = {
            path                   = var.traefik_flux_repository.path
            prune                  = true
            syncIntervalInSeconds  = var.traefik_flux_repository.sync_interval_seconds
            retryIntervalInSeconds = 60
            wait                   = true
            postBuild = {
              substitute = {
                gateway_name      = name
                gateway_namespace = gateway.namespace
                gateway_exposure  = gateway.exposure
                gateway_internal  = tostring(gateway.internal)
                quote             = "\""
              }
            }
          }
        }
        namespace  = "flux-system"
        scope      = "cluster"
        sourceKind = "GitRepository"
      }
    }
  } : {}
}

check "traefik_needs_flux" {
  assert {
    condition     = length(local.traefik_flux_configurations) == 0 || local.flux_extension_enabled
    error_message = "${var.name} asks for Traefik (gateway_implementation), which is deployed through Flux, but has no flux_git_repository: no Flux extension is installed to deploy it."
  }
}

# Named `traefik-<gateway>`; its Kustomization is `traefik-<gateway>-gateway` in flux-system. The
# Gateway's namespace is the Flux repository's: until it exists, the Kustomization retries.
resource "azapi_resource" "traefik_flux_configuration" {
  for_each = local.flux_extension_enabled ? local.traefik_flux_configurations : {}

  name      = "traefik-${each.key}"
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@${local.kubernetes_configuration_api_version}"
  body      = each.value

  depends_on = [azapi_resource.flux_extension]
}
