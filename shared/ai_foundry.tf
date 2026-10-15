# The AI agents' model endpoint (OneK8s design section 15, onek8s/aks-ai-agents `model.provider: foundry`): a
# Microsoft Foundry resource with one Claude deployment, signed in to with Entra ID only - no API key exists. The
# agents run as the environment's GitHub deployment identity (aks-terraform's agent workflows), which gets
# `Cognitive Services User` on it: the model's data plane and nothing else. See ai_foundry.
resource "azurerm_cognitive_account" "agents" {
  count = var.ai_foundry == null ? 0 : 1

  name                  = var.ai_foundry.name
  location              = var.ai_foundry.location
  resource_group_name   = local.resource_group_name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = var.ai_foundry.name
  # Entra ID only: no keys to leak. Reached on its public endpoint by the GitHub-hosted agent runners.
  local_auth_enabled            = false
  public_network_access_enabled = true
}

resource "azurerm_cognitive_deployment" "agents" {
  count = var.ai_foundry == null ? 0 : 1

  name                 = var.ai_foundry.model
  cognitive_account_id = azurerm_cognitive_account.agents[0].id

  model {
    format  = "Anthropic"
    name    = var.ai_foundry.model
    version = var.ai_foundry.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.ai_foundry.capacity
  }
}

resource "azurerm_role_assignment" "agents_model_user" {
  count = var.ai_foundry == null || !var.create_role_assignments ? 0 : 1

  scope                = azurerm_cognitive_account.agents[0].id
  role_definition_name = "Cognitive Services User"
  principal_id         = data.azurerm_client_config.current.object_id
}
