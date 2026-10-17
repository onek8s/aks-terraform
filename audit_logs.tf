# The cluster's Kubernetes audit log, in the environment's Log Analytics workspace (OneK8s design
# section 21, CIS AKS Benchmark 2.1.1) - created by shared/ and looked up here. See
# log_analytics_workspace_name.
data "azurerm_log_analytics_workspace" "platform" {
  count = var.log_analytics_workspace_name == null ? 0 : 1

  name                = var.log_analytics_workspace_name
  resource_group_name = coalesce(var.log_analytics_workspace_resource_group_name, var.resource_group_name)
}

resource "azurerm_monitor_diagnostic_setting" "audit" {
  count = var.log_analytics_workspace_name == null ? 0 : 1

  name                       = "audit-to-${var.log_analytics_workspace_name}"
  target_resource_id         = module.aks.resource_id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform[0].id
  # Resource-specific tables (AKSAuditAdmin, AKSControlPlane), not AzureDiagnostics.
  log_analytics_destination_type = "Dedicated"

  # Every request that changes something, by whom - without the get, list and watch calls of
  # `kube-audit`, which would multiply the volume for little. And `guard`: the Entra ID and Azure
  # RBAC decisions, who was let in or refused.
  dynamic "enabled_log" {
    for_each = toset(var.audit_log_categories)
    content {
      category = enabled_log.value
    }
  }
}
