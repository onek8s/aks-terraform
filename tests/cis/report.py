#!/usr/bin/env python3
"""CIS Azure Kubernetes Service (AKS) Benchmark report of OneK8s design sections 14 and 17: one row per
CIS recommendation, from three sources gathered by the CIS benchmark workflow into one directory.

    report.py <results directory> accepted.yaml

  - kube-bench-<node>.json: kube-bench (`--benchmark aks-1.8 --targets node --json`) on every node -
    section 3, the worker nodes' files and kubelet;
  - kubescape.json: Kubescape's `cis-aks-t1.8.0` framework against the API server - section 4,
    RBAC, service accounts, pod security, network policies, secrets, namespaces;
  - aks.json, diagnostic-settings.json, defender.json, registry.json, kubelet-registry-roles.json,
    gateways.json: the cluster's Azure settings, read here - sections 2 and 5, which neither tool
    can see from inside the cluster.

A recommendation fails when any source fails it (any node, any object). A failure is accepted when
accepted.yaml lists it with a reason - for every failing object, if the entry names them - and only
then: an accepted failure still counts against the score. Prints one line per recommendation, a
Markdown summary to $GITHUB_STEP_SUMMARY and results.json beside the inputs; exits 1 when a failure is
not accepted.
"""
import glob
import json
import os
import re
import sys

import yaml

RANK = {"FAIL": 4, "PASS": 3, "WARN": 2, "MANUAL": 1}


def load(directory, name, default=None):
    path = os.path.join(directory, name)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return default
    with open(path) as f:
        return json.load(f)


class Report:
    def __init__(self):
        self.rows = {}

    def add(self, cis, title, status, source, objects=(), detail=""):
        row = self.rows.setdefault(cis, {"id": cis, "title": title, "status": "MANUAL", "sources": [],
                                         "failing": [], "detail": []})
        if not row["title"]:
            row["title"] = title
        if RANK[status] > RANK[row["status"]]:
            row["status"] = status
        if source not in row["sources"]:
            row["sources"].append(source)
        if status == "FAIL":
            row["failing"] += [o for o in objects if o not in row["failing"]]
        if detail and detail not in row["detail"]:
            row["detail"].append(detail)


def kube_bench(report, directory):
    for path in sorted(glob.glob(os.path.join(directory, "kube-bench-*.json"))):
        node = os.path.basename(path)[len("kube-bench-"):-len(".json")]
        try:
            with open(path) as f:
                data = json.load(f)
        except ValueError:
            print(f"::warning::{path}: no kube-bench results")
            continue
        for control in data.get("Controls", []):
            for group in control.get("tests", []):
                for test in group.get("results", []):
                    status = {"PASS": "PASS", "FAIL": "FAIL", "WARN": "WARN"}.get(test.get("status"), "MANUAL")
                    title = re.sub(r"\s*\((Automated|Manual)\)\s*$", "", test.get("test_desc", "").strip())
                    detail = f"{node}: {test.get('actual_value', '')}".strip() if status == "FAIL" else ""
                    report.add(test["test_number"], title, status, "kube-bench", [f"node/{node}"], detail[:200])


def kubescape(report, directory):
    data = load(directory, "kubescape.json")
    if not data:
        return
    failing = {}
    for result in data.get("results", []):
        for control in result.get("controls", []):
            if control.get("status", {}).get("status") == "failed":
                failing.setdefault(control["controlID"], []).append(result["resourceID"])
    for control_id, control in data.get("summaryDetails", {}).get("controls", {}).items():
        match = re.match(r"CIS-([\d.]+)\s+(.*)", control.get("name", ""))
        if not match:
            continue
        cis, title = match.groups()
        # Section 3 is kube-bench's: without a host scanner Kubescape has no node data, and its
        # numbering of the kubelet checks differs from the benchmark kube-bench implements.
        # 5.4.5 is judged on the Gateways' listeners (azure() below): Kubescape's control fails every
        # Service, ClusterIP ones included, that lacks an Azure load balancer TLS annotation, while
        # TLS ends at the Gateways here.
        if cis.startswith("3.") or cis == "5.4.5":
            continue
        status = {"passed": "PASS", "failed": "FAIL"}.get(control.get("status"), "MANUAL")
        info = control.get("statusInfo", {}).get("info", "")
        # Passed because nothing in the cluster is of the kind the control looks at: no evidence.
        if control.get("statusInfo", {}).get("subStatus") == "irrelevant":
            status, info = "MANUAL", "no object the control applies to"
        report.add(cis, title, status, f"kubescape {control_id}", sorted(failing.get(control_id, [])),
                   info if status != "PASS" else "")


def azure(report, directory):
    aks = load(directory, "aks.json")
    if not aks:
        return
    p = aks.get("properties", {})
    access = p.get("apiServerAccessProfile") or {}
    security = p.get("securityProfile") or {}
    aad = p.get("aadProfile") or {}
    cluster = f"managedCluster/{aks.get('name')}"

    def check(cis, title, ok, detail, objects=(cluster,)):
        report.add(cis, title, "PASS" if ok else "FAIL", "azure", list(objects), detail)

    settings = load(directory, "diagnostic-settings.json", [])
    audit = [s["name"] for s in settings
             for log in (s.get("properties", s).get("logs") or [])
             if log.get("enabled") and log.get("category") in ("kube-audit", "kube-audit-admin")]
    check("2.1.1", "Enable audit Logs", bool(audit),
          f"diagnostic settings with kube-audit(-admin): {', '.join(audit) or 'none'}")

    defender = load(directory, "defender.json", {}) or {}
    tier = defender.get("pricingTier") or defender.get("properties", {}).get("pricingTier")
    sensor = (security.get("defender") or {}).get("securityMonitoring", {}).get("enabled")
    check("5.1.1", "Ensure Image Vulnerability Scanning using Microsoft Defender for Cloud (MDC) image scanning or a third party provider",
          tier == "Standard", f"Defender for Containers plan: {tier or 'unknown'}, sensor on the cluster: {bool(sensor)}")

    registry = load(directory, "registry.json")
    if registry:
        rp = registry.get("properties", registry)
        admin = rp.get("adminUserEnabled")
        anonymous = rp.get("anonymousPullEnabled")
        check("5.1.2", "Minimize user access to Azure Container Registry (ACR)", not admin and not anonymous,
              f"admin user {'on' if admin else 'off'}, anonymous pull {'on' if anonymous else 'off'}",
              [f"registry/{registry.get('name')}"])
    roles = load(directory, "kubelet-registry-roles.json")
    if roles is not None:
        names = sorted({r.get("roleDefinitionName") for r in roles})
        check("5.1.3", "Minimize cluster access to read-only for Azure Container Registry (ACR)", names == ["AcrPull"],
              f"kubelet identity on the registry: {', '.join(names) or 'none'}")

    check("5.2.2", "Use Azure RBAC for Kubernetes Authorization",
          bool(aad.get("enableAzureRBAC")) and bool(p.get("disableLocalAccounts")),
          f"Azure RBAC {aad.get('enableAzureRBAC')}, local accounts disabled {p.get('disableLocalAccounts')}")
    kms = (security.get("azureKeyVaultKms") or {})
    check("5.3.1", "Ensure Kubernetes Secrets are encrypted", bool(kms.get("enabled")),
          f"KMS {kms.get('enabled')}, key vault network access {kms.get('keyVaultNetworkAccess')}")
    ranges = access.get("authorizedIPRanges") or []
    private = bool(access.get("enablePrivateCluster"))
    check("5.4.1", "Restrict Access to the Control Plane Endpoint",
          private or (ranges and "0.0.0.0/0" not in ranges),
          f"private {private}, authorized ranges {', '.join(ranges) or 'none (any address)'}")
    check("5.4.2", "Ensure clusters are created with Private Endpoint Enabled and Public Access Disabled",
          private and not access.get("enablePrivateClusterPublicFQDN"), f"private cluster {private}")
    public_nodes = [a["name"] for a in p.get("agentPoolProfiles", []) if a.get("enableNodePublicIP")]
    check("5.4.3", "Ensure clusters are created with Private Nodes", not public_nodes,
          f"pools with node public IPs: {', '.join(public_nodes) or 'none'}")
    net = p.get("networkProfile") or {}
    check("5.4.4", "Ensure Network Policy is Enabled and set as appropriate",
          net.get("networkPolicy") in ("cilium", "azure", "calico"), f"network policy {net.get('networkPolicy')}")
    check("5.5.1", "Manage Kubernetes RBAC users with Azure AD", bool(aad.get("managed")),
          f"Entra ID integration {aad.get('managed')}")

    gateways = load(directory, "gateways.json")
    if gateways is not None:
        plain = [f"gateway/{g['metadata']['namespace']}/{g['metadata']['name']}:{l['name']}"
                 for g in gateways.get("items", []) for l in g["spec"].get("listeners", [])
                 if l.get("protocol") not in ("HTTPS", "TLS")]
        report.add("5.4.5", "Encrypt traffic to HTTPS load balancers with TLS certificates",
                   "FAIL" if plain else "PASS", "azure", plain,
                   f"{len(gateways.get('items', []))} Gateways, listeners without TLS: {len(plain)}")


def accepted_objects(entries, row):
    """The failing objects of a row that accepted.yaml does not cover."""
    reasons = []
    left = []
    for obj in row["failing"] or ["*"]:
        hit = next((e for e in entries if str(e["id"]) == row["id"]
                    and re.fullmatch(e.get("objects", ".*"), obj, re.IGNORECASE)), None)
        if hit:
            if hit["reason"] not in reasons:
                reasons.append(hit["reason"])
        else:
            left.append(obj)
    return left, reasons


def main():
    directory, accepted_file = sys.argv[1], sys.argv[2]
    with open(accepted_file) as f:
        entries = (yaml.safe_load(f) or {}).get("accepted", [])
    report = Report()
    kube_bench(report, directory)
    kubescape(report, directory)
    azure(report, directory)

    key = lambda r: [int(x) for x in r["id"].split(".")]
    rows = sorted(report.rows.values(), key=key)
    unaccepted = 0
    for row in rows:
        row["reason"] = ""
        if row["status"] == "FAIL":
            left, reasons = accepted_objects(entries, row)
            row["reason"] = "; ".join(reasons)
            if left:
                unaccepted += 1
                row["unaccepted"] = left
            else:
                row["status"] = "ACCEPTED"
    stale = [e for e in entries if not any(r["id"] == str(e["id"]) and r["status"] == "ACCEPTED" for r in rows)]

    counts = {s: sum(r["status"] == s for r in rows) for s in ("PASS", "FAIL", "ACCEPTED", "WARN", "MANUAL")}
    automated = counts["PASS"] + counts["FAIL"] + counts["ACCEPTED"]
    score = 100 * counts["PASS"] / automated if automated else 0
    for row in rows:
        failing = row.get("unaccepted") or row["failing"]
        print(f"{row['status']:8} {row['id']:7} {row['title']} [{', '.join(row['sources'])}]"
              + (f" - {'; '.join(row['detail'])}"[:400] if row["detail"] else "")
              + (f" - failing: {', '.join(failing[:10])}{' ...' if len(failing) > 10 else ''}" if failing else "")
              + (f" - accepted: {row['reason']}" if row["reason"] else ""))
        if row["status"] == "FAIL":
            print(f"::error::CIS {row['id']} {row['title']}: {', '.join(failing[:10])}")
        if row["failing"] and row["status"] in ("FAIL", "ACCEPTED"):
            print(f"::group::{row['id']}: {len(row['failing'])} failing objects")
            print("\n".join(row["failing"]))
            print("::endgroup::")
    for e in stale:
        print(f"::warning::accepted.yaml: {e['id']} ({e.get('objects', 'all')}) no longer fails - remove it")
    print(f"\nScore {score:.0f} % ({counts['PASS']} of {automated} automated recommendations pass), "
          f"{counts['ACCEPTED']} accepted, {counts['FAIL']} failed, {counts['WARN']} warn, {counts['MANUAL']} manual")

    with open(os.path.join(directory, "results.json"), "w") as f:
        json.dump({"score": round(score, 1), "counts": counts, "rows": rows}, f, indent=2)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        cell = lambda s: str(s).replace("|", "\\|").replace("\n", " ")
        with open(summary, "a") as f:
            f.write(f"### CIS AKS Benchmark - {os.environ.get('CLUSTER', '')}\n\n"
                    f"**Score {score:.0f} %**: {counts['PASS']} of {automated} automated recommendations pass; "
                    f"{counts['ACCEPTED']} failures accepted (tests/cis/accepted.yaml), {counts['FAIL']} not accepted, "
                    f"{counts['WARN']} warn, {counts['MANUAL']} manual.\n\n"
                    "| Result | CIS | Recommendation | Source | Detail |\n|---|---|---|---|---|\n")
            for row in rows:
                failing = row.get("unaccepted") or row["failing"]
                detail = "; ".join(row["detail"])[:300]
                if failing:
                    detail += f" failing: {', '.join(failing[:8])}{' ...' if len(failing) > 8 else ''}"
                if row["reason"]:
                    detail += f" accepted: {row['reason']}"
                f.write(f"| {row['status']} | {row['id']} | {cell(row['title'])} | {cell(', '.join(row['sources']))} | {cell(detail)} |\n")
    return 1 if unaccepted else 0


if __name__ == "__main__":
    sys.exit(main())
