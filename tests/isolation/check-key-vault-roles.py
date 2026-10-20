#!/usr/bin/env python3
"""Key Vault role check of OneK8s requirements 0.3 ("Requirement and isolation tests"), R10 / R9:
an application reads Key Vault only through its namespace's share, never with an identity of its own.

    check-key-vault-roles.py <resource group> <zone> [<zone>...]

Every user-assigned identity of the resource group that a cluster federates with a service account
in an application namespace of the zones (`<zone>-<app>`) is checked:

  - the namespace's `key-vault` service account (what External Secrets Operator reads as): its only
    Key Vault data-plane role is `Key Vault Secrets User`, each under an ABAC condition on the
    namespace's prefix `<namespace>--`;
  - any other service account (an application's own workload identity): no Key Vault data-plane
    role at all, at any scope.

The role assignments are every one the identity holds, inherited ones included (`az role
assignment list --all --include-inherited`), so roles given at the vault, its resource group, the
subscription or a management group are all seen. A reader with no Secrets User at all fails too:
the check must have found the share it is about. Signed in with the Azure CLI. Prints one line per
check and a Markdown table to $RESULTS (the workflow's summary); exits 1 on a finding.
"""
import json
import os
import re
import subprocess
import sys

# Roles that act on the vault's data plane (secrets, keys, certificates). Key Vault Contributor is
# control plane only on an RBAC vault.
DATA_ROLE = re.compile(r"^Key Vault (?!Contributor$)")
READER_SERVICE_ACCOUNT = "key-vault"


def az(*args):
    return json.loads(subprocess.run(["az", *args, "-o", "json"], check=True, capture_output=True, text=True).stdout)


def result(status, req, check, detail=""):
    print(f"{status} [{req}] {check}{' - ' + detail if detail else ''}")
    if os.environ.get("RESULTS"):
        with open(os.environ["RESULTS"], "a") as f:
            f.write(f"| {status} | {req} | {check} | {detail.replace('|', chr(92) + '|')} |\n")


def main():
    group, zones = sys.argv[1], sys.argv[2:]
    application = re.compile(r"^system:serviceaccount:((?:%s)-[a-z0-9-]+):([a-z0-9.-]+)$" % "|".join(map(re.escape, zones)))
    platform = {f"{zone}-{suffix}" for zone in zones for suffix in ("gateway", "secrets")}

    failed = checked = 0
    for identity in az("identity", "list", "-g", group):
        subjects = [c["subject"] for c in az("identity", "federated-credential", "list", "-g", group, "--identity-name", identity["name"])]
        accounts = {(m.group(1), m.group(2)) for m in map(application.match, subjects) if m and m.group(1) not in platform}
        if not accounts:
            continue
        checked += 1
        assignments = az("role", "assignment", "list", "--assignee", identity["principalId"], "--all", "--include-inherited")
        roles = [{"role": a.get("roleDefinitionName") or "", "scope": a.get("scope") or "", "condition": a.get("condition") or ""}
                 for a in assignments if DATA_ROLE.match(a.get("roleDefinitionName") or "")]
        names = ", ".join(f"{ns}:{sa}" for ns, sa in sorted(accounts))
        problems = []
        for ns, sa in sorted(accounts):
            for a in roles:
                if sa != READER_SERVICE_ACCOUNT:
                    problems.append(f"{a['role']} on {a['scope'].rsplit('/', 1)[-1]} (an application identity)")
                elif a["role"] != "Key Vault Secrets User":
                    problems.append(f"{a['role']} on {a['scope'].rsplit('/', 1)[-1]} (only Secrets User)")
                elif f"'{ns}--'" not in a["condition"] and f"\"{ns}--\"" not in a["condition"]:
                    problems.append(f"{a['role']} on {a['scope'].rsplit('/', 1)[-1]} without the ABAC condition on {ns}--")
        reader = all(sa == READER_SERVICE_ACCOUNT for _, sa in accounts)
        if reader and not roles:
            problems.append("no Key Vault Secrets User at all - not the namespace's share")
        what = f"{'namespace reader' if reader else 'application identity'} {identity['name']} ({names})"
        if problems:
            failed += 1
            result("FAIL", "R9, R10", f"{what}: Key Vault roles", "; ".join(sorted(set(problems)))[:300])
        elif reader:
            result("PASS", "R9, R10", f"{what}: Key Vault roles", f"{len(roles)} Secrets User, each under its prefix")
        else:
            result("PASS", "R9", f"{what}: no Key Vault data-plane role")
    if checked == 0:
        result("FAIL", "R9", "identities federated with application namespaces", f"none found in {group}")
        failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
