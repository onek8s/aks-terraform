#!/usr/bin/env python3
"""Azure Resource Graph check of OneK8s design section 7.1 ("Requirement and isolation tests"):
public IPs, public endpoints of PaaS / Key Vault / ACR / API servers, and local authentication
left on - none but the designed ones and the recorded lab exceptions.

    check-public-endpoints.py <subscription id> allowed-public-endpoints.yaml

Signed in with the Azure CLI. Prints one line per finding and a Markdown table to $RESULTS (the
workflow's summary); exits 1 when something is not on the allow-list.
"""
import json
import os
import re
import subprocess
import sys

import yaml

PAAS = ("microsoft.keyvault/vaults", "microsoft.containerregistry/registries", "microsoft.storage/storageaccounts",
        "microsoft.sql/servers", "microsoft.documentdb/databaseaccounts", "microsoft.servicebus/namespaces",
        "microsoft.eventhub/namespaces", "microsoft.cognitiveservices/accounts", "microsoft.web/sites",
        "microsoft.dbforpostgresql/flexibleservers", "microsoft.cache/redis")
PAAS_KQL = ", ".join(f"'{t}'" for t in PAAS)
# Also public in the sense of D60 (no public endpoints): the API servers, Log Analytics (ingestion and query), data
# collection endpoints, managed disks (export and import over a SAS URL), Private Link scopes
OTHER = ("microsoft.containerservice/managedclusters", "microsoft.operationalinsights/workspaces",
         "microsoft.insights/datacollectionendpoints", "microsoft.compute/disks",
         "microsoft.kubernetesconfiguration/privatelinkscopes")
OTHER_KQL = ", ".join(f"'{t}'" for t in OTHER)

QUERIES = {
    "public-ip": """
        Resources
        | where type =~ 'microsoft.network/publicipaddresses'
        | project type, name, resourceGroup, detail = tostring(properties.ipAddress)""",
    "public-endpoint": f"""
        Resources
        | where type in~ ({PAAS_KQL}) or type in~ ({OTHER_KQL})
        | extend access = tostring(coalesce(properties.publicNetworkAccess, properties.networkAcls.publicNetworkAccess)),
                 acl = tostring(properties.networkAcls.defaultAction),
                 ingestion = tostring(properties.publicNetworkAccessForIngestion), query = tostring(properties.publicNetworkAccessForQuery),
                 privateCluster = coalesce(tobool(properties.apiServerAccessProfile.enablePrivateCluster), false)
        | extend public = case(
            type =~ 'microsoft.containerservice/managedclusters', not(privateCluster),
            type =~ 'microsoft.operationalinsights/workspaces', not(ingestion =~ 'Disabled' and query =~ 'Disabled'),
            not(access =~ 'Disabled') and not(acl =~ 'Deny'))
        | where public
        | project type, name, resourceGroup,
                  detail = strcat('publicNetworkAccess=', access, ' defaultAction=', acl, ' ingestion=', ingestion, ' query=', query)""",
    "local-auth": f"""
        Resources
        | where (type =~ 'microsoft.containerregistry/registries' and coalesce(tobool(properties.adminUserEnabled), false))
             or (type =~ 'microsoft.containerservice/managedclusters' and not(coalesce(tobool(properties.disableLocalAccounts), false)))
             or (type =~ 'microsoft.storage/storageaccounts' and coalesce(tobool(properties.allowSharedKeyAccess), true))
             or (type =~ 'microsoft.keyvault/vaults' and not(coalesce(tobool(properties.enableRbacAuthorization), false)))
             or (type in~ ('microsoft.servicebus/namespaces', 'microsoft.eventhub/namespaces', 'microsoft.cognitiveservices/accounts',
                           'microsoft.documentdb/databaseaccounts') and not(coalesce(tobool(properties.disableLocalAuth), false)))
        | project type, name, resourceGroup, detail = ''""",
}


def graph(subscription, query):
    body = json.dumps({"subscriptions": [subscription], "query": query, "options": {"$top": 1000}})
    out = subprocess.run(
        ["az", "rest", "--method", "post", "--url",
         "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
         "--body", body], check=True, capture_output=True, text=True).stdout
    return json.loads(out)["data"]


def main():
    subscription, allow_path = sys.argv[1:3]
    allowed = yaml.safe_load(open(allow_path))["allowed"]
    results = os.environ.get("RESULTS")
    failures = 0
    rows = []
    for check, query in QUERIES.items():
        for r in graph(subscription, query):
            match = next((a for a in allowed if a["check"] == check
                          and re.fullmatch(a.get("type", ".*"), r["type"], re.I)
                          and re.fullmatch(a.get("name", ".*"), r["name"], re.I)
                          and re.fullmatch(a.get("resourceGroup", ".*"), r["resourceGroup"], re.I)), None)
            what = f"{check}: {r['type']} {r['resourceGroup']}/{r['name']} {r['detail']}".strip()
            if match:
                print(f"PASS {what} - allowed: {match['reason']}")
                rows.append(("PASS", what, match["reason"]))
            else:
                print(f"::error::FAIL {what} - not designed and not a recorded exception")
                rows.append(("FAIL", what, "not on tests/isolation/allowed-public-endpoints.yaml"))
                failures += 1
    if results:
        with open(results, "a") as f:
            for status, what, why in rows:
                f.write(f"| {status} | R1, R5, R7a | Resource Graph {what} | {why} |\n")
    print(f"{len(rows)} findings, {failures} not allowed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
