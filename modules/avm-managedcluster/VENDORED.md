# Vendored: Azure/avm-res-containerservice-managedcluster/azurerm 0.8.3

A copy of the Azure Verified Module for AKS, version 0.8.3 (registry source
`Azure/avm-res-containerservice-managedcluster/azurerm`, MIT licence - see LICENSE), with three changes:

- `network_profile.advanced_networking.performance.acceleration_mode` - ACNS eBPF host routing
  (`BpfVeth`), sent in the cluster's create request (`locals.network_profile.tf`, `variables.tf`).
  AKS refuses to turn it on for an existing cluster ("User-installed iptables rules found") even when
  the only rules are its own, so it cannot be added after creation, and the upstream module has no input
  for it.
- `security_profile.image_integrity` - AKS Image Integrity (preview), `securityProfile.imageIntegrity`
  (`locals.resource_body.tf`, `variables.tf`): the Ratify add-on that checks image signatures for the
  Azure Policy add-on (OneK8s design section 14). Only the preview cluster APIs know it; the
  configuration is on a preview API anyway, for the ingress profile (below).
- The cluster's API version when `ingress_profile.application_load_balancer` is set: upstream pins
  `2025-09-02-preview` for it (`main.tf`), which does not know
  `ingressProfile.webAppRouting.gatewayAPIImplementations.appRoutingIstio` - App Routing's Gateway
  API implementation, the GatewayClass `approuting-istio` the zones' Gateways use. The module
  already has the input (`web_app_routing.gateway_api_implementations`), but on that API version AKS
  never receives it. Patched to `2026-05-02-preview`, the newest preview the azapi provider (2.13)
  validates and one that knows the ALB setting, App Routing Istio, Image Integrity and the
  acceleration mode alike. The root module's own azapi calls use the same version (`locals.tf`,
  `aks_api_version`).

The examples, tests and docs of the upstream module are left out. Drop this copy and go back to the
registry once a release has the input.
