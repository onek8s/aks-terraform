# The dev environment's tenants (README, "Tenants"; design section 3.3): the catalogue's files, one per
# application namespace, deployed into every cell that holds the tenant's zone. Applied after the cells
# (Deploy, stack dev-tenants): a cell listed here must exist and run its platform Flux configuration.
location            = "germanywestcentral"
resource_group_name = "rg-aks-dev"
environment         = "dev"
catalogue_dir       = "catalogue/dev"

# The lab's one cell, with both internal zones (aks-terraform's envs/dev-int-stateless-az3.tfvars).
# dev-int-stateful is defined but never deployed: it joins here when it is built.
cells = {
  aks-dev-int-stateless-az3 = { zones = ["int-fi", "int-se"] }
}
