#!/usr/bin/env bash
# Prints the name the naming policy (modules/conventions) gives one resource of a stack, for the
# workflows that need a name no variable states - the policy's defaults are the lab's names, and a
# real estate's policy comes from the NAMING_POLICY environment variable (the Deploy workflow's
# secret of the same name, see the README, "Naming policy"). The stack's variables file gives the
# region, the environment and the exposure. Needs terraform; touches no state and no cloud.
#
#   scripts/policy-name.sh shared/envs/dev.tfvars key_vault platform    # kv-onek8s-gwc-platform
set -euo pipefail

vars="$1" type="$2" name="${3:-}"
tfvar() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$vars" | head -n 1; }

module="$(cd "$(dirname "$0")/../modules/conventions" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The module has no providers: init only lets console load it.
cp "$module"/*.tf "$work/"
terraform -chdir="$work" init -backend=false -input=false >/dev/null

args=(-var "location=$(tfvar location)" -var "names={ asked = { type = \"$type\", name = \"$name\" } }")
environment="$(tfvar environment)"
[ -z "$environment" ] || args+=(-var "environment=$environment")
exposure="$(tfvar exposure)"
[ -z "$exposure" ] || args+=(-var "exposure=$exposure")
if [ -n "${NAMING_POLICY:-}" ]; then
  printf '{"naming": %s}' "$NAMING_POLICY" > "$work/naming.tfvars.json"
  args+=(-var-file="$work/naming.tfvars.json")
fi

answer="$(echo 'jsonencode([local.names.asked, local.policy_errors, local.invalid_names, local.names_without_location_code])' | terraform -chdir="$work" console "${args[@]}")"
# console prints the JSON as an HCL string
json="$(printf '%s' "$answer" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read()))')"
problems="$(printf '%s' "$json" | python3 -c 'import json, sys; n, *p = json.load(sys.stdin); print("; ".join(sum(p, [])))')"
if [ -n "$problems" ]; then
  echo "::error::The naming policy cannot name the $type ${name}: $problems" >&2
  exit 1
fi
printf '%s' "$json" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0])'
