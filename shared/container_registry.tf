# The environment's container registry: the images the clusters run - see container_registry_name.
# Every cluster of the environment pulls from it as its kubelet identity, granted by the cluster
# configuration, so nothing secret is kept for it anywhere. It is part of the clusters' estate here,
# not of the landing zone.
#
# Basic: a prototype's few images. Admin user off - only Entra ID identities reach it.
resource "azurerm_container_registry" "this" {
  count = var.container_registry_name == null ? 0 : 1

  name                = var.container_registry_name
  location            = var.location
  resource_group_name = local.resource_group_name
  sku                 = "Basic"
  admin_enabled       = false
}

# Nothing pushes to the registry from outside: it builds the images itself, with an ACR task each,
# from the apps' public repositories at a pinned commit - aks-hello from github.com/onek8s/aks-hello.
# No app repository holds a credential for Azure, and nothing is published anywhere else. A release
# of an image is a new entry in container_registry_builds; the registry builds it on the next apply.
# A task runs again only when it changes, so a published tag is built once.
resource "azurerm_container_registry_task" "build" {
  for_each = var.container_registry_name == null ? {} : var.container_registry_builds

  # Task names take letters, digits, hyphens and underscores: aks-hello:0.2.0 is aks-hello-0_2_0.
  name                  = replace(replace(replace(each.key, "/", "-"), ":", "-"), ".", "_")
  container_registry_id = azurerm_container_registry.this[0].id

  # The task always runs on its own amd64 host: an arm64 task would run the build under emulation,
  # where the .NET compiler crashes. An arm64 image comes from a Dockerfile that cross-compiles on
  # that host (`dockerfile` of the build, e.g. aks-hello's Dockerfile.arm64); `architecture` only
  # says which nodes the image is for.
  platform {
    os           = "Linux"
    architecture = "amd64"
  }

  docker_step {
    dockerfile_path = each.value.dockerfile
    # <repository>#<commit>[:<folder>]: the source the registry reads, anonymously.
    context_path         = "${each.value.repository}#${each.value.commit}${each.value.folder == null ? "" : ":${each.value.folder}"}"
    context_access_token = "-" # required by the provider; a public repository is read without one
    image_names          = [each.key]
    push_enabled         = true
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*$", each.key))
      error_message = "${each.key} is not an image name with a tag, such as aks-hello:0.2.0."
    }
  }
}

resource "azurerm_container_registry_task_schedule_run_now" "build" {
  for_each = azurerm_container_registry_task.build

  container_registry_task_id = each.value.id

  lifecycle {
    replace_triggered_by = [azurerm_container_registry_task.build[each.key]]
  }
}
