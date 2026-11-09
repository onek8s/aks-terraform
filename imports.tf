# One-off, 2026-11-09: the lab's first apply of the zone pools' generations (#235) timed out while AKS
# created them one at a time, so some of the new pools exist in Azure but not in the state. Taken out
# again with the next change of the lab's pools; an import of a pool already in the state does nothing.
import {
  for_each = var.name == "aks-dev-int-stateless-az3" ? toset([
    "fi1", "fi1spot", "fi1arm", "fi1armspot", "se1", "se1spot", "se1arm", "se1armspot",
  ]) : toset([])

  to = module.aks.module.nodepools[each.key].azapi_resource.this[0]
  id = "${data.azurerm_resource_group.this.id}/providers/Microsoft.ContainerService/managedClusters/${var.name}/agentPools/${each.key}"
}
