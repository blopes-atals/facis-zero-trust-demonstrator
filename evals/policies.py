"""Classify the live network policies of one namespace (used by the eval checks).

Usage: python3 policies.py <namespace> <netpol.json> <cnp.json> <ccnp.json>
Prints one line per rule-level class and exits 0. Classes:
  default-deny, dns-bypass, intra-plane, mesh-control-plane:<dir>:<port>, matrix:<dir>,
  api-lane, entity-ingress:<port>, other:<name>
"""
import json
import sys

PLANE = "ztd.facis.io/plane"
ns, np_f, cnp_f, ccnp_f = sys.argv[1:5]
items = lambda f: json.load(open(f)).get("items", [])
out = []


def peers(rules, key):
    return [p for r in rules for p in (r.get(key) or [])]


def ports(rules):
    return sorted({p.get("port") for r in rules for p in (r.get("ports") or [])}, key=str)


for p in items(np_f):
    s, name = p["spec"], p["metadata"]["name"]
    ing, eg = s.get("ingress") or [], s.get("egress") or []
    types = set(s.get("policyTypes") or [])
    if not ing and not eg and s.get("podSelector") == {} and types == {"Ingress", "Egress"}:
        out.append("default-deny"); continue
    rules = ing + eg
    pr = peers(ing, "from") + peers(eg, "to")
    pt = ports(rules)
    if eg and not ing and pt and set(map(str, pt)) <= {"53"}:
        out.append("dns-bypass"); continue
    if pt == [15012]:
        out.append(f"mesh-control-plane:{'ingress' if ing else 'egress'}:15012"); continue
    if pr and not pt and all(x == {"podSelector": {}} for x in pr):
        out.append("intra-plane"); continue
    if pr and all((x.get("podSelector") is not None) and x.get("namespaceSelector") for x in pr):
        out.append(f"matrix:{'ingress' if ing else 'egress'}:{name}"); continue
    out.append(f"other:NetworkPolicy/{name}")

for p in items(cnp_f):
    s, name = p.get("spec") or {}, p["metadata"]["name"]
    for r in s.get("egress") or []:
        if set(r.get("toEntities") or []) == {"kube-apiserver"} and not r.get("toEndpoints"):
            out.append("api-lane")
        else:
            out.append(f"other:CNP/{name}/egress:{json.dumps(r, sort_keys=True)}")
    for r in s.get("ingress") or []:
        if r.get("fromEntities") and not r.get("fromEndpoints") and not r.get("fromCIDR"):
            for tp in r.get("toPorts") or [{}]:
                for prt in tp.get("ports") or [{"port": "*"}]:
                    out.append(f"entity-ingress:{prt.get('port')}")
        else:
            out.append(f"other:CNP/{name}/ingress:{json.dumps(r, sort_keys=True)}")
    for k in ("ingressDeny", "egressDeny"):
        if s.get(k):
            out.append(f"deny-rule:CNP/{name}/{k}")

for p in items(ccnp_f):
    out.append(f"other:CCNP/{p['metadata']['name']}")

print("\n".join(out))
