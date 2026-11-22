# conftest verify --policy plan-risk
package main

# AVM names the type in lower case (agentpools); the rules match either.
pool_type := "Microsoft.ContainerService/managedClusters/agentpools@2026-01-02-preview"

pool(address, actions, before, after) := {
	"address": address,
	"type": "azapi_resource",
	"change": {
		"actions": actions,
		"before": {"type": pool_type, "body": {"properties": before}},
		"after": {"type": pool_type, "body": {"properties": after}},
		"after_unknown": {},
	},
}

plan(changes) := {"resource_changes": changes}

test_localdns_on_a_pool_is_flagged if {
	p := pool("module.aks.module.nodepools[\"se2\"].azapi_resource.this[0]", ["update"], {"count": 1}, {"count": 1, "localDNSProfile": {"mode": "Disabled"}})
	count(warn) == 1 with input as plan([p])
}

test_autoscaler_bounds_on_a_pool_pass if {
	p := pool("module.aks.module.nodepools[\"se2\"].azapi_resource.this[0]", ["update"], {"maxCount": 1}, {"maxCount": 2})
	count(warn) == 0 with input as plan([p])
}

test_a_new_pool_passes if {
	p := {"address": "x", "type": "azapi_resource", "change": {"actions": ["create"], "before": null, "after": {"type": pool_type, "body": {"properties": {"osSKU": "AzureLinux"}}}, "after_unknown": {}}}
	count(warn) == 0 with input as plan([p])
}

test_a_removed_pool_is_flagged if {
	p := pool("x", ["delete"], {"osSKU": "AzureLinux"}, {})
	count(warn) == 1 with input as plan([p])
}

test_an_unknown_kubernetes_version_on_a_pool_is_flagged if {
	p := object.union(pool("x", ["update"], {"orchestratorVersion": "1.35"}, {}), {"change": {"after_unknown": {"body": {"properties": {"orchestratorVersion": true}}}}})
	count(warn) == 1 with input as plan([p])
}

test_a_cluster_network_change_is_flagged if {
	c := {"address": "module.aks.azapi_resource.this", "type": "azapi_resource", "change": {
		"actions": ["update"],
		"before": {"type": "Microsoft.ContainerService/managedClusters@2025-10-02-preview", "body": {"properties": {"networkProfile": {"outboundType": "userDefinedRouting"}}}},
		"after": {"type": "Microsoft.ContainerService/managedClusters@2025-10-02-preview", "body": {"properties": {"networkProfile": {"outboundType": "loadBalancer"}}}},
		"after_unknown": {},
	}}
	count(warn) == 1 with input as plan([c])
}

test_a_route_change_is_flagged if {
	r := {"address": "azurerm_route_table.zone[\"int-se\"]", "type": "azurerm_route_table", "change": {"actions": ["update"], "before": {"route": [{"name": "a"}]}, "after": {"route": [{"name": "b"}]}}}
	count(warn) == 1 with input as plan([r])
}

test_route_table_tags_pass if {
	r := {"address": "azurerm_route_table.cell", "type": "azurerm_route_table", "change": {"actions": ["update"], "before": {"route": [{"name": "a"}], "tags": {}}, "after": {"route": [{"name": "a"}], "tags": {"x": "y"}}}}
	count(warn) == 0 with input as plan([r])
}

test_private_endpoint_network_policies_are_flagged if {
	s := {"address": "azurerm_subnet.cell[\"system\"]", "type": "azurerm_subnet", "change": {"actions": ["update"], "before": {"private_endpoint_network_policies": "Disabled"}, "after": {"private_endpoint_network_policies": "Enabled"}}}
	count(warn) == 1 with input as plan([s])
}

test_a_replaced_kms_key_is_flagged if {
	k := {"address": "azurerm_key_vault_key.cluster[\"kms\"]", "type": "azurerm_key_vault_key", "change": {"actions": ["delete", "create"], "before": {}, "after": {}}}
	count(warn) == 1 with input as plan([k])
}

test_no_changes_pass if {
	count(warn) == 0 with input as plan([])
}
