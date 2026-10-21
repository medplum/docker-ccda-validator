#!/usr/bin/env python3
"""Turn scanner findings into dependency bumps, and summarize what is left.

Subcommands:

  pin-java    Read Trivy and/or Amazon Inspector findings for jars in the WAR and
              raise each vulnerable artifact to its fixed version in the
              validator's pom.xml.
  pin-tomcat  Raise TOMCAT_VERSION in the Dockerfile when the Tomcat jars in the
              image carry a fixed finding.
  report      Write report.md and summary.json from the final scans.

Only the standard library is used, so this runs on a bare CI runner and on
macOS without a virtualenv.

How a Java fix is applied, in order of precedence (this mirrors how Maven
itself resolves a version, so the edit lands where it actually takes effect):

  1. An explicit, non-import <dependencyManagement> entry for the artifact:
     raise its version.
  2. A direct <dependency> declaring a version: raise it, or the property it
     reads.
  3. An imported BOM that lists the artifact (jackson-bom, log4j-bom,
     spring-framework-bom, ...): raise the BOM, so the whole family moves
     together instead of leaving jackson-core and jackson-databind on
     different patch levels. Only done when the BOM is published at that exact
     version and lists the artifact; otherwise fall through.
  4. Otherwise it is transitive: add an explicit <dependencyManagement> pin.
     Explicit entries win over imported BOMs and over every transitive path,
     which is how log4j-bom cleared CVE-2026-49844 on both of its paths.

The fixed version chosen is the lowest one that clears every finding on that
artifact, within the installed major version. A fix that exists only in a new
major (Spring 6 -> 7, say) is reported for a human instead of applied, unless
--allow-major is passed: those are migrations, not bumps.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

MAVEN_CENTRAL = "https://repo1.maven.org/maven2"
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
PIN_MARKER = "Pinned by docker-ccda-validator scripts/vulnfix.py"

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

_QUALIFIERS = {
    "alpha": -5, "a": -5, "beta": -4, "b": -4, "milestone": -3, "m": -3,
    "rc": -2, "cr": -2, "snapshot": -1, "ga": 0, "final": 0, "release": 0, "sp": 1,
}


def vkey(version):
    """Sort key approximating Maven's ComparableVersion for real-world versions."""
    tokens = re.findall(r"\d+|[A-Za-z]+", version)
    nums = []
    i = 0
    while i < len(tokens) and tokens[i].isdigit():
        nums.append(int(tokens[i]))
        i += 1
    while nums and nums[-1] == 0:  # 2.20 == 2.20.0
        nums.pop()
    rest = tokens[i:]
    qualifier = _QUALIFIERS.get(rest[0].lower(), 0.5) if rest else 0
    tail = [int(t) for t in rest[1:] if t.isdigit()]
    return (nums, qualifier, tail)


def major(version):
    m = re.match(r"\d+", version)
    return m.group(0) if m else version


def parse_fixed(fixed):
    """'2.18.11, 2.21.7, 2.22.3' -> ['2.18.11', '2.21.7', '2.22.3']."""
    if not fixed or fixed.strip().lower() in ("notavailable", "none", "-"):
        return []
    return [v.strip() for v in re.split(r"[,\s]+", fixed) if v.strip()]


def pick_fix(installed, fixed_versions, allow_major):
    """Lowest fixed version above the installed one, preferring the same major."""
    newer = sorted((v for v in fixed_versions if vkey(v) > vkey(installed)), key=vkey)
    same_major = [v for v in newer if major(v) == major(installed)]
    if same_major:
        return same_major[0], None
    if newer:
        if allow_major:
            return newer[0], None
        return None, f"fixed only in a new major version ({', '.join(newer)})"
    return None, "no fixed version published"


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

def load_trivy(path):
    """Yield normalized findings from a Trivy JSON report."""
    data = json.loads(Path(path).read_text())
    for result in data.get("Results") or []:
        cls = result.get("Class", "")
        for v in result.get("Vulnerabilities") or []:
            yield {
                "source": "trivy",
                "class": "os" if cls == "os-pkgs" else "lang",
                "type": result.get("Type", ""),
                "pkg": v.get("PkgName", ""),
                "installed": v.get("InstalledVersion", ""),
                "fixed": parse_fixed(v.get("FixedVersion", "")),
                "id": v.get("VulnerabilityID", ""),
                "severity": (v.get("Severity") or "UNKNOWN").upper(),
                "path": v.get("PkgPath", "") or result.get("Target", ""),
                "status": v.get("Status", ""),
            }


def load_inspector(path):
    """Yield normalized findings from `aws inspector2 list-findings` output.

    This is the scanner Vanta reads, so feeding it in means the automation acts
    on the same list the SLA is measured against, not only on Trivy's view.
    """
    data = json.loads(Path(path).read_text())
    for f in data.get("findings") or []:
        details = f.get("packageVulnerabilityDetails") or {}
        for p in details.get("vulnerablePackages") or []:
            yield {
                "source": "inspector",
                "class": "lang" if p.get("packageManager") in ("JAR", "GRADLE", "POM") else "os",
                "type": (p.get("packageManager") or "").lower(),
                "pkg": p.get("name", ""),
                "installed": p.get("version", ""),
                "fixed": parse_fixed(p.get("fixedInVersion", "")),
                "id": details.get("vulnerabilityId", ""),
                "severity": (f.get("severity") or "UNKNOWN").upper(),
                "path": p.get("filePath", ""),
                "status": f.get("status", ""),
            }


def load_findings(trivy_paths, inspector_paths):
    findings = []
    for p in trivy_paths or []:
        findings.extend(load_trivy(p))
    for p in inspector_paths or []:
        findings.extend(load_inspector(p))
    return findings


def at_or_above(severity, threshold):
    return SEVERITIES.index(severity) <= SEVERITIES.index(threshold) if severity in SEVERITIES else False


def min_severity(severities_csv):
    wanted = [s.strip().upper() for s in severities_csv.split(",") if s.strip()]
    return max(wanted, key=SEVERITIES.index)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

_http_cache = {}


def http_get(url):
    if url not in _http_cache:
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                _http_cache[url] = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            _http_cache[url] = None
    return _http_cache[url]


def central_pom(group, artifact, version, repo=MAVEN_CENTRAL):
    return http_get(f"{repo}/{group.replace('.', '/')}/{artifact}/{version}/{artifact}-{version}.pom")


# ---------------------------------------------------------------------------
# pom.xml editing
#
# Edits are textual so comments, ordering and indentation survive untouched;
# a parse-and-reserialize would rewrite the whole file and bury the one-line
# change in noise.
# ---------------------------------------------------------------------------

DEP_RE = re.compile(r"<dependency>.*?</dependency>", re.S)


def _tag(block, name):
    m = re.search(rf"<{name}>\s*([^<]*?)\s*</{name}>", block)
    return m.group(1) if m else None


def _span(text, open_tag, close_tag, start=0):
    i = text.find(open_tag, start)
    if i < 0:
        return None
    j = text.find(close_tag, i)
    return (i, j + len(close_tag)) if j >= 0 else None


def _inside(pos, spans):
    return any(a <= pos < b for a, b in spans if a is not None)


class Pom:
    def __init__(self, path):
        self.path = Path(path)
        self.text = self.path.read_text()

    def save(self):
        self.path.write_text(self.text)

    def _layout(self):
        t = self.text
        dm = _span(t, "<dependencyManagement>", "</dependencyManagement>")
        excluded = [dm] if dm else []
        for tag in ("build", "profiles", "reporting"):
            s = _span(t, f"<{tag}>", f"</{tag}>")
            if s:
                excluded.append(s)
        direct = None
        pos = 0
        while True:
            s = _span(t, "<dependencies>", "</dependencies>", pos)
            if not s:
                break
            if not _inside(s[0], excluded):
                direct = s
                break
            pos = s[0] + 1
        return dm, direct

    def _blocks(self, span):
        if not span:
            return []
        a, b = span
        return [(a + m.start(), a + m.end(), m.group(0)) for m in DEP_RE.finditer(self.text[a:b])]

    def managed(self):
        dm, _ = self._layout()
        return self._blocks(dm)

    def direct(self):
        _, direct = self._layout()
        return self._blocks(direct)

    def property(self, name):
        props = _span(self.text, "<properties>", "</properties>")
        if not props:
            return None
        m = re.search(rf"<{re.escape(name)}>\s*([^<]*?)\s*</{re.escape(name)}>", self.text[props[0]:props[1]])
        return m.group(1) if m else None

    def resolve(self, raw):
        m = re.fullmatch(r"\$\{([^}]+)\}", raw or "")
        return self.property(m.group(1)) if m else raw

    def set_version(self, block_start, block_end, block, new_version):
        """Raise a block's version, editing the property instead when it reads one."""
        raw = _tag(block, "version")
        m = re.fullmatch(r"\$\{([^}]+)\}", raw or "")
        if m:
            name = m.group(1)
            props = _span(self.text, "<properties>", "</properties>")
            a, b = props
            seg = self.text[a:b]
            seg2, n = re.subn(rf"(<{re.escape(name)}>)\s*[^<]*?\s*(</{re.escape(name)}>)",
                              rf"\g<1>{new_version}\g<2>", seg, count=1)
            if n != 1:
                raise RuntimeError(f"property {name} not found in <properties>")
            self.text = self.text[:a] + seg2 + self.text[b:]
            return f"property `{name}`"
        new_block = re.sub(r"(<version>)\s*[^<]*?\s*(</version>)", rf"\g<1>{new_version}\g<2>", block, count=1)
        self.text = self.text[:block_start] + new_block + self.text[block_end:]
        return "version literal"

    def add_managed(self, group, artifact, version, reason):
        dm, _ = self._layout()
        if not dm:
            raise RuntimeError("pom.xml has no <dependencyManagement>; add one before pinning")
        inner = _span(self.text, "<dependencies>", "</dependencies>", dm[0])
        close = inner[1] - len("</dependencies>")
        blocks = self.managed()
        if blocks:
            line_start = self.text.rfind("\n", 0, blocks[0][0]) + 1
            indent = self.text[line_start:blocks[0][0]]
        else:
            indent = " " * 12
        step = "    " if indent.endswith("    ") else "\t"
        entry = (
            f"{indent}<!-- {PIN_MARKER}: {reason} -->\n"
            f"{indent}<dependency>\n"
            f"{indent}{step}<groupId>{group}</groupId>\n"
            f"{indent}{step}<artifactId>{artifact}</artifactId>\n"
            f"{indent}{step}<version>{version}</version>\n"
            f"{indent}</dependency>\n"
        )
        # Insert before the indentation that precedes </dependencies>.
        line_start = self.text.rfind("\n", 0, close) + 1
        self.text = self.text[:line_start] + entry + self.text[line_start:]


def find_block(blocks, group, artifact, imports=False):
    for start, end, block in blocks:
        is_import = _tag(block, "scope") == "import"
        if is_import != imports:
            continue
        if _tag(block, "groupId") == group and _tag(block, "artifactId") == artifact:
            return start, end, block
    return None


def covering_bom(pom, group, artifact, target):
    """An imported BOM in this pom that would manage group:artifact at `target`."""
    for start, end, block in pom.managed():
        if _tag(block, "scope") != "import":
            continue
        bg, ba = _tag(block, "groupId"), _tag(block, "artifactId")
        if not (group == bg or group.startswith(bg + ".")):
            continue
        text = central_pom(bg, ba, target)
        if text and f"<artifactId>{artifact}</artifactId>" in text:
            return (start, end, block, bg, ba)
    return None


# ---------------------------------------------------------------------------
# pin-java
# ---------------------------------------------------------------------------

def cmd_pin_java(args):
    threshold = min_severity(args.severity)
    findings = [f for f in load_findings(args.trivy, args.inspector)
                if f["class"] == "lang" and ":" in f["pkg"] and at_or_above(f["severity"], threshold)]
    if args.path_prefix:
        findings = [f for f in findings if not f["path"] or any(p in f["path"] for p in args.path_prefix)]

    # One decision per artifact: the lowest version that clears all of its findings.
    by_artifact = {}
    for f in findings:
        by_artifact.setdefault(f["pkg"], []).append(f)

    pom = Pom(args.pom)
    changes, skipped = [], []
    bom_targets = {}  # (bom group, bom artifact) -> (target, block, [artifact entries])

    for pkg, fs in sorted(by_artifact.items()):
        group, artifact = pkg.split(":", 1)
        installed = max((f["installed"] for f in fs), key=vkey)
        ids = sorted({f["id"] for f in fs})
        needed, reasons = [], []
        for f in fs:
            fix, why = pick_fix(f["installed"], f["fixed"], args.allow_major)
            if fix:
                needed.append(fix)
            else:
                reasons.append(f"{f['id']}: {why}")
        if reasons:
            skipped.append({"artifact": pkg, "installed": installed, "ids": ids, "reason": "; ".join(sorted(set(reasons)))})
            if not needed:
                continue
        target = max(needed, key=vkey)
        if not central_pom(group, artifact, target):
            skipped.append({"artifact": pkg, "installed": installed, "ids": ids,
                            "reason": f"{target} is not on Maven Central"})
            continue

        hit = find_block(pom.managed(), group, artifact)
        if hit:
            current = pom.resolve(_tag(hit[2], "version"))
            if current and vkey(current) >= vkey(target):
                skipped.append({"artifact": pkg, "installed": installed, "ids": ids,
                                "reason": f"already managed at {current}; the build is not picking it up (shaded copy?)"})
                continue
            how = pom.set_version(*hit, target)
            changes.append({"artifact": pkg, "from": installed, "to": target, "how": f"dependencyManagement {how}", "ids": ids})
            continue

        hit = find_block(pom.direct(), group, artifact)
        if hit and _tag(hit[2], "version"):
            current = pom.resolve(_tag(hit[2], "version"))
            if current and vkey(current) >= vkey(target):
                skipped.append({"artifact": pkg, "installed": installed, "ids": ids,
                                "reason": f"declared at {current}; the build is not picking it up (shaded copy?)"})
                continue
            how = pom.set_version(*hit, target)
            changes.append({"artifact": pkg, "from": installed, "to": target, "how": f"direct dependency {how}", "ids": ids})
            continue

        bom = covering_bom(pom, group, artifact, target)
        if bom:
            start, end, block, bg, ba = bom
            key = (bg, ba)
            prev = bom_targets.get(key)
            entry = {"artifact": pkg, "from": installed, "to": target, "ids": ids}
            if prev:
                prev[2].append(entry)
                if vkey(target) > vkey(prev[0]):
                    bom_targets[key] = (target, prev[1], prev[2])
            else:
                bom_targets[key] = (target, block, [entry])
            continue

        pom.add_managed(group, artifact, target, ", ".join(ids))
        changes.append({"artifact": pkg, "from": installed, "to": target, "how": "new dependencyManagement pin", "ids": ids})

    # BOM bumps go last so one family member's lower fix cannot undercut another's.
    for (bg, ba), (target, _, entries) in bom_targets.items():
        hit = find_block(pom.managed(), bg, ba, imports=True)
        current = pom.resolve(_tag(hit[2], "version"))
        if current and vkey(current) >= vkey(target):
            for e in entries:
                skipped.append({"artifact": e["artifact"], "installed": e["from"], "ids": e["ids"],
                                "reason": f"{ba} already at {current}; the build is not picking it up"})
            continue
        how = pom.set_version(*hit, target)
        for e in entries:
            e["to"] = target
            e["how"] = f"{ba} {current} -> {target} ({how})"
            changes.append(e)

    if changes and not args.dry_run:
        pom.save()

    out = {"changes": changes, "skipped": skipped}
    if args.output:
        prior = json.loads(Path(args.output).read_text()) if Path(args.output).exists() else {"changes": [], "skipped": []}
        # Accumulate across rounds; later rounds' skips supersede earlier ones.
        prior["changes"].extend(changes)
        prior["skipped"] = skipped
        Path(args.output).write_text(json.dumps(prior, indent=2))
    for c in changes:
        print(f"pinned {c['artifact']} {c['from']} -> {c['to']} via {c['how']} ({', '.join(c['ids'])})")
    for s in skipped:
        print(f"left   {s['artifact']} {s['installed']}: {s['reason']} ({', '.join(s['ids'])})")
    print(f"{len(changes)} change(s)")
    return 0


# ---------------------------------------------------------------------------
# pin-tomcat
# ---------------------------------------------------------------------------

def tomcat_tag_exists(version, flavor):
    url = f"https://hub.docker.com/v2/repositories/library/tomcat/tags/{version}-{flavor}"
    try:
        return http_get(url) is not None
    except urllib.error.HTTPError:
        return False


def cmd_pin_tomcat(args):
    threshold = min_severity(args.severity)
    dockerfile = Path(args.dockerfile)
    text = dockerfile.read_text()
    m = re.search(r"^ARG TOMCAT_VERSION=(\S+)$", text, re.M)
    if not m:
        print("no ARG TOMCAT_VERSION in Dockerfile")
        return 0
    current = m.group(1)
    flavor_m = re.search(r"FROM tomcat:\$\{TOMCAT_VERSION\}-(\S+)", text)
    flavor = flavor_m.group(1) if flavor_m else "jdk17-temurin"

    needed, ids = [], set()
    for f in load_findings(args.trivy, args.inspector):
        if f["class"] != "lang" or not at_or_above(f["severity"], threshold):
            continue
        if not f["pkg"].startswith("org.apache.tomcat") or "usr/local/tomcat" not in f["path"]:
            continue
        fix, why = pick_fix(f["installed"], f["fixed"], allow_major=False)
        if fix:
            needed.append(fix)
            ids.add(f["id"])
        else:
            print(f"left   {f['pkg']} {f['installed']}: {why} ({f['id']})")
    if not needed:
        print("Tomcat: nothing to do")
        return 0
    target = max(needed, key=vkey)
    if vkey(target) <= vkey(current):
        print(f"Tomcat: already at {current}")
        return 0
    if not tomcat_tag_exists(target, flavor):
        print(f"Tomcat: tomcat:{target}-{flavor} is not published yet; leaving {current}")
        return 0
    dockerfile.write_text(text.replace(m.group(0), f"ARG TOMCAT_VERSION={target}", 1))
    if args.output:
        Path(args.output).write_text(json.dumps({"from": current, "to": target, "ids": sorted(ids)}, indent=2))
    print(f"Tomcat: {current} -> {target} ({', '.join(sorted(ids))})")
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _unique(findings):
    seen, out = set(), []
    for f in findings:
        k = (f["pkg"], f["installed"], f["id"])
        if k not in seen:
            seen.add(k)
            out.append(f)
    return out


def _counts(findings):
    c = {"os_fixable": 0, "os_unfixed": 0, "lang_fixable": 0, "lang_unfixed": 0}
    for f in findings:
        c[f"{f['class']}_{'fixable' if f['fixed'] else 'unfixed'}"] += 1
    c["total"] = len(findings)
    return c


def _ok(flag):
    return {"true": "✅ passed", "false": "❌ failed", "skipped": "⏭️ skipped"}.get(str(flag).lower(), str(flag))


def cmd_report(args):
    threshold = min_severity(args.severity)

    def scoped(paths, inspector=()):
        return _unique(sorted(
            (f for f in load_findings(paths, inspector) if at_or_above(f["severity"], threshold)),
            key=lambda f: (SEVERITIES.index(f["severity"]), f["pkg"], f["id"])))

    after = scoped(args.image_scan)
    before = scoped(args.baseline_scan, args.baseline_inspector) if (args.baseline_scan or args.baseline_inspector) else None
    pins = json.loads(Path(args.pins).read_text()) if args.pins and Path(args.pins).exists() else {"changes": [], "skipped": []}
    tomcat = json.loads(Path(args.tomcat).read_text()) if args.tomcat and Path(args.tomcat).exists() else None

    after_keys = {(f["pkg"], f["id"]) for f in after}
    resolved = [f for f in (before or []) if (f["pkg"], f["id"]) not in after_keys]
    ca = _counts(after)
    cb = _counts(before) if before is not None else None

    lines = [f"# Vulnerability remediation report", "",
             f"Severity threshold: **{threshold} and above**. Image scanned with Trivy after a `--pull --no-cache` rebuild.", ""]
    if args.notes:
        lines += [args.notes, ""]

    lines += ["## Summary", "", "| | Baseline | After |", "|---|---:|---:|"]
    for k, label in (("os_fixable", "OS packages, fix available"), ("os_unfixed", "OS packages, no fix yet"),
                     ("lang_fixable", "Java/jar, fix available"), ("lang_unfixed", "Java/jar, no fix yet"), ("total", "**Total**")):
        lines.append(f"| {label} | {cb[k] if cb else '—'} | {ca[k]} |")
    lines.append("")
    if before is not None:
        lines += [f"Resolved relative to baseline (`{args.baseline_label or 'baseline'}`): **{len(resolved)}**", ""]

    lines += ["## Verification", "", "| Check | Result |", "|---|---|",
              f"| WAR build | {_ok(args.build_ok)} |", f"| Validator tests (`mvn verify`) | {_ok(args.tests_ok)} |",
              f"| Image build | {_ok(args.image_ok)} |", f"| Container smoke test | {_ok(args.smoke_ok)} |", ""]

    lines += ["## Java dependency changes", ""]
    if pins["changes"]:
        lines += ["| Artifact | From | To | How | Advisories |", "|---|---|---|---|---|"]
        for c in pins["changes"]:
            lines.append(f"| `{c['artifact']}` | {c['from']} | {c['to']} | {c['how']} | {', '.join(c['ids'])} |")
    else:
        lines.append("None.")
    lines.append("")
    if pins["skipped"]:
        lines += ["Not changed automatically:", "", "| Artifact | Installed | Why | Advisories |", "|---|---|---|---|"]
        for s in pins["skipped"]:
            lines.append(f"| `{s['artifact']}` | {s['installed']} | {s['reason']} | {', '.join(s['ids'])} |")
        lines.append("")

    if tomcat:
        lines += ["## Tomcat", "", f"`TOMCAT_VERSION` {tomcat['from']} → {tomcat['to']} ({', '.join(tomcat['ids'])})", ""]

    if resolved:
        lines += ["## Resolved", "", "| Package | Version | Advisory | Severity |", "|---|---|---|---|"]
        for f in resolved:
            lines.append(f"| `{f['pkg']}` | {f['installed']} | {f['id']} | {f['severity']} |")
        lines.append("")

    lines += ["## Remaining in the rebuilt image", ""]
    if after:
        lines += ["| Package | Version | Advisory | Severity | Fixed in | Where |", "|---|---|---|---|---|---|"]
        for f in after:
            where = f["path"] or f["type"]
            lines.append(f"| `{f['pkg']}` | {f['installed']} | {f['id']} | {f['severity']} | "
                         f"{', '.join(f['fixed']) or '_not yet_'} | {where} |")
        lines += ["", "_OS packages with no fix are waiting on an ALAS advisory; the next scheduled run picks them up "
                      "automatically. Jar findings above were either fixed only in a new major version or are not "
                      "reachable by a version pin — see the table of things not changed automatically._"]
    else:
        lines.append("Nothing at or above the threshold. 🎉")
    lines.append("")

    Path(args.output).write_text("\n".join(lines))
    summary = {
        "after": ca, "baseline": cb, "resolved_vs_baseline": len(resolved) if before is not None else None,
        "java_changes": len(pins["changes"]), "tomcat_changed": bool(tomcat),
    }
    if args.summary:
        Path(args.summary).write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--trivy", action="append", default=[], help="Trivy JSON report (repeatable)")
        sp.add_argument("--inspector", action="append", default=[], help="inspector2 list-findings JSON (repeatable)")
        sp.add_argument("--severity", default="HIGH,CRITICAL")
        sp.add_argument("--output")

    sp = sub.add_parser("pin-java")
    common(sp)
    sp.add_argument("--pom", required=True)
    sp.add_argument("--allow-major", action="store_true")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--path-prefix", action="append", default=[],
                    help="only act on findings whose path contains this (e.g. WEB-INF/lib)")
    sp.set_defaults(fn=cmd_pin_java)

    sp = sub.add_parser("pin-tomcat")
    common(sp)
    sp.add_argument("--dockerfile", required=True)
    sp.set_defaults(fn=cmd_pin_tomcat)

    sp = sub.add_parser("report")
    sp.add_argument("--image-scan", action="append", default=[], required=True)
    sp.add_argument("--baseline-scan", action="append", default=[])
    sp.add_argument("--baseline-inspector", action="append", default=[])
    sp.add_argument("--baseline-label")
    sp.add_argument("--pins")
    sp.add_argument("--tomcat")
    sp.add_argument("--severity", default="HIGH,CRITICAL")
    sp.add_argument("--build-ok", default="skipped")
    sp.add_argument("--tests-ok", default="skipped")
    sp.add_argument("--image-ok", default="skipped")
    sp.add_argument("--smoke-ok", default="skipped")
    sp.add_argument("--notes")
    sp.add_argument("--output", required=True)
    sp.add_argument("--summary")
    sp.set_defaults(fn=cmd_report)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
