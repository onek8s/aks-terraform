#!/usr/bin/env bash
# Installs Notation and its Azure Key Vault plugin, and trusts the platform's image signing certificate
# (shared/: image_signing) - by its subject, the way each cluster's Ratify does - so that `notation
# verify` checks a signature exactly as admission would, and `notation sign` can sign with the key in
# the vault. For the Sign images and Isolation tests workflows, after `azure/login`.
#
#   .github/scripts/notation-setup.sh <vault> <certificate> <registry>
#
# Puts `notation` on the PATH of the later steps, logs Notation in to <registry> as the Azure CLI's
# identity, and exports NOTATION_KEY_ID (the certificate's key, for signing) and
# NOTATION_SUBJECT through GITHUB_ENV.
set -euo pipefail
vault=$1 certificate=$2 registry=$3

# Pinned with their published checksums.
NOTATION_VERSION=1.3.2
NOTATION_SHA256=e1a0f060308086bf8020b2d31defb7c5348f133ca0dba6a1a7820ef3cbb6dfe5
AZURE_KV_PLUGIN_VERSION=1.2.1
AZURE_KV_PLUGIN_SHA256=67c5ccaaf28dd44d2b6572684d84e344a02c2258af1d65ead3910b3156d3eaf5

dir="${RUNNER_TEMP:-$(mktemp -d)}/notation"
mkdir -p "$dir/bin"
curl -sSfLo "$dir/notation.tar.gz" "https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_amd64.tar.gz"
echo "${NOTATION_SHA256}  $dir/notation.tar.gz" | sha256sum -c -
tar xzf "$dir/notation.tar.gz" -C "$dir/bin" notation
notation="$dir/bin/notation"
curl -sSfLo "$dir/azure-kv.tar.gz" "https://github.com/Azure/notation-azure-kv/releases/download/v${AZURE_KV_PLUGIN_VERSION}/notation-azure-kv_${AZURE_KV_PLUGIN_VERSION}_linux_amd64.tar.gz"
"$notation" plugin install --force --file "$dir/azure-kv.tar.gz" --sha256sum "$AZURE_KV_PLUGIN_SHA256"

az keyvault certificate download --vault-name "$vault" -n "$certificate" -e PEM -f "$dir/platform.pem"
subject="$(openssl x509 -in "$dir/platform.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
echo "Trusting $subject, valid until $(openssl x509 -in "$dir/platform.pem" -noout -enddate | cut -d= -f2)"
"$notation" cert delete --type ca --store platform --all --yes >/dev/null 2>&1 || true
"$notation" cert add --type ca --store platform "$dir/platform.pem"
jq -n --arg subject "$subject" '{
  version: "1.0",
  trustPolicies: [{
    name: "platform",
    registryScopes: ["*"],
    signatureVerification: {level: "strict"},
    trustStores: ["ca:platform"],
    trustedIdentities: ["x509.subject: \($subject)"]
  }]
}' > "$dir/trustpolicy.json"
"$notation" policy import --force "$dir/trustpolicy.json"

az acr login -n "$registry" --expose-token --query accessToken -o tsv \
  | "$notation" login -u 00000000-0000-0000-0000-000000000000 --password-stdin "$registry.azurecr.io"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "$dir/bin" >> "$GITHUB_PATH"
  echo "NOTATION_KEY_ID=$(az keyvault certificate show --vault-name "$vault" -n "$certificate" --query kid -o tsv)" >> "$GITHUB_ENV"
  echo "NOTATION_SUBJECT=$subject" >> "$GITHUB_ENV"
fi
