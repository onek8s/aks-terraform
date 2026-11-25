# High-risk changes in a Terraform plan (`terraform show -json tfplan`), checked by Deploy before an
# apply. A finding is a `warn`: Deploy lists it in the run's summary and stops the apply unless the run
# sets `accept_risk`. Each rule names a change whose plan line looks harmless (an in-place update) but
# which AKS or the network turns into an outage or a node rollover - the cases the lab met:
#
#   - #229: LocalDNS stated on every pool was an in-place update in the plan; AKS reimaged every node.
#   - #216: a route table policy on snet-system took the system node down within a minute (#217).
#
# The messages name resources and properties only, never values: the plan JSON holds secrets in clear
# and the Deploy log is public. Rules are tested by `conftest verify` (risk_test.rego) in the PR workflow.
package main

# Agent pool properties AKS applies by replacing, reimaging or upgrading every node of the pool.
node_rolling_pool_properties := {
	"enableEncryptionAtHost",
	"enableFIPS",
	"gpuProfile",
	"kubeletConfig",
	"linuxOSConfig",
	"localDNSProfile",
	"messageOfTheDay",
	"nodeImageVersion",
	"orchestratorVersion",
	"osDiskSizeGB",
	"osDiskType",
	"osSKU",
	"securityProfile",
	"vmSize",
}

# Cluster properties whose change reaches every node or the API server's reachability.
cluster_properties := {
	"apiServerAccessProfile",
	"kubernetesVersion",
	"networkProfile",
}

azapi_types := {"azapi_resource", "azapi_update_resource"}

arm_type(change, prefix) if {
	azapi_types[change.type]
	some state in [change.change.before, change.change.after]
	is_object(state)
	startswith(lower(object.get(state, "type", "")), lower(prefix))
}

is_pool(change) if arm_type(change, "Microsoft.ContainerService/managedClusters/agentPools@")

is_cluster(change) if arm_type(change, "Microsoft.ContainerService/managedClusters@")

updated(change) if change.change.actions == ["update"]

deleted(change) if "delete" in change.change.actions

properties(state) := object.get(object.get(state, "body", {}), "properties", {}) if is_object(state)

# A property changed when it differs between the states; an unknown value counts when it was set.
property_changed(change, name) if {
	before := properties(change.change.before)
	after := properties(change.change.after)
	object.get(before, name, null) != object.get(after, name, null)
	not after_unknown(change, name)
}

property_changed(change, name) if {
	after_unknown(change, name)
	object.get(properties(change.change.before), name, null) != null
}

after_unknown(change, name) if change.change.after_unknown.body.properties[name] == true

warn contains msg if {
	some change in input.resource_changes
	is_pool(change)
	updated(change)
	some name in node_rolling_pool_properties
	property_changed(change, name)
	msg := sprintf("%s: node pool property %s changes - AKS replaces, reimages or upgrades every node of the pool (#229)", [change.address, name])
}

warn contains msg if {
	some change in input.resource_changes
	is_pool(change)
	deleted(change)
	msg := sprintf("%s: the node pool is deleted or replaced - AKS drains and removes its nodes", [change.address])
}

warn contains msg if {
	some change in input.resource_changes
	is_cluster(change)
	deleted(change)
	msg := sprintf("%s: the cluster is deleted or replaced", [change.address])
}

warn contains msg if {
	some change in input.resource_changes
	is_cluster(change)
	updated(change)
	some name in cluster_properties
	property_changed(change, name)
	msg := sprintf("%s: cluster property %s changes - it reaches every node or the API server's reachability", [change.address, name])
}

warn contains msg if {
	some change in input.resource_changes
	change.type == "azurerm_route_table"
	updated(change)
	change.change.before.route != change.change.after.route
	msg := sprintf("%s: the routes change - every flow of the subnets it serves, the hub firewall's path included (#216)", [change.address])
}

network_types := {"azurerm_route_table", "azurerm_subnet_route_table_association", "azurerm_subnet", "azurerm_virtual_network", "azurerm_virtual_network_peering"}

warn contains msg if {
	some change in input.resource_changes
	network_types[change.type]
	deleted(change)
	msg := sprintf("%s: deleted or replaced - the nodes behind it lose their network path while it is gone", [change.address])
}

warn contains msg if {
	some change in input.resource_changes
	change.type == "azurerm_subnet"
	updated(change)
	change.change.before.private_endpoint_network_policies != change.change.after.private_endpoint_network_policies
	msg := sprintf("%s: private_endpoint_network_policies changes - a private endpoint's answers then follow the route table (the outage of #216, reverted in #217)", [change.address])
}

warn contains msg if {
	some change in input.resource_changes
	change.type == "azurerm_key_vault_key"
	deleted(change)
	msg := sprintf("%s: the key is deleted or replaced - what it encrypts (KMS data, node disks) cannot be read with the new one", [change.address])
}

is_namespace(change) if arm_type(change, "Microsoft.ContainerService/managedClusters/managedNamespaces@")

# A tenant's managed namespace deleted (tenants/): with deletePolicy Delete, AKS deletes the Kubernetes
# namespace and everything the team runs in it. A tenant leaving the state on purpose is forgotten
# (`removed`), which is no delete.
warn contains msg if {
	some change in input.resource_changes
	is_namespace(change)
	deleted(change)
	msg := sprintf("%s: the managed namespace is deleted or replaced - with deletePolicy Delete, AKS deletes the team's namespace and what runs in it", [change.address])
}
