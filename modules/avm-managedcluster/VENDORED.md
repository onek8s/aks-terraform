# Vendored: Azure/avm-res-containerservice-managedcluster/azurerm 0.8.3

A copy of the Azure Verified Module for AKS, version 0.8.3 (registry source
`Azure/avm-res-containerservice-managedcluster/azurerm`, MIT licence - see LICENSE), with one change:

- `network_profile.advanced_networking.performance.acceleration_mode` - ACNS eBPF host routing
  (`BpfVeth`), sent in the cluster's create request (`locals.network_profile.tf`, `variables.tf`).
  AKS refuses to turn it on for an existing cluster ("User-installed iptables rules found") even when
  the only rules are its own, so it cannot be added after creation, and the upstream module has no input
  for it.

The examples, tests and docs of the upstream module are left out. Drop this copy and go back to the
registry once a release has the input.
