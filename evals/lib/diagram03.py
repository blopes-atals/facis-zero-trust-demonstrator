"""Shared helpers for the plane-separation-design and staleness-windows checks.

Parses the Mermaid source of diagram 03 and the tables / prose of ARCHITECTURE section 6.
Everything here reads files; nothing writes outside EVAL_TMP.
"""
import os
import re
import sys

ROOT = os.environ.get("EVAL_ROOT", os.getcwd())
MMD = os.path.join(ROOT, "docs/diagrams/03-trust-boundaries.mmd")
SVG = os.path.join(ROOT, "docs/diagrams/03-trust-boundaries.svg")
ARCH = os.path.join(ROOT, "docs/architecture.md")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def norm(s):
    return re.sub(r"\s+", " ", s.replace("<br/>", " ").replace("<br>", " ")).strip()


# ---------------------------------------------------------------- Mermaid

NODE_RE = re.compile(r'([A-Za-z_][\w]*)\s*(\[\s*"(.*?)"\s*\]|\(\(\s*"?(.*?)"?\s*\)\)|\[(.*?)\])')
EDGE_RE = re.compile(
    r'^\s*([A-Za-z_]\w*)(?:\s*(?:\[.*?\]|\(\(.*?\)\)))?\s*'
    r'(-\.->|==>|-->)\s*(?:\|"?(.*?)"?\|)?\s*'
    r'([A-Za-z_]\w*)'
)


class Diagram:
    def __init__(self, text):
        self.text = text
        self.nodes = {}        # id -> label
        self.parent = {}       # node id -> innermost subgraph id (None = top level)
        self.subgraphs = {}    # id -> label
        self.edges = []        # (src, kind, label, dst)
        stack = []
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("%%"):
                continue
            m = re.match(r'subgraph\s+([A-Za-z_]\w*)\s*(?:\[\s*"(.*?)"\s*\])?', line)
            if m:
                self.subgraphs[m.group(1)] = norm(m.group(2) or m.group(1))
                stack.append(m.group(1))
                continue
            if line == "end":
                if stack:
                    stack.pop()
                continue
            if re.match(r"(flowchart|graph|direction|classDef|class|style|linkStyle)\b", line):
                continue
            e = EDGE_RE.match(line)
            # node declarations (also inline in edges)
            for nm in NODE_RE.finditer(line):
                nid = nm.group(1)
                label = nm.group(3) or nm.group(4) or nm.group(5) or nid
                if nid not in self.nodes or self.nodes[nid] == nid:
                    self.nodes[nid] = norm(label)
                    self.parent.setdefault(nid, stack[-1] if stack else None)
            if e:
                src, kind, label, dst = e.group(1), e.group(2), norm(e.group(3) or ""), e.group(4)
                for nid in (src, dst):
                    self.nodes.setdefault(nid, nid)
                    self.parent.setdefault(nid, stack[-1] if stack else None)
                self.edges.append((src, kind, label, dst))

    def trust_domains(self):
        return [s for s, l in self.subgraphs.items() if "spiffe trust domain" in l.lower()]

    def in_domain(self, nid):
        return self.parent.get(nid) in self.trust_domains()

    def nodes_in(self, sg):
        return [n for n, p in self.parent.items() if p == sg]

    def data_plane(self, sg):
        return [n for n in self.nodes_in(sg) if self.nodes[n].lower().startswith("data plane")]

    def mgmt_plane(self, sg):
        return [n for n in self.nodes_in(sg) if self.nodes[n].lower().startswith("management plane")]

    def unplaced(self):
        return [n for n, l in self.nodes.items()
                if not self.in_domain(n) and "management plane" in l.lower()
                and "placement not yet recorded" in l.lower()]

    def all_labels(self):
        return list(self.nodes.values()) + list(self.subgraphs.values()) + [e[2] for e in self.edges]


def diagram():
    return Diagram(read(MMD))


# ---------------------------------------------------------------- architecture.md

def section(md, heading_prefix):
    """Text under the first '### <prefix>' heading up to the next heading."""
    lines = md.splitlines()
    out, on = [], False
    for l in lines:
        if re.match(r"#{1,6}\s", l):
            if on:
                break
            if re.match(r"#{1,6}\s+" + re.escape(heading_prefix), l):
                on = True
                continue
        if on:
            out.append(l)
    return "\n".join(out)


def first_table(text):
    rows = [l for l in text.splitlines() if l.strip().startswith("|")]
    if len(rows) < 2:
        return [], []
    split = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    return split(rows[0]), [split(r) for r in rows[2:]]


def prose_before_table(text):
    out = []
    for l in text.splitlines():
        if l.strip().startswith("|"):
            break
        out.append(l)
    return norm("\n".join(out))


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.;:])\s+(?=[A-Z])", norm(text)) if s.strip()]


def die(msg, code=1):
    print(msg)
    sys.exit(code)


# ---------------------------------------------------------------- feature files

def feature_scenarios():
    """[(path, feature_name, feature_tags, scenario_name, scenario_tags)] from features/**/*.feature."""
    import glob
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, "features", "**", "*.feature"), recursive=True)):
        ftags, pending, fname = [], [], None
        for l in read(path).splitlines():
            s = l.strip()
            if s.startswith("@"):
                pending += re.findall(r"@[\w-]+", s)
            elif re.match(r"Feature:", s):
                fname, ftags, pending = s[8:].strip(), pending, []
            elif re.match(r"(Scenario|Scenario Outline|Example):", s):
                out.append((path, fname, ftags, s.split(":", 1)[1].strip(), pending))
                pending = []
            elif re.match(r"(Background|Rule):", s):
                pending = []
    return out


def staleness_rows():
    _, rows = first_table(section(read(ARCH), "Staleness matrix"))
    return [(r[0], re.findall(r"@[\w-]+", r[-1])) for r in rows]
