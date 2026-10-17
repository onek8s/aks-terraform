# The environment's Log Analytics workspace, log-<env>-platform (OneK8s design section 6.2, "Azure
# Monitor data, read in place"): the data Azure produces rather than the clusters - first the clusters'
# Kubernetes audit logs, which each cluster sends here through a diagnostic setting (its
# log_analytics_workspace_name). CIS AKS Benchmark 2.1.1. See log_analytics_workspace_name.
resource "azurerm_log_analytics_workspace" "platform" {
  count = var.log_analytics_workspace_name == null ? 0 : 1

  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = local.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_in_days
  # A cap on the ingestion, so an audit log that grows by surprise costs a known amount a day; past
  # it the workspace drops data until the next day, which the security agent sees as a gap.
  daily_quota_gb = var.log_analytics_daily_quota_gb
  # Only Entra ID: queries with workspace or resource permissions, no shared keys for the agents.
  local_authentication_enabled = false
  # Without public network access only through the landing zone's Azure Monitor Private Link scope (azure-landing-zone
  # monitor_private_link.workspace_ids names this workspace); the clusters' diagnostic settings are unaffected
  internet_ingestion_enabled = local.public_network_access
  internet_query_enabled     = local.public_network_access
}
