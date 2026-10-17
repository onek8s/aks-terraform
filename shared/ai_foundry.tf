# The AI agents' model endpoint (OneK8s design section 20, onek8s/aks-ai-agents `model.provider: foundry`): a
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
  # Entra ID only: no keys to leak. Reached through its private endpoint (private_endpoints.tf) - the agent
  # workflows join the labfw VPN - and, while private_endpoints.public_network_access allows, its public one.
  local_auth_enabled            = false
  public_network_access_enabled = local.public_network_access
  network_acls {
    default_action = local.public_network_access ? "Allow" : "Deny"
    bypass         = "AzureServices"
  }
  # A Foundry resource with projects - Azure turns it on (and adds a default project) with the first model
  # deployment attempt, and it cannot be turned off without deleting the resource
  project_management_enabled = true

  # Projects need the resource's own identity
  identity {
    type = "SystemAssigned"
  }
}

# Anthropic's models need the deploying organisation's attestation (modelProviderData: legal name, country, industry):
# the resource provider signs the Azure Marketplace offer for Claude on its behalf and sends the three fields to
# Anthropic with every request - so the deployment is made only when ai_foundry.model_provider says who that is.
# azapi: azurerm has no modelProviderData.
resource "azapi_resource" "agents_model" {
  count = var.ai_foundry == null ? 0 : var.ai_foundry.model_provider == null || !var.ai_foundry.deploy ? 0 : 1

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

# Other models on the same resource, OpenAI's format (azurerm knows it): the agents' model while Claude has no quota
# here (dev: gpt-4.1-mini, created in the portal on 2026-10-15 and imported below). aks-ai-agents model.provider
# azure-openai.
resource "azurerm_cognitive_deployment" "agents_openai" {
  for_each = var.ai_foundry == null ? {} : var.ai_foundry.openai_deployments

  name                   = each.key
  cognitive_account_id   = azurerm_cognitive_account.agents[0].id
  version_upgrade_option = "OnceNewDefaultVersionAvailable"
  rai_policy_name        = each.value.rai_policy_name

  model {
    format  = "OpenAI"
    name    = each.key
    version = each.value.version
  }

  sku {
    name     = "GlobalStandard"
    capacity = each.value.capacity
  }
}

import {
  for_each = var.ai_foundry == null ? {} : { for name, d in var.ai_foundry.openai_deployments : name => d if d.import }
  to       = azurerm_cognitive_deployment.agents_openai[each.key]
  id       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}/providers/Microsoft.CognitiveServices/accounts/${var.ai_foundry.name}/deployments/${each.key}"
}
