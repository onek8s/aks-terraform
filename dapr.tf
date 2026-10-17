# The AKS Dapr extension, with `dapr` - a trial on a lab cell, not a platform feature (OneK8s design
# D65; section 7.4 lists it among the options kept open). AKS installs and upgrades Dapr's control plane;
# an application opts in per pod with the `dapr.io/enabled` annotation and gets the daprd sidecar.
locals {
  dapr_settings = var.dapr == null ? {} : merge(
    {
      "global.ha.enabled" = tostring(var.dapr.high_availability)
      # No StorageClass in a stateless cell (persistent_storage_enabled): placement's Raft log and the
      # scheduler's etcd in memory, so neither asks for a PersistentVolumeClaim - which the landing
      # zone's no-persistent-storage policy would refuse anyway.
      "dapr_placement.cluster.forceInMemoryLog" = "true"
      "dapr_scheduler.cluster.inMemoryStorage"  = "true"
      # The sidecar as Pod Security restricted asks (section 2.7): every capability dropped, the
      # runtime's seccomp profile; daprd already runs as non-root on a read-only root file system.
      "dapr_sidecar_injector.sidecarDropALLCapabilities" = "true"
      "global.seccompProfile"                            = "RuntimeDefault"
      # Requests as Dapr's production guidelines give them (the chart sets none), so the scheduler
      # places the control plane honestly on a full system node. The guidelines have no figure for the
      # scheduler: measured in the trial.
      "dapr_operator.resources.requests.cpu"            = "100m"
      "dapr_operator.resources.requests.memory"         = "100Mi"
      "dapr_sidecar_injector.resources.requests.cpu"    = "100m"
      "dapr_sidecar_injector.resources.requests.memory" = "30Mi"
      "dapr_sentry.resources.requests.cpu"              = "100m"
      "dapr_sentry.resources.requests.memory"           = "30Mi"
      "dapr_placement.resources.requests.cpu"           = "250m"
      "dapr_placement.resources.requests.memory"        = "75Mi"
      "dapr_scheduler.resources.requests.cpu"           = "100m"
      "dapr_scheduler.resources.requests.memory"        = "128Mi"
    },
    # On the system pool, like the Flux controllers: the platform's own, never on a zone's nodes.
    {
      "global.nodeSelector.kubernetes\\.azure\\.com/mode" = "system"
    },
    local.system_pool_critical_addons_only ? {
      "global.tolerations[0].key"      = "CriticalAddonsOnly"
      "global.tolerations[0].operator" = "Exists"
      "global.tolerations[0].effect"   = "NoSchedule"
    } : {},
    var.dapr.settings,
  )
}

resource "azapi_resource" "dapr_extension" {
  count = var.dapr == null ? 0 : 1

  name      = "dapr"
  parent_id = module.aks.resource_id
  type      = "Microsoft.KubernetesConfiguration/extensions@${local.kubernetes_configuration_api_version}"
  body = {
    properties = merge(
      {
        extensionType           = "microsoft.dapr"
        releaseTrain            = "Stable"
        autoUpgradeMinorVersion = var.dapr.version == null
        configurationSettings   = local.dapr_settings
        scope = {
          cluster = {
            releaseNamespace = "dapr-system"
          }
        }
      },
      var.dapr.version == null ? {} : { version = var.dapr.version },
    )
  }
  # A new version, or the HA setting, cannot change on an installed extension.
  replace_triggers_external_values = {
    version           = var.dapr.version
    high_availability = var.dapr.high_availability
  }

  # One operation on a cluster at a time (see the Flux extension).
  depends_on = [module.aks, azapi_resource.flux_extension]
}
