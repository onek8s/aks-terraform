# The environment's monthly budget (cost management, OneK8s design section 3.2): what the whole
# subscription may cost in a month - the clusters, their node resource groups, everything shared -
# in the billing account's currency. Azure Cost Management mails the subscription's owners when the
# month's actual cost passes 80 % and 100 % of it, and when the forecast for the month passes 100 %,
# so a GPU node or a cell left running is noticed within a day, not on the invoice. A budget only
# reports: it stops nothing. The breakdown by team and namespace is OpenCost's, in Grafana
# (aks-fluxcd-platform, infrastructure/observability). See monthly_budget.
resource "azurerm_consumption_budget_subscription" "this" {
  count = var.monthly_budget == null ? 0 : 1

  name            = "budget-${var.environment}"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  amount          = var.monthly_budget.amount
  time_grain      = "Monthly"

  time_period {
    start_date = var.monthly_budget.start_date
  }

  dynamic "notification" {
    for_each = {
      actual-80      = { threshold = 80, type = "Actual" }
      actual-100     = { threshold = 100, type = "Actual" }
      forecasted-100 = { threshold = 100, type = "Forecasted" }
    }
    content {
      enabled        = true
      operator       = "GreaterThan"
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      contact_roles  = var.monthly_budget.contact_roles
      contact_emails = var.monthly_budget.contact_emails
    }
  }
}
