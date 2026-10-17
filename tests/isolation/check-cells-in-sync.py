#!/usr/bin/env python3
"""Cells-in-sync check of OneK8s design section 7.1 ("Requirement and isolation tests"), R13: every
stateless cell of an environment is built from the same IaC and the same fleet configuration -
only its name and its availability zone differ.

    check-cells-in-sync.py <environment> <aks-terraform checkout> <aks-fluxcd-platform checkout>

Compares, for every pair of cells, `envs/<env>-stateless-az<N>.tfvars` (aks-terraform) and every
file of `clusters/<env>-stateless-az<N>/` (aks-fluxcd-platform) after replacing the cell's own
name (`stateless-az<N>`) and its availability zone (`availability_zones = ["<N>"]`, "zone <N>") with
placeholders and dropping comments. Prints one line per check and a Markdown table to $RESULTS;
exits 1 when two cells differ in anything else.
"""
import difflib
import glob
import os
import re
import sys


def result(status, req, check, detail=""):
    print(f"{status} [{req}] {check}{' - ' + detail if detail else ''}")
    if os.environ.get("RESULTS"):
        with open(os.environ["RESULTS"], "a") as f:
            f.write(f"| {status} | {req} | {check} | {detail.replace('|', chr(92) + '|')} |\n")


def normalized(path, number):
    lines = []
    for line in open(path):
        line = re.sub(r"\s+#.*$", "", line.rstrip()) if not line.lstrip().startswith("#") else ""
        line = line.replace(f"stateless-az{number}", "stateless-az<N>")
        line = re.sub(r'(availability_zones\s*=\s*\[)"%s"(\])' % number, r'\1"<N>"\2', line)
        if line.strip():
            lines.append(line)
    return lines


def main():
    env, terraform, fleet = sys.argv[1:4]
    tfvars = sorted(glob.glob(f"{terraform}/envs/{env}-stateless-az*.tfvars"))
    cells = [re.search(r"stateless-az(\d+)", p).group(1) for p in tfvars]
    if len(cells) < 2:
        result("FAIL", "R13", f"{env}: at least two stateless cells defined", f"{len(cells)} in envs/")
        sys.exit(1)
    failed = 0
    first = cells[0]
    for other in cells[1:]:
        pairs = [(f"envs/{env}-stateless-az{first}.tfvars", f"{terraform}/envs/{env}-stateless-az{first}.tfvars", f"{terraform}/envs/{env}-stateless-az{other}.tfvars")]
        a_dir, b_dir = f"{fleet}/clusters/{env}-stateless-az{first}", f"{fleet}/clusters/{env}-stateless-az{other}"
        names = sorted(set(os.listdir(a_dir)) | set(os.listdir(b_dir)))
        pairs += [(f"clusters/{env}-stateless-az<N>/{n}", f"{a_dir}/{n}", f"{b_dir}/{n}") for n in names]
        for label, a, b in pairs:
            what = f"az{first} and az{other}: {label}"
            if not (os.path.exists(a) and os.path.exists(b)):
                failed += 1
                result("FAIL", "R13", f"{what} the same", f"only in {'az' + first if os.path.exists(a) else 'az' + other}")
                continue
            diff = [d for d in difflib.unified_diff(normalized(a, first), normalized(b, other), lineterm="", n=0) if d[:1] in "+-" and d[:3] not in ("+++", "---")]
            if diff:
                failed += 1
                result("FAIL", "R13", f"{what} the same", "; ".join(diff)[:300])
            else:
                result("PASS", "R13", f"{what} the same", "but the cell's name and availability zone")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
