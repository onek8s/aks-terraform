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

# Anthropic's models need the deploying organisation's attestation (modelProviderData: legal name, country, industry):
# the resource provider signs the Azure Marketplace offer for Claude on its behalf and sends the three fields to
# Anthropic with every request - so the deployment is made only when ai_foundry.model_provider says who that is.
# azapi: azurerm has no modelProviderData.
resource "azapi_resource" "agents_model" {
  count = var.ai_foundry == null ? 0 : var.ai_foundry.model_provider == null ? 0 : 1

  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name      = var.ai_foundry.model
  parent_id = azurerm_cognitive_account.agents[0].id
  # The provider's embedded schema predates modelProviderData
  schema_validation_enabled = false

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.ai_foundry.capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = var.ai_foundry.model
        version = var.ai_foundry.model_version
      }
      modelProviderData = {
        organizationName = var.ai_foundry.model_provider.organization_name
        countryCode      = var.ai_foundry.model_provider.country_code
        industry         = var.ai_foundry.model_provider.industry
      }
    }
  }
}

resource "azurerm_role_assignment" "agents_model_user" {
  count = var.ai_foundry == null || !var.create_role_assignments ? 0 : 1

  scope                = azurerm_cognitive_account.agents[0].id
  role_definition_name = "Cognitive Services User"
  principal_id         = data.azurerm_client_config.current.object_id
}
