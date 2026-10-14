#!/usr/bin/env python3
"""Namespace access check of OneK8s design section 17 ("Requirement and isolation tests"), R6:
the Entra ID groups of `managed_namespaces[*].groups` (view, edit, admin) get exactly their
Kubernetes role in their own namespace and nothing anywhere else.

    check-namespace-access.py <envs/<cluster>.tfvars> <testers.yaml>

Needs a kubeconfig (KUBECONFIG) of an identity that may impersonate (the isolation tests' own).

1. Bindings: every group named in the tfvars has its RoleBinding `platform-<role>` in its namespace,
   ClusterRole `<role>`, the group as the only subject; there is no `platform-<role>` binding for a
   role that names no group, and no binding labelled `platform/namespace-access` anywhere else.
2. Kubernetes RBAC, by impersonating a member of each group (`kubectl auth can-i --as-group`): the
   matrix below in the namespace, and nothing in another namespace or on the cluster.
3. Signed in for real: for each group with a tester in <testers.yaml> - an Entra ID application
   that is a member of the group and federated with this repository's GitHub environment - a token
   for the AKS server application obtained with the workflow's OIDC token, then `kubectl auth whoami`
   (the group is among the caller's groups), the same matrix without impersonation, and one write
   as a server-side dry run. A group without a tester is reported as AUDIT.

Prints one line per check and a Markdown table to $RESULTS; exits 1 when a check failed.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

import hcl2
import yaml

REQ = "R6"
ROLES = ["view", "edit", "admin"]
# What each role may do in its own namespace: (verb, resource, view, edit, admin).
MATRIX = [
    ("get", "pods", True, True, True),
    ("list", "deployments.apps", True, True, True),
    ("get", "secrets", False, True, True),
    ("create", "configmaps", False, True, True),
    ("delete", "deployments.apps", False, True, True),
    ("create", "rolebindings.rbac.authorization.k8s.io", False, False, True),
    ("create", "roles.rbac.authorization.k8s.io", False, False, True),
    # The namespace's quota and the namespace itself come from aks-terraform, not from its admins.
    ("update", "resourcequotas", False, False, False),
]
# Never, for any role: outside the namespace, and on the cluster.
ELSEWHERE = [
    ("get", "pods", "kube-system"),
    ("get", "pods", "flux-system"),
    ("list", "secrets", "ext-fi-gateway"),
    ("create", "configmaps", "default"),
]
CLUSTER_WIDE = [
    ("list", "namespaces"),
    ("list", "nodes"),
    ("create", "clusterrolebindings.rbac.authorization.k8s.io"),
]
AKS_SERVER_APP = "6dae42f8-4368-4678-94ff-3960e28e3630"
failed = False


def result(status, check, detail=""):
    global failed
    if status == "FAIL":
        failed = True
        print(f"::error::FAIL [{REQ}] {check}{' - ' + detail if detail else ''}")
    elif status == "AUDIT":
        print(f"::notice::AUDIT [{REQ}] {check}{' - ' + detail if detail else ''}")
    else:
        print(f"{status} [{REQ}] {check}{' - ' + detail if detail else ''}")
    if os.environ.get("RESULTS"):
        with open(os.environ["RESULTS"], "a") as f:
            f.write(f"| {status} | {REQ} | {check} | {detail.replace('|', chr(92) + '|')} |\n")


def kubectl(*args, kubeconfig=None):
    env = dict(os.environ)
    if kubeconfig:
        env["KUBECONFIG"] = kubeconfig
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, env=env, timeout=60)


def can_i(verb, resource, namespace, auth, kubeconfig=None):
    args = ["auth", "can-i", verb, resource, *auth]
    if namespace:
        args += ["-n", namespace]
    out = kubectl(*args, kubeconfig=kubeconfig)
    answer = out.stdout.strip()
    if answer not in ("yes", "no"):
        raise RuntimeError(f"kubectl auth can-i {verb} {resource}: {out.stderr.strip()[:200]}")
    return answer == "yes"


def matrix(label, namespace, role, auth, kubeconfig=None):
    """The role's rights in its namespace, elsewhere and on the cluster; one row per surprise."""
    wrong, checked = [], 0
    column = 2 + ROLES.index(role)
    try:
        for row in MATRIX:
            verb, resource, expected = row[0], row[1], row[column]
            checked += 1
            if can_i(verb, resource, namespace, auth, kubeconfig) != expected:
                wrong.append(f"{verb} {resource}: {'allowed' if not expected else 'refused'}")
        for verb, resource, other in ELSEWHERE:
            if other == namespace:
                continue
            checked += 1
            if can_i(verb, resource, other, auth, kubeconfig):
                wrong.append(f"{verb} {resource} in {other}: allowed")
        for verb, resource in CLUSTER_WIDE:
            checked += 1
            if can_i(verb, resource, None, auth, kubeconfig):
                wrong.append(f"{verb} {resource} (cluster): allowed")
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        result("FAIL", f"{label}: {role} in {namespace} and nowhere else", str(e))
        return
    if wrong:
        result("FAIL", f"{label}: {role} in {namespace} and nowhere else", "; ".join(wrong))
    else:
        result("PASS", f"{label}: {role} in {namespace} and nowhere else", f"{checked} rights as expected")


def expected_groups(tfvars):
    with open(tfvars) as f:
        parsed = hcl2.load(f)
    namespaces = parsed.get("managed_namespaces", {})
    if isinstance(namespaces, list):  # python-hcl2 wraps blocks and some maps in lists
        namespaces = namespaces[0] if namespaces else {}
    groups = {}
    for name, namespace in namespaces.items():
        given = (namespace or {}).get("groups") or {}
        if isinstance(given, list):
            given = given[0] if given else {}
        # python-hcl2 8 keeps the quotes of string values and quoted keys.
        given = {key.strip('"'): str(value).strip('"') for key, value in given.items() if value is not None}
        groups[name.strip('"')] = {role: given[role].lower() for role in ROLES if given.get(role)}
    return groups


def check_bindings(groups):
    out = kubectl("get", "rolebindings", "-A", "-l", "platform/namespace-access", "-o", "json")
    if out.returncode != 0:
        result("FAIL", "role bindings of managed_namespaces[*].groups", out.stderr.strip()[:200])
        return
    found = {(b["metadata"]["namespace"], b["metadata"]["name"]): b for b in json.loads(out.stdout)["items"]}
    for namespace, roles in groups.items():
        for role in ROLES:
            binding = found.pop((namespace, f"platform-{role}"), None)
            check = f"{namespace}: RoleBinding platform-{role}"
            if role not in roles:
                if binding:
                    result("FAIL", f"{check} only with a group", "exists, but the tfvars name no group")
                continue
            if not binding:
                result("FAIL", f"{check} binds the {role} group", "missing")
                continue
            subjects = [(s.get("kind"), s.get("name")) for s in binding.get("subjects") or []]
            ref = binding["roleRef"]
            if (ref["kind"], ref["name"]) != ("ClusterRole", role) or subjects != [("Group", roles[role])]:
                result("FAIL", f"{check} binds the {role} group", f"roleRef {ref['kind']}/{ref['name']}, subjects {subjects}")
            else:
                result("PASS", f"{check} binds the {role} group", f"ClusterRole {role} to group {roles[role]}")
    for namespace, name in found:
        result("FAIL", "no namespace access binding the tfvars do not name", f"{namespace}/{name}")


def tester_kubeconfig(client_id, tenant, workdir):
    """A kubeconfig that calls the cluster with a token of the tester application, no impersonation."""
    request = urllib.request.Request(
        os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=api://AzureADTokenExchange",
        headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]},
    )
    assertion = json.load(urllib.request.urlopen(request, timeout=30))["value"]
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "grant_type": "client_credentials",
        "scope": f"{AKS_SERVER_APP}/.default",
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }).encode()
    token = json.load(urllib.request.urlopen(
        f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", data=body, timeout=30))["access_token"]
    print(f"::add-mask::{token}")
    config = yaml.safe_load(kubectl("config", "view", "--raw", "--minify").stdout)
    config["users"] = [{"name": "tester", "user": {"token": token}}]
    config["contexts"][0]["context"]["user"] = "tester"
    path = os.path.join(workdir, f"{client_id}.kubeconfig")
    with open(path, "w") as f:
        yaml.safe_dump(config, f)
    os.chmod(path, 0o600)
    return path


def check_tester(namespace, role, group, client_id, tenant, workdir):
    label = f"signed in as a member of the {role} group"
    try:
        kubeconfig = tester_kubeconfig(client_id, tenant, workdir)
    except Exception as e:  # noqa: BLE001 - any failure to sign in is the finding
        result("FAIL", f"{namespace}: tester of the {role} group signs in", str(e)[:200])
        return
    out = kubectl("auth", "whoami", "-o", "json", kubeconfig=kubeconfig)
    if out.returncode != 0:
        result("FAIL", f"{namespace}: tester of the {role} group reaches the API server", out.stderr.strip()[:200])
        return
    user = json.loads(out.stdout)["status"]["userInfo"]
    if group in [g.lower() for g in user.get("groups", [])]:
        result("PASS", f"{namespace}: the API server sees the tester in the {role} group", user.get("username", ""))
    else:
        result("FAIL", f"{namespace}: the API server sees the tester in the {role} group",
               f"{user.get('username')} has groups {user.get('groups')}")
    matrix(label, namespace, role, [], kubeconfig)
    # One real write, refused or admitted by authorization (server-side dry run: nothing is stored).
    manifest = 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: namespace-access-test}\ndata: {k: v}\n'
    write = subprocess.run(["kubectl", "create", "--dry-run=server", "-n", namespace, "-f", "-"], input=manifest,
                           capture_output=True, text=True, env={**os.environ, "KUBECONFIG": kubeconfig}, timeout=60)
    may_write = role != "view"
    admitted = write.returncode == 0
    forbidden = "forbidden" in write.stderr.lower()
    if admitted == may_write and (admitted or forbidden):
        result("PASS", f"{namespace}: {label} {'writes' if may_write else 'cannot write'} a ConfigMap (dry run)",
               "admitted" if admitted else write.stderr.strip()[:150])
    else:
        result("FAIL", f"{namespace}: {label} {'writes' if may_write else 'cannot write'} a ConfigMap (dry run)",
               (write.stdout + write.stderr).strip()[:200])


def main():
    tfvars, testers_file = sys.argv[1:3]
    groups = expected_groups(tfvars)
    with open(testers_file) as f:
        testers = (yaml.safe_load(f) or {}).get("testers") or {}
    tenant = os.environ.get("AZURE_TENANT_ID", "")
    if not any(groups.values()):
        result("AUDIT", "namespace access groups", f"{os.path.basename(tfvars)} names no managed_namespaces[*].groups")
    check_bindings(groups)
    with tempfile.TemporaryDirectory() as workdir:
        for namespace, roles in groups.items():
            for role, group in roles.items():
                auth = ["--as", "namespace-access-test", "--as-group", group, "--as-group", "system:authenticated"]
                matrix(f"a member of the {role} group (impersonated)", namespace, role, auth)
                client_id = (testers.get(namespace) or {}).get(role)
                if client_id:
                    check_tester(namespace, role, group, client_id, tenant, workdir)
                else:
                    result("AUDIT", f"{namespace}: signed in as a member of the {role} group",
                           f"no tester in {os.path.basename(testers_file)}; checked by impersonation only")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
