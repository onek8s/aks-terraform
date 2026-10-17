#!/usr/bin/env python3
"""Namespace access check of OneK8s design section 7.1 ("Requirement and isolation tests"), R6:
the Entra ID groups of `managed_namespaces[*].groups` (view, edit, admin) get exactly their
Kubernetes role in their own namespace and nothing anywhere else.

    check-namespace-access.py <envs/<cluster>.tfvars> <testers.yaml> [<shared/envs/<env>.tfvars>]

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

4. Key Vault (with the shared tfvars), soft multi-tenancy: shared/ names the same groups for the
   namespace as the cell; `admin` holds exactly Key Vault Secrets Officer and `edit` exactly the
   custom role `OneK8s Key Vault Secrets Editor (<resource group>)` (D51) on the namespace's vault
   under the ABAC condition on `<namespace>--` (metadata included), `view` no Key Vault role at all
   (`az role assignment list`); and each tester, signed in with a Key Vault token, lists nothing,
   reads and writes no other namespace's secret and creates none outside the naming - `admin`
   writes, reads and reads the metadata of one of their own, by name; `edit` writes, updates and
   reads the metadata of one, but reads no value and deletes nothing.
5. Platform viewers (shared/ platform_viewer_group_object_ids): their custom role is defined and
   assignable at the environment's resource group only and held by each group there; signed in as
   the tester, they list the clusters' namespaces and nothing inside them, and list each vault's
   secret names without reading a value or writing.

Prints one line per check and a Markdown table to $RESULTS; exits 1 when a check failed.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
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
    ("list", "secrets", "int-fi-gateway"),
    ("create", "configmaps", "default"),
]
CLUSTER_WIDE = [
    ("list", "namespaces"),
    ("list", "nodes"),
    ("create", "clusterrolebindings.rbac.authorization.k8s.io"),
]
AKS_SERVER_APP = "6dae42f8-4368-4678-94ff-3960e28e3630"
VAULT_SCOPE = "https://vault.azure.net/.default"
VAULT_API = "api-version=7.4"
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
    # "yes" or "no", which with Azure RBAC comes with a reason: "no - Azure does not have opinion...".
    answer = (out.stdout.split() or [""])[0]
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


def tester_token(client_id, tenant, scope):
    """A token of the tester application for `scope`, signed in with the workflow's OIDC token."""
    request = urllib.request.Request(
        os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=api://AzureADTokenExchange",
        headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]},
    )
    assertion = json.load(urllib.request.urlopen(request, timeout=30))["value"]
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "grant_type": "client_credentials",
        "scope": scope,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }).encode()
    token = json.load(urllib.request.urlopen(
        f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", data=body, timeout=30))["access_token"]
    print(f"::add-mask::{token}")
    return token


def tester_kubeconfig(client_id, tenant, workdir):
    """A kubeconfig that calls the cluster with a token of the tester application, no impersonation."""
    token = tester_token(client_id, tenant, f"{AKS_SERVER_APP}/.default")
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


def parse(tfvars):
    with open(tfvars) as f:
        return hcl2.load(f)


def unquoted(value):
    return value.strip('"') if isinstance(value, str) else value


def shared_groups(shared_tfvars):
    """managed namespace -> {role: group} as shared/ grants them on the vault."""
    shares = parse(shared_tfvars).get("key_vault_namespaces", {})
    groups = {}
    for name, share in shares.items():
        given = (share or {}).get("groups") or {}
        given = {unquoted(k): unquoted(v).lower() for k, v in given.items() if v is not None}
        groups[unquoted(name)] = {role: given[role] for role in ROLES if given.get(role)}
    return groups


def namespace_vault(tfvars, namespace):
    parsed = parse(tfvars)
    vaults = {unquoted(k): unquoted(v) for k, v in (parsed.get("key_vault_namespace_vaults") or {}).items()}
    return vaults.get(namespace) or unquoted(parsed.get("key_vault_name"))


def az(*args):
    out = subprocess.run(["az", *args, "-o", "json"], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200])
    return json.loads(out.stdout or "null")


def check_vault_roles(namespace, roles, vault, editor):
    """Each group's Key Vault data-plane roles on the namespace's vault, under its condition (metadata
    included): `admin` exactly Secrets Officer, `edit` exactly the Secrets Editor custom role (write,
    no value - D51), `view` none at all."""
    wanted_by_role = {"admin": "Key Vault Secrets Officer", "edit": editor}
    for role, group in roles.items():
        check = f"{namespace}: the {role} group's Key Vault roles"
        try:
            assignments = az("role", "assignment", "list", "--assignee", group, "--all", "--include-inherited")
        except RuntimeError as e:
            result("FAIL", check, str(e))
            continue
        data = [a for a in assignments if "Key Vault " in (a.get("roleDefinitionName") or "")
                and a.get("roleDefinitionName") != "Key Vault Contributor"]
        problems = []
        wanted = wanted_by_role.get(role)
        if role == "view":
            problems = [f"{a['roleDefinitionName']} on {(a.get('scope') or '').rsplit('/', 1)[-1]}" for a in data]
        else:
            for a in data:
                where = (a.get("scope") or "").rsplit("/", 1)[-1]
                condition = a.get("condition") or ""
                if a["roleDefinitionName"] != wanted or where != vault:
                    problems.append(f"{a['roleDefinitionName']} on {where}")
                elif f"'{namespace}--'" not in condition or "secrets/readMetadata/action" not in condition:
                    problems.append(f"{a['roleDefinitionName']} on {where} without the condition on {namespace}-- (metadata included)")
            if not any(a["roleDefinitionName"] == wanted and (a.get("scope") or "").endswith("/" + vault) for a in data):
                problems.append(f"no {wanted} on {vault}")
        if problems:
            result("FAIL", check, "; ".join(problems))
        elif role == "view":
            result("PASS", check, "none: Kubernetes' view sees no Secret either")
        elif role == "edit":
            result("PASS", check, f"{wanted} on {vault}: write and metadata under {namespace}--, no value")
        else:
            result("PASS", check, f"{wanted} on {vault}, values and metadata under {namespace}--")


def vault_call(method, url, token, body=None):
    request = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                                     data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, {}


def check_vault_tester(namespace, role, client_id, tenant, vault, other):
    """Soft multi-tenancy in the vault, signed in as the tester: no listing for anyone; edit and admin
    write, read and read the metadata of a secret of their own, by name; nobody touches another
    namespace's secret or creates one outside the naming."""
    label = f"{namespace}: signed in as a member of the {role} group, Key Vault {vault}"
    try:
        token = tester_token(client_id, tenant, VAULT_SCOPE)
    except Exception as e:  # noqa: BLE001
        result("FAIL", f"{label}: signs in", str(e)[:200])
        return
    endpoint = f"https://{vault}.vault.azure.net"
    writes = role != "view"
    wrong = []

    def expect(what, status, wanted):
        if status != wanted:
            wrong.append(f"{what}: HTTP {status}, expected {wanted}")

    expect("list the secrets", vault_call("GET", f"{endpoint}/secrets?{VAULT_API}", token)[0], 403)
    expect("list the deleted secrets", vault_call("GET", f"{endpoint}/deletedsecrets?{VAULT_API}", token)[0], 403)
    expect(f"read {other}--isolation-test", vault_call("GET", f"{endpoint}/secrets/{other}--isolation-test?{VAULT_API}", token)[0], 403)
    expect(f"read the metadata of {other}--isolation-test",
           vault_call("GET", f"{endpoint}/secrets/{other}--isolation-test/versions?{VAULT_API}", token)[0], 403)
    run = os.environ.get("GITHUB_RUN_ID", "local")
    expect(f"write {other}--namespace-access-test",
           vault_call("PUT", f"{endpoint}/secrets/{other}--namespace-access-test?{VAULT_API}", token, {"value": "x"})[0], 403)
    expect("write namespace-access-test (no namespace's name)",
           vault_call("PUT", f"{endpoint}/secrets/namespace-access-test-{run}?{VAULT_API}", token, {"value": "x"})[0], 403)
    if role == "edit":
        # The edit role writes and updates but neither reads a value nor deletes (D51): one fixed name,
        # overwritten each run with a new version, so no secret is left behind per run.
        name = f"{namespace}--namespace-access-test-edit"
        expect(f"write {name}", vault_call("PUT", f"{endpoint}/secrets/{name}?{VAULT_API}", token, {"value": run})[0], 200)
        expect(f"update the attributes of {name}",
               vault_call("PATCH", f"{endpoint}/secrets/{name}?{VAULT_API}", token, {"contentType": "text/plain"})[0], 200)
        expect(f"read the metadata of {name}", vault_call("GET", f"{endpoint}/secrets/{name}/versions?{VAULT_API}", token)[0], 200)
        expect(f"read {name} (its value)", vault_call("GET", f"{endpoint}/secrets/{name}?{VAULT_API}", token)[0], 403)
        expect(f"delete {name}", vault_call("DELETE", f"{endpoint}/secrets/{name}?{VAULT_API}", token)[0], 403)
    else:
        name = f"{namespace}--namespace-access-test-{run}-{role}"
        status = vault_call("PUT", f"{endpoint}/secrets/{name}?{VAULT_API}", token, {"value": "x"})[0]
        expect(f"write {name}", status, 200 if writes else 403)
        expect(f"read {name}", vault_call("GET", f"{endpoint}/secrets/{name}?{VAULT_API}", token)[0], 200 if writes else 403)
        expect(f"read the metadata of {name}", vault_call("GET", f"{endpoint}/secrets/{name}/versions?{VAULT_API}", token)[0], 200 if writes else 403)
        if status == 200:
            vault_call("DELETE", f"{endpoint}/secrets/{name}?{VAULT_API}", token)
            # Soft delete keeps it for the retention period; purge it, as the role allows.
            for _ in range(10):
                purge = vault_call("DELETE", f"{endpoint}/deletedsecrets/{name}?{VAULT_API}", token)[0]
                if purge in (200, 204, 404):
                    break
                subprocess.run(["sleep", "3"])
    what = ("lists nothing, reads nothing, writes nothing" if not writes
            else f"lists nothing, writes {namespace}-- only, by name, reads no value" if role == "edit"
            else f"lists nothing, reads and writes {namespace}-- only, by name")
    if wrong:
        result("FAIL", f"{label}: {what}", "; ".join(wrong))
    else:
        result("PASS", f"{label}: {what}")


def check_platform_viewers(shared_tfvars, testers, tenant, workdir, vaults):
    """The platform viewers: the custom role at the resource group, and signed in as the tester -
    namespaces and secret names listed, nothing inside a namespace, no secret value, no write."""
    parsed = parse(shared_tfvars)
    groups = [unquoted(g).lower() for g in parsed.get("platform_viewer_group_object_ids") or []]
    if not groups:
        result("AUDIT", "platform viewers", "shared/ names no platform_viewer_group_object_ids")
        return
    group = unquoted(parsed.get("resource_group_name"))
    try:
        subscription = az("account", "show")["id"]
        scope = f"/subscriptions/{subscription}/resourceGroups/{group}"
        name = unquoted(parsed.get("platform_viewer_role_name")) or f"OneK8s Platform Viewer ({group})"
        definitions = az("role", "definition", "list", "--name", name, "--custom-role-only", "true", "--scope", scope)
        scopes = [s.lower() for d in definitions for s in d.get("assignableScopes", [])]
        if len(definitions) == 1 and scopes == [scope.lower()]:
            result("PASS", "platform viewers: custom role assignable at the resource group only", name)
        else:
            result("FAIL", "platform viewers: custom role assignable at the resource group only", f"{len(definitions)} definition(s), scopes {scopes}")
        for viewer in groups:
            assigned = [a for a in az("role", "assignment", "list", "--assignee", viewer, "--all")
                        if a.get("roleDefinitionName") == name and (a.get("scope") or "").lower() == scope.lower()]
            result("PASS" if assigned else "FAIL", f"platform viewers: group {viewer} holds the role on {group}")
    except RuntimeError as e:
        result("FAIL", "platform viewers: custom role and its assignments", str(e))
    client_id = (testers.get("platform") or {}).get("viewers")
    if not client_id:
        result("AUDIT", "platform viewers: signed in as a member", "no tester platform.viewers")
        return
    try:
        kubeconfig = tester_kubeconfig(client_id, tenant, workdir)
    except Exception as e:  # noqa: BLE001
        result("FAIL", "platform viewers: the tester signs in", str(e)[:200])
        return
    out = kubectl("auth", "whoami", "-o", "json", kubeconfig=kubeconfig)
    if out.returncode == 0 and any(g in [x.lower() for x in json.loads(out.stdout)["status"]["userInfo"].get("groups", [])] for g in groups):
        result("PASS", "platform viewers: the API server sees the tester in the group")
    else:
        result("FAIL", "platform viewers: the API server sees the tester in the group", (out.stdout + out.stderr).strip()[:200])
    names = kubectl("get", "namespaces", "-o", "name", kubeconfig=kubeconfig)
    listed = [n.split("/", 1)[-1] for n in names.stdout.split()]
    wrong = [] if names.returncode == 0 and "kube-system" in listed else [f"list namespaces: {names.stderr.strip()[:150]}"]
    try:
        for verb, resource, namespace in [("get", "pods", "int-fi-example"), ("list", "secrets", "int-fi-example"),
                                          ("list", "configmaps", "kube-system"), ("create", "configmaps", "default")]:
            if can_i(verb, resource, namespace, [], kubeconfig):
                wrong.append(f"{verb} {resource} in {namespace}: allowed")
        if can_i("delete", "namespaces", None, [], kubeconfig):
            wrong.append("delete namespaces: allowed")
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        wrong.append(str(e))
    result("FAIL" if wrong else "PASS", "platform viewers: list namespaces and nothing inside them",
           "; ".join(wrong) if wrong else f"{len(listed)} namespaces")
    try:
        token = tester_token(client_id, tenant, VAULT_SCOPE)
    except Exception as e:  # noqa: BLE001
        result("FAIL", "platform viewers: Key Vault sign-in", str(e)[:200])
        return
    for vault in sorted(set(vaults.values())):
        endpoint = f"https://{vault}.vault.azure.net"
        status, listing = vault_call("GET", f"{endpoint}/secrets?{VAULT_API}", token)
        secrets = [i["id"].rsplit("/", 1)[-1] for i in listing.get("value", [])]
        wrong = [] if status == 200 and secrets else [f"list: HTTP {status}, {len(secrets)} secret(s)"]
        if secrets:
            got = vault_call("GET", f"{endpoint}/secrets/{secrets[0]}?{VAULT_API}", token)[0]
            if got != 403:
                wrong.append(f"read {secrets[0]}: HTTP {got}")
        put = vault_call("PUT", f"{endpoint}/secrets/platform-viewer-test?{VAULT_API}", token, {"value": "x"})[0]
        if put != 403:
            wrong.append(f"write platform-viewer-test: HTTP {put}")
        result("FAIL" if wrong else "PASS", f"platform viewers: list the secrets of {vault}, no value, no write",
               "; ".join(wrong) if wrong else f"{len(secrets)} names listed")


def main():
    tfvars, testers_file = sys.argv[1:3]
    shared_tfvars = sys.argv[3] if len(sys.argv) > 3 else None
    groups = expected_groups(tfvars)
    with open(testers_file) as f:
        testers = (yaml.safe_load(f) or {}).get("testers") or {}
    tenant = os.environ.get("AZURE_TENANT_ID", "")
    if not any(groups.values()):
        result("AUDIT", "namespace access groups", f"{os.path.basename(tfvars)} names no managed_namespaces[*].groups")
    check_bindings(groups)
    vaults = {}
    if shared_tfvars:
        in_shared = shared_groups(shared_tfvars)
        parsed = parse(shared_tfvars)
        editor = (unquoted(parsed.get("key_vault_secrets_editor_role_name"))
                  or f"OneK8s Key Vault Secrets Editor ({unquoted(parsed.get('resource_group_name'))})")
        for namespace, roles in groups.items():
            if not roles:
                continue
            if in_shared.get(namespace) != roles:
                result("FAIL", f"{namespace}: shared/ grants the same groups on the vault",
                       f"cell {roles}, shared {in_shared.get(namespace)}")
            else:
                result("PASS", f"{namespace}: shared/ grants the same groups on the vault", ", ".join(sorted(roles)))
            vaults[namespace] = namespace_vault(tfvars, namespace)
            check_vault_roles(namespace, roles, vaults[namespace], editor)
    with tempfile.TemporaryDirectory() as workdir:
        for namespace, roles in groups.items():
            for role, group in roles.items():
                auth = ["--as", "namespace-access-test", "--as-group", group, "--as-group", "system:authenticated"]
                matrix(f"a member of the {role} group (impersonated)", namespace, role, auth)
                client_id = (testers.get(namespace) or {}).get(role)
                if client_id:
                    check_tester(namespace, role, group, client_id, tenant, workdir)
                    if namespace in vaults:
                        # Another application of the same zone: its secrets' names in the same vault.
                        other = f"{namespace.split('-')[0]}-{namespace.split('-')[1]}-other"
                        check_vault_tester(namespace, role, client_id, tenant, vaults[namespace], other)
                else:
                    result("AUDIT", f"{namespace}: signed in as a member of the {role} group",
                           f"no tester in {os.path.basename(testers_file)}; checked by impersonation only")
        if shared_tfvars:
            check_platform_viewers(shared_tfvars, testers, tenant, workdir, vaults)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
