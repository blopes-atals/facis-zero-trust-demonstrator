"""Helper for the registration-inventory checks (not a check itself).

Runs the comparison step of section "registration-inventory" of verify.sh against a synthetic
cluster snapshot (entries, namespaces, pods, nodes, certificates read), no cluster involved.
"""
import json, os, re, subprocess, sys, tempfile

ROOT = os.environ.get("EVAL_ROOT") or subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
VERIFY = os.path.join(ROOT, "scripts/verify-mesh-identity/verify.sh")
TD = "ztd.test"
PLANE, IDENT = "ztd.facis.io/plane", "spiffe.io/spire-managed-identity"
NODE_UID = "node-uid-1"


def extract():
    src = open(VERIFY).read()
    m = re.search(r'python3 - "\$inv" "\$TD"[^\n]*<<\'PY\'\n(.*?)\nPY\n', src, re.S)
    if not m:
        print("cannot locate the registration-inventory comparison in verify.sh"); sys.exit(1)
    return m.group(1)


class Zone:
    def __init__(self):
        self.ns = {}; self.pods = []; self.entries = []; self.certs = []; self.fixtures = []

    def namespace(self, name, plane=True, inject=True):
        labels = {}
        if plane: labels[PLANE] = "data"
        if inject: labels["istio-injection"] = "enabled"
        self.ns[name] = labels

    def pod(self, ns, name, sa="app", uid=None, labelled=True, phase="Running"):
        uid = uid or f"uid-{ns}-{name}"
        labels = {IDENT: "true"} if labelled else {}
        self.pods.append({"metadata": {"namespace": ns, "name": name, "uid": uid, "labels": labels},
                          "spec": {"serviceAccountName": sa, "nodeName": "n1", "containers": [{"name": "app", "image": "x"}]},
                          "status": {"phase": phase}})
        return uid

    def entry(self, path, uid=None, parent=None, selectors=None):
        sel = selectors if selectors is not None else ([{"type": "k8s", "value": f"pod-uid:{uid}"}] if uid else [])
        self.entries.append({"spiffe_id": {"trust_domain": TD, "path": path},
                             "parent_id": {"trust_domain": TD, "path": parent or f"/spire/agent/k8s_psat/c/{NODE_UID}"},
                             "selectors": sel})

    def cert(self, ns, pod, uri, reader="proxy", chains=True):
        self.certs.append((ns, pod, reader, uri, "CN=SPIRE", "1" if chains else "0"))

    def run(self):
        d = tempfile.mkdtemp(dir=os.environ.get("EVAL_TMP"))
        json.dump({"entries": self.entries}, open(f"{d}/entries.json", "w"))
        json.dump({"items": [{"metadata": {"name": n, "labels": l}} for n, l in self.ns.items()]}, open(f"{d}/namespaces.json", "w"))
        json.dump({"items": self.pods}, open(f"{d}/pods.json", "w"))
        json.dump({"items": [{"metadata": {"name": "n1", "uid": NODE_UID}}]}, open(f"{d}/nodes.json", "w"))
        open(f"{d}/fixtures.txt", "w").write("\n".join(self.fixtures) + "\n")
        open(f"{d}/certs.tsv", "w").write("".join("\t".join(c) + "\n" for c in self.certs))
        script = os.path.join(d, "cmp.py"); open(script, "w").write(extract())
        r = subprocess.run([sys.executable, script, d, TD], capture_output=True, text=True)
        if r.returncode != 0:
            print("comparison step crashed:", r.stderr[-800:]); sys.exit(1)
        checks = json.load(open(f"{d}/checks.json"))
        return r.stdout, checks


def show(report, checks):
    print(report)
    for c in checks:
        print(("ok   " if c["ok"] else "FAIL ") + c["title"] + " | " + c["detail"])


def failed(checks):
    return [c for c in checks if not c["ok"]]


def row(report, needle):
    return [l for l in report.splitlines() if needle in l and l.startswith("|")]


def expect(cond, msg):
    if not cond:
        print("EXPECTATION FAILED:", msg); sys.exit(1)
