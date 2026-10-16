#!/usr/bin/env python3
"""Build the architecture and roadmap visuals from one source of truth.

Sources : docs/roadmap/roadmap.json (stages), docs/roadmap/flow.json (request-flow steps), and the
          Terraform files themselves (facts and structure).
Outputs : docs/architecture.svg        static architecture diagram (GitHub renders SVG images, not scripts)
          docs/roadmap.svg             static roadmap
          docs/ROADMAP.md              milestone table and details
          docs/roadmap/data.js         data for the interactive page (file:// cannot fetch JSON)
          docs/roadmap/index.html      only the block between the GENERATED markers (inline diagram)

Before drawing anything it parses the Terraform and FAILS if what the diagram claims no longer matches
the code (AZ count, NAT mode, capacities, ports, load-balancer scheme, ...). Nothing is invented: the
picture is "configured design", never live status.

Usage:  python scripts/build_visuals.py            write the outputs
        python scripts/build_visuals.py --check    verify, write nothing (used in CI); exit 1 on drift
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
RM = DOCS / "roadmap"
problems: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


# --------------------------------------------------------------------------------------- Terraform
def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def tf_default(var: str) -> str:
    m = re.search(r'variable\s+"%s"\s*\{.*?default\s*=\s*(.+?)\n' % re.escape(var), read("variables.tf"), re.S)
    if not m:
        fail(f"variables.tf: no default found for {var}")
        return ""
    return m.group(1).strip().strip('"')


def capacity(var: str) -> tuple[int, int, int]:
    m = re.search(r'variable\s+"%s"\s*\{.*?default\s*=\s*\{\s*min\s*=\s*(\d+),\s*desired\s*=\s*(\d+),\s*max\s*=\s*(\d+)' % var, read("variables.tf"), re.S)
    if not m:
        fail(f"variables.tf: cannot parse default capacity of {var}")
        return (0, 0, 0)
    return tuple(int(x) for x in m.groups())  # type: ignore[return-value]


def require(cond: bool, msg: str) -> None:
    if not cond:
        fail(msg)


def terraform_facts() -> dict:
    f: dict = {}
    f["az_count"] = int(tf_default("az_count") or 0)
    f["nat_mode"] = tf_default("nat_gateway_mode")
    f["fe_cap"] = capacity("frontend_capacity")
    f["be_cap"] = capacity("backend_capacity")
    f["cpu_target"] = int(tf_default("cpu_target_percent") or 0)
    f["instance_type"] = tf_default("frontend_instance_type")
    f["db_class"] = tf_default("db_instance_class")
    f["db_version"] = tf_default("db_engine_version")
    f["db_backup"] = int(tf_default("db_backup_retention_days") or 0)
    f["db_multi_az"] = tf_default("db_multi_az")
    f["db_storage"] = int(tf_default("db_allocated_storage") or 0)
    f["price_class"] = tf_default("cloudfront_price_class")
    f["log_days"] = int(tf_default("log_retention_days") or 0)
    f["vpc_cidr"] = tf_default("vpc_cidr")
    f["region"] = tf_default("region")
    f["ami"] = tf_default("ami_id")

    mon = read("modules/monitoring/main.tf")
    blocks = len(re.findall(r'resource\s+"aws_cloudwatch_metric_alarm"', mon))
    foreach = re.search(r'resource\s+"aws_cloudwatch_metric_alarm"\s+"asg_cpu"\s*\{\s*for_each\s*=\s*\{(.*?)\}', mon, re.S)
    extra = len(re.findall(r"=", foreach.group(1))) - 1 if foreach else 0
    f["alarms"] = blocks + extra

    # The drawing assumes this shape; if Terraform changes, the drawing must be revisited.
    require(f["az_count"] == 2, f"diagram draws 2 Availability Zones but az_count defaults to {f['az_count']}")
    require(f["nat_mode"] == "per_az", f"diagram draws one NAT gateway per AZ but nat_gateway_mode defaults to {f['nat_mode']!r}")
    require(f["fe_cap"] == (2, 2, 4) and f["be_cap"] == (2, 2, 4), f"diagram labels capacity 2/2/4 but defaults are {f['fe_cap']} and {f['be_cap']}")
    require(f["db_multi_az"] == "true", "diagram draws a Multi-AZ database but db_multi_az does not default to true")
    require(f["region"] == "us-east-1", "diagram says us-east-1")
    require(f["alarms"] == 10, f"diagram/docs say 10 alarms; monitoring module defines {f['alarms']}")

    alb, sg = read("alb.tf"), read("security_groups.tf")
    ext = re.search(r'resource\s+"aws_lb"\s+"external"\s*\{(.*?)\n\}', alb, re.S)
    intl = re.search(r'resource\s+"aws_lb"\s+"internal"\s*\{(.*?)\n\}', alb, re.S)
    require(bool(ext) and bool(re.search(r"internal\s*=\s*false", ext.group(1)) if ext else False), "alb.tf: external ALB must be internal = false")
    require(bool(intl) and bool(re.search(r"internal\s*=\s*true", intl.group(1)) if intl else False), "alb.tf: internal ALB must be internal = true")
    require('status_code  = "403"' in alb or 'status_code = "403"' in alb, "alb.tf: listener default action must be a fixed 403")
    require("http_header" in alb and "origin_verify_header_name" in alb, "alb.tf: forwarding rule must match the origin-verify header")
    require(re.search(r'"backend"\s*\{.*?port\s*=\s*8080', alb, re.S) is not None, "alb.tf: backend target group must use port 8080")
    require('path                = "/healthz"' in alb and 'path                = "/health"' in alb, "alb.tf: health-check paths /healthz and /health")
    for rule, port in (("ext_alb_from_cloudfront", 80), ("frontend_from_ext_alb", 80), ("int_alb_from_frontend", 80), ("backend_from_int_alb", 8080), ("rds_from_backend", 5432)):
        m = re.search(r'resource\s+"aws_vpc_security_group_ingress_rule"\s+"%s"\s*\{(.*?)\n\}' % rule, sg, re.S)
        require(bool(m) and re.search(r"from_port\s*=\s*%d" % port, m.group(1) if m else "") is not None, f"security_groups.tf: {rule} must allow port {port}")
    require("prefix_list_id" in sg, "security_groups.tf: external ALB must use the CloudFront prefix list")
    for rule, port in (("ext_alb_to_frontend", 80), ("frontend_to_int_alb", 80), ("int_alb_to_backend", 8080), ("backend_to_rds", 5432)):
        m = re.search(r'resource\s+"aws_vpc_security_group_egress_rule"\s+"%s"\s*\{(.*?)\n\}' % rule, sg, re.S)
        require(bool(m) and re.search(r"from_port\s*=\s*%d\s" % port, m.group(1) if m else "") is not None, f"security_groups.tf: egress rule {rule} must allow port {port}")

    net, db, edge, app = read("modules/network/main.tf"), read("modules/database/main.tf"), read("modules/edge/main.tf"), read("modules/app_tier/main.tf")
    require('resource "aws_route" "db' not in net and "aws_route_table\" \"db\"" in net, "network: the database route table must have no default route")
    require("map_public_ip_on_launch = false" in net, "network: no auto-assigned public IPs")
    require("publicly_accessible    = false" in db and "storage_encrypted     = true" in db, "database: private and encrypted")
    require('"rds.force_ssl"' in db, "database: rds.force_ssl")
    require(edge.count('viewer_protocol_policy   = "redirect-to-https"') + edge.count('viewer_protocol_policy = "redirect-to-https"') == 3, "edge: three behaviors redirect to HTTPS")
    require('path_pattern             = "/api/*"' in edge and 'path_pattern           = "/static/*"' in edge, "edge: /api/* and /static/* behaviors")
    require('http_tokens                 = "required"' in app and 'health_check_type         = "ELB"' in app, "app_tier: IMDSv2 and ELB health checks")
    return f


# --------------------------------------------------------------------------------------- helpers
FONT = 'Inter, "Segoe UI", system-ui, -apple-system, Roboto, Helvetica, Arial, sans-serif'
C = {
    "bg0": "#070d1a", "bg1": "#0d1830", "panel": "#101b33", "panel2": "#14213f", "line": "#27385f",
    "text": "#e8eef9", "muted": "#9db0cf", "dim": "#6f84a8",
    "cyan": "#22d3ee", "blue": "#4c8dff", "orange": "#ff9900", "purple": "#a78bfa",
    "green": "#34d399", "amber": "#fbbf24", "slate": "#94a3b8",
}
warnings: list[str] = []


def fit(text: str, size: float, width: float, where: str, bold: bool = False) -> None:
    est = len(text) * size * (0.60 if bold else 0.55)
    if est > width:
        warnings.append(f"text may overflow ({est:.0f}px > {width:.0f}px) in {where}: {text!r}")


def txt(x, y, s, size=13, cls="t", anchor="start", weight=None, fill=None, where="", width=None, extra="") -> str:
    if width is not None:
        fit(s, size, width, where or s, bold=bool(weight and int(weight) >= 600))
    a = f' text-anchor="{anchor}"' if anchor != "start" else ""
    w = f' font-weight="{weight}"' if weight else ""
    fl = f' fill="{fill}"' if fill else ""
    return f'<text class="{cls}" x="{x}" y="{y}" font-size="{size}"{a}{w}{fl}{extra}>{escape(s)}</text>'


def wrap(s: str, size: float, width: float, max_lines: int, where: str) -> list[str]:
    words, lines, cur = s.split(), [], ""
    per = max(1, int(width / (size * 0.55)))
    for w in words:
        if len(cur) + len(w) + (1 if cur else 0) <= per:
            cur = (cur + " " + w).strip()
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if len(lines) > max_lines:
        warnings.append(f"wrapped text exceeds {max_lines} lines in {where}")
        lines = lines[:max_lines]
    return lines


# --------------------------------------------------------------------------------------- glyphs
GLYPHS = {
    "browser": '<rect x="3" y="6" width="26" height="20" rx="3"/><path d="M3 12h26"/><circle cx="7.5" cy="9" r=".9" fill="currentColor"/><circle cx="11" cy="9" r=".9" fill="currentColor"/>',
    "route53": '<circle cx="16" cy="16" r="12"/><text x="16" y="20.5" font-size="12" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none">53</text>',
    "cloudfront": '<circle cx="16" cy="16" r="12"/><ellipse cx="16" cy="16" rx="5" ry="12"/><path d="M4 16h24"/>',
    "acm": '<path d="M16 4l10 4v8c0 6-5 10-10 12C11 26 6 22 6 16V8z"/><path d="M11 16l4 4 7-8"/>',
    "igw": '<path d="M5 27V13h22v14M3 13L16 4l13 9M12 27v-9h8v9"/>',
    "alb": '<circle cx="6" cy="16" r="3"/><path d="M9 16h6M15 16l9-8M15 16h9M15 16l9 8"/><circle cx="26.5" cy="8" r="2"/><circle cx="26.5" cy="16" r="2"/><circle cx="26.5" cy="24" r="2"/>',
    "nat": '<rect x="4" y="7" width="24" height="18" rx="3"/><path d="M10 13h12M19 10l3 3-3 3M22 20H10M13 17l-3 3 3 3"/>',
    "ec2": '<rect x="9" y="9" width="14" height="14" rx="2"/><path d="M13 5v4M16 5v4M19 5v4M13 23v4M16 23v4M19 23v4M5 13h4M5 16h4M5 19h4M23 13h4M23 16h4M23 19h4"/>',
    "rds": '<ellipse cx="16" cy="8" rx="10" ry="4"/><path d="M6 8v16c0 4 20 4 20 0V8M6 16c0 4 20 4 20 0"/>',
    "cw": '<path d="M4 25h24M5 22l6-7 5 4 6-9 5 4"/>',
    "secret": '<circle cx="11" cy="16" r="5"/><path d="M16 16h12M24 16v5M28 16v4"/>',
    "ssm": '<rect x="3" y="6" width="26" height="20" rx="3"/><path d="M8 13l5 4-5 4M16 21h8"/>',
    "logs": '<rect x="7" y="4" width="18" height="24" rx="2"/><path d="M11 10h10M11 15h10M11 20h6"/>',
    "s3": '<ellipse cx="16" cy="9" rx="10" ry="3.5"/><path d="M6 9l2.5 17c.4 2 15.6 2 16 0L26 9"/>',
}


def symbols() -> str:
    return "".join(f'<symbol id="g-{k}" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{v}</symbol>' for k, v in GLYPHS.items())


# --------------------------------------------------------------------------------------- diagram model
KIND = {"client": C["slate"], "edge": C["cyan"], "net": C["purple"], "compute": C["orange"], "data": C["blue"], "sec": C["amber"], "support": C["dim"]}

# id: (x, y, w, h, kind, glyph, title, subtitle)
NODES: dict[str, tuple] = {
    "browser": (40, 82, 240, 78, "client", "browser", "Viewer / browser", "HTTPS to the public name"),
    "route53": (380, 56, 260, 70, "edge", "route53", "Route 53", "A + AAAA alias (optional)"),
    "cloudfront": (660, 90, 280, 80, "edge", "cloudfront", "CloudFront", "3 behaviors · HTTP to HTTPS"),
    "igw": (690, 196, 220, 40, "net", "igw", "Internet gateway", ""),
    "nat_a": (70, 305, 250, 60, "net", "nat", "NAT gateway · AZ a", "elastic IP"),
    "ext_alb": (500, 305, 600, 60, "net", "alb", "External ALB (internet-facing)", "port 80 · default 403 · forwards only with the origin header"),
    "nat_b": (1280, 305, 250, 60, "net", "nat", "NAT gateway · AZ b", "elastic IP"),
    "fe_a": (330, 470, 300, 72, "compute", "ec2", "Frontend EC2 · AZ a", "nginx :80 · configured, not live"),
    "fe_b": (970, 470, 300, 72, "compute", "ec2", "Frontend EC2 · AZ b", "nginx :80 · configured, not live"),
    "int_alb": (500, 590, 600, 60, "net", "alb", "Internal ALB (private)", "port 80 · forwards to backend :8080"),
    "be_a": (330, 718, 300, 54, "compute", "ec2", "Backend EC2 · AZ a", "API :8080 · configured, not live"),
    "be_b": (970, 718, 300, 54, "compute", "ec2", "Backend EC2 · AZ b", "API :8080 · configured, not live"),
    "rds_p": (340, 868, 360, 100, "data", "rds", "RDS PostgreSQL · primary", "AZ a · encrypted · TLS enforced · :5432"),
    "rds_s": (900, 868, 360, 100, "data", "rds", "RDS standby (Multi-AZ)", "AZ b · synchronous replication"),
}
# frames: id: (x, y, w, h, title)
FRAMES = {
    "fe_asg": (300, 430, 1000, 128, "Frontend Auto Scaling group · min 2 / desired 2 / max 4 · CPU target 50%"),
    "be_asg": (300, 676, 1000, 108, "Backend Auto Scaling group · min 2 / desired 2 / max 4 · CPU target 50%"),
}
# chips: id: (x, y, w, h, kind, text)
CHIPS = {
    "acm": (960, 94, 250, 34, "edge", "ACM certificate · us-east-1"),
    "origin_header": (960, 136, 240, 34, "sec", "adds X-Origin-Verify header"),
    "sg_ext": (332, 313, 158, 44, "sec", ["SG: from CloudFront", "prefix list, port 80"]),
    "sg_fe": (660, 474, 280, 40, "sec", "SG: port 80 from the external ALB"),
    "sg_int": (332, 598, 158, 44, "sec", ["SG: from frontend", "group, port 80"]),
    "sg_be": (660, 730, 280, 36, "sec", "SG: port 8080 from the internal ALB"),
    "sg_rds": (620, 986, 360, 30, "sec", "SG: port 5432 from the backend group only"),
}
# edges: id: (d, kind, layer, bidir, label, label_xy, anchor)
EDGES = {
    "e_dns": ("M280,100 H380", "dns", None, True, "DNS lookup", (330, 88), "middle"),
    "e_browser_cf": ("M280,146 H660", "req", None, False, "HTTPS request · TLS ends at CloudFront", (470, 170), "middle"),
    "e_cf_igw": ("M800,170 V196", "req", None, False, "", (0, 0), "start"),
    "e_igw_alb": ("M800,236 V305", "req", None, False, "HTTP :80 + X-Origin-Verify", (814, 276), "start"),
    "e_alb_fe": ("M800,365 V430", "req", None, False, "to healthy frontends", (814, 402), "start"),
    "e_fe_int": ("M800,558 V590", "req", None, False, "/api/* proxied", (814, 579), "start"),
    "e_int_be": ("M800,650 V676", "req", None, False, "to backend :8080", (814, 668), "start"),
    "e_be_rds": ("M800,784 V850 H520 V868", "req", None, False, "PostgreSQL :5432 (TLS)", (814, 812), "start"),
    "e_repl": ("M700,918 H900", "repl", "replication", False, "synchronous replication", (800, 908), "middle"),
    "hc_ext": ("M1020,365 V430", "hc", "health", False, "health check /healthz", (1032, 402), "start"),
    "hc_int": ("M1020,650 V676", "hc", "health", False, "health check /health", (1032, 668), "start"),
    "eg_a": ("M300,730 H100 V365", "eg", "nat", False, "", (0, 0), "start"),
    "eg_a2": ("M300,505 H100", "eg", "nat", False, "", (0, 0), "start"),
    "nat_igw_a": ("M100,305 V232 H690", "eg", "nat", False, "", (0, 0), "start"),
    "eg_b": ("M1300,730 H1500 V365", "eg", "nat", False, "", (0, 0), "start"),
    "eg_b2": ("M1300,505 H1500", "eg", "nat", False, "", (0, 0), "start"),
    "nat_igw_b": ("M1500,305 V232 H910", "eg", "nat", False, "", (0, 0), "start"),
}
SUPPORT = [
    ("cw", "CloudWatch · 10 alarms to SNS", 310),
    ("logs", "VPC flow logs · RDS logs", 250),
    ("secret", "Secrets Manager · RDS-managed secret", 360),
    ("ssm", "Session Manager (no SSH)", 270),
    ("s3", "S3 gateway endpoint", 240),
]
W, H = 1600, 1140


def arch_svg(f: dict, standalone: bool) -> str:
    o: list[str] = []
    a = o.append
    title = "Architecture of the highly available web platform (derived from the Terraform in this repository)"
    desc = ("Configured design, not live telemetry. A viewer resolves the name through Route 53, connects to CloudFront over HTTPS, "
            "which forwards over HTTP with a secret header through the internet gateway to the external ALB. The ALB forwards to the "
            "frontend Auto Scaling group in private subnets, which calls the internal ALB, then the backend Auto Scaling group, which "
            "queries a Multi-AZ RDS PostgreSQL database in isolated subnets. Two Availability Zones, one NAT gateway per zone.")
    a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" class="arch" role="img" aria-labelledby="arch-title arch-desc" font-family=\'{FONT}\'>')
    a(f'<title id="arch-title">{escape(title)}</title><desc id="arch-desc">{escape(desc)}</desc>')
    a("<defs>")
    a(f'<linearGradient id="bgGrad" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{C["bg1"]}"/><stop offset="1" stop-color="{C["bg0"]}"/></linearGradient>')
    a(f'<linearGradient id="vpcGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{C["cyan"]}" stop-opacity=".55"/><stop offset=".5" stop-color="{C["blue"]}" stop-opacity=".45"/><stop offset="1" stop-color="{C["orange"]}" stop-opacity=".5"/></linearGradient>')
    for mid, col in (("req", C["cyan"]), ("dns", C["cyan"]), ("hc", C["amber"]), ("eg", C["slate"]), ("repl", C["blue"])):
        a(f'<marker id="m-{mid}" viewBox="0 0 10 10" refX="8.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="12" markerHeight="12" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{col}"/></marker>')
    a(symbols())
    a("</defs>")
    a("<style>")
    rules = [
        (".bg", f"fill:url(#bgGrad)"), (".t", f"fill:{C['text']}"), (".m", f"fill:{C['muted']}"), (".d", f"fill:{C['dim']}"), ("text", f"font-family:{FONT}"),
        (".zone", f"fill:{C['panel']};stroke:{C['line']};stroke-width:1.2"), (".zone-vpc", "fill:#0a1428;stroke:url(#vpcGrad);stroke-width:2.2;stroke-dasharray:10 6"),
        (".band", "fill:#ffffff;fill-opacity:.025;stroke:#ffffff;stroke-opacity:.07"),
        (".box", f"fill:{C['panel2']};stroke-width:1.8"), (".frame", "fill:#ffffff;fill-opacity:.02;stroke-width:1.4;stroke-dasharray:6 5"),
        (".chip", "fill:#0c1730;stroke-width:1.2"),
    ]
    for k, v in KIND.items():
        rules += [(f".k-{k} .box", f"stroke:{v}"), (f".k-{k} .chip", f"stroke:{v}"), (f".k-{k} .frame", f"stroke:{v}"), (f".k-{k} .gl", f"color:{v}")]
    rules += [
        (".edge", "fill:none;stroke-width:3;stroke-linecap:round;stroke-linejoin:round"),
        (".e-req", f"stroke:{C['cyan']}"), (".e-dns", f"stroke:{C['cyan']};stroke-dasharray:7 6"),
        (".e-hc", f"stroke:{C['amber']};stroke-width:2;stroke-dasharray:2 6"), (".e-eg", f"stroke:{C['slate']};stroke-width:2;stroke-dasharray:8 6"),
        (".e-repl", f"stroke:{C['blue']};stroke-width:2.5"), (".lbl", "font-size:13.5px"),
    ]
    for sel, body in rules:  # every selector is scoped to .arch so the inline copy cannot restyle the page
        a(f".arch {sel}{{{body}}}")
    a("</style>")
    a(f'<rect class="bg" width="{W}" height="{H}"/>')
    # title block
    a(txt(40, 32, "Architecture · derived from the Terraform in this repository", 20, "t", weight=700))
    a(txt(40, 50, f"Configured design, not live telemetry · {f['region']} · {f['az_count']} Availability Zones · capacities are configured values", 13.5, "m", width=1000, where="subtitle"))
    # legend
    a(f'<g id="legend" transform="translate(1262,50)"><rect class="zone" width="320" height="132" rx="10"/>')
    rows = [("req", "Request path (arrow = direction)"), ("dns", "DNS lookup and answer"), ("hc", "Load-balancer health check"), ("eg", "Egress via NAT (packages, SSM)"), ("repl", "Database replication")]
    for i, (kind, label) in enumerate(rows):
        y = 24 + i * 22
        a(f'<path class="edge e-{kind}" d="M14,{y} H54" marker-end="url(#m-{kind})"/>')
        a(txt(66, y + 5, label, 13.5, "m", width=246, where="legend"))
    a("</g>")
    # VPC
    a(f'<g id="zones"><rect class="zone zone-vpc" x="30" y="215" width="1540" height="830" rx="16"/>')
    a(txt(124, 256, f"VPC {f['vpc_cidr']} · {f['region']}", 15.5, "t", weight=600))
    a(txt(1476, 256, "no instance has a public IP", 13.5, "d", anchor="end"))
    for (y, h, label) in ((295, 80, "Public subnets · 10.0.0.0/24 · 10.0.1.0/24"), (395, 405, "Private application subnets · 10.0.10.0/24 · 10.0.11.0/24"), (820, 205, "Isolated database subnets · 10.0.20.0/24 · 10.0.21.0/24 · no default route")):
        a(f'<rect class="band" x="50" y="{y}" width="1500" height="{h}" rx="10"/>')
        a(txt(120, y - 4 if y == 295 else y + 17, label, 13, "d", width=760, where=label))
    a(f'<path d="M800,255 V1030" stroke="{C["line"]}" stroke-width="1.2" stroke-dasharray="3 7" fill="none"/>')
    a(txt(330, 274, "Availability Zone a", 14, "m"))
    a(txt(1270, 274, "Availability Zone b", 14, "m", anchor="end"))
    a("</g>")
    # frames
    a('<g id="frames">')
    for fid, (x, y, w, h, ttl) in FRAMES.items():
        a(f'<g id="n-{fid}" class="node k-compute" role="img" aria-label="{escape(ttl)}"><rect class="frame" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        a(txt(x + 16, y + 23, ttl, 14, "t", weight=600, width=w - 32, where=ttl) + "</g>")
    a("</g>")
    # edges
    a('<g id="edges">')
    for eid, (d, kind, layer, bidir, label, (lx, ly), anc) in EDGES.items():
        lay = f' data-layer="{layer}"' if layer else ""
        ms = f' marker-start="url(#m-{kind})"' if bidir else ""
        me = "" if eid.endswith("2") else f' marker-end="url(#m-{kind})"'      # stubs (eg_a2/eg_b2) just join the main line
        a(f'<path id="{eid}" class="edge e-{kind}" d="{d}"{me}{ms}{lay}/>')
    a("</g>")
    a('<g id="edge-labels">')
    for eid, (d, kind, layer, bidir, label, (lx, ly), anc) in EDGES.items():
        if label:
            lay = f' data-layer="{layer}"' if layer else ""
            wmax = 230 if anc != "middle" else 360
            a(txt(lx, ly, label, 13.5, "lbl " + ("t" if kind in ("req",) else "m"), anchor=anc, width=wmax, where=f"edge {eid}", extra=f' data-for="{eid}"{lay}'))
    a(txt(110, 600, "egress :80 / :443", 13, "m", extra=' data-layer="nat"'))
    a(txt(110, 618, "to the internet via NAT", 13, "m", extra=' data-layer="nat"'))
    a(txt(1400, 600, "egress :80 / :443", 13, "m", extra=' data-layer="nat"', anchor="middle"))
    a(txt(1400, 618, "to the internet via NAT", 13, "m", extra=' data-layer="nat"', anchor="middle"))
    a("</g>")
    # nodes
    a('<g id="nodes">')
    for nid, (x, y, w, h, kind, gl, ttl, sub) in NODES.items():
        a(f'<g id="n-{nid}" class="node k-{kind}" role="img" aria-label="{escape(ttl + (": " + sub if sub else ""))}">')
        a(f'<rect class="box" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        size = 26 if h >= 50 else 22
        a(f'<use class="gl" href="#g-{gl}" x="{x + 12}" y="{y + (h - size) / 2:.1f}" width="{size}" height="{size}"/>')
        tx = x + 12 + size + 12
        inner = w - (tx - x) - 10
        if sub:
            a(txt(tx, y + h / 2 - 3, ttl, 16, "t", weight=600, width=inner, where=ttl))
            a(txt(tx, y + h / 2 + 16, sub, 13, "m", width=inner, where=sub))
        else:
            a(txt(tx, y + h / 2 + 6, ttl, 15.5, "t", weight=600, width=inner, where=ttl))
        a("</g>")
    a("</g>")
    # chips
    a('<g id="chips">')
    for cid, (x, y, w, h, kind, t) in CHIPS.items():
        lay = ' data-layer="security"' if cid.startswith("sg_") else ""
        a(f'<g id="n-{cid}" class="node k-{kind}"{lay}><rect class="chip k-{kind}" x="{x}" y="{y}" width="{w}" height="{h}" rx="8"/>')
        lines = t if isinstance(t, list) else [t]
        for i, ln in enumerate(lines):
            yy = y + (h / 2 + 5 if len(lines) == 1 else 18 + i * 17)
            a(txt(x + w / 2, yy, ln, 13, "t", anchor="middle", width=w - 14, where=ln))
        a("</g>")
    a("</g>")
    # supporting strip
    a(f'<g id="support"><text class="d" x="40" y="1072" font-size="14">Supporting services (configured)</text>')
    x = 40
    for gl, label, w in SUPPORT:
        a(f'<g class="k-support"><rect class="chip" x="{x}" y="1080" width="{w}" height="40" rx="8" stroke="{C["line"]}"/><use class="gl" href="#g-{gl}" x="{x + 10}" y="1088" width="24" height="24" style="color:{C["muted"]}"/>')
        a(txt(x + 42, 1106, label, 13.5, "t", width=w - 50, where=label) + "</g>")
        x += w + 16
    a("</g>")
    a('<g id="packet-layer"></g>')
    a("</svg>")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------------------- roadmap svg
def status_label(st: dict) -> tuple[str, str]:
    local, aws = st["local"], st["aws"]
    if local == "planned":
        return "Planned", "planned"
    if local == "verified":
        return "Verified locally", "verified"
    return "Documented", "documented"


def counts(stages: list[dict]) -> dict:
    return {
        "verified": sum(s["local"] == "verified" for s in stages),
        "documented": sum(s["local"] == "documented" for s in stages),
        "planned": sum(s["local"] == "planned" for s in stages),
        "aws_verified": sum(s["aws"] == "verified" for s in stages),
        "total": len(stages),
    }


TAGLINES = {
    "design": "Three tiers, two AZs, private by default.",
    "foundation": "Five modules, pinned providers, plan-time guard rails.",
    "network": "Public, private and isolated subnets; one NAT per AZ.",
    "security": "Each tier reachable only from the one before it.",
    "loadbalancing": "Header-locked external ALB, private internal ALB.",
    "autoscaling": "Two Auto Scaling groups, min 2, ELB health checks.",
    "database": "Multi-AZ PostgreSQL; password never in state.",
    "edge": "CloudFront, optional ACM and Route 53, HTTPS only.",
    "ci": "Seven jobs; pull requests static only; saved-plan apply.",
    "state": "S3 with native locking; guards against empty state.",
    "validation": "What was run, what failed, what costs money.",
    "deploy": "AMI check, first plan, sandbox apply, hardening.",
}


def roadmap_svg(stages: list[dict]) -> str:
    cw, ch, gap, x0, per_row = 350, 276, 28, 24, 4
    cnt = counts(stages)
    rows = [stages[i:i + per_row] for i in range(0, len(stages), per_row)]
    Wr = x0 * 2 + per_row * cw + (per_row - 1) * gap
    top0, step = 118, ch + 52
    Hr = top0 + (len(rows) - 1) * step + ch + 64
    o: list[str] = []
    a = o.append
    title = "Engineering roadmap and project journey"
    desc = (f"{cnt['total']} stages. {cnt['verified']} verified locally, {cnt['documented']} documented, {cnt['planned']} planned. "
            f"{cnt['aws_verified']} verified on AWS: nothing has been deployed.")
    a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {Wr} {Hr}" width="{Wr}" height="{Hr}" class="roadmap" role="img" aria-labelledby="rm-title rm-desc" font-family=\'{FONT}\'>')
    a(f'<title id="rm-title">{title}</title><desc id="rm-desc">{escape(desc)}</desc>')
    a("<defs>")
    a(f'<linearGradient id="bgGrad" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{C["bg1"]}"/><stop offset="1" stop-color="{C["bg0"]}"/></linearGradient>')
    a(f'<linearGradient id="rail" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{C["green"]}"/><stop offset=".62" stop-color="{C["cyan"]}"/><stop offset="1" stop-color="{C["dim"]}"/></linearGradient>')
    a("</defs>")
    a("<style>")
    a(f".roadmap .bg{{fill:url(#bgGrad)}} .roadmap text{{font-family:{FONT}}} .roadmap .t{{fill:{C['text']}}} .roadmap .m{{fill:{C['muted']}}} .roadmap .d{{fill:{C['dim']}}}")
    a(f".roadmap .card{{fill:{C['panel']};stroke:{C['line']};stroke-width:1.2}} .roadmap .chipbg{{fill:#0c1730}}")
    a("</style>")
    a(f'<rect class="bg" width="{Wr}" height="{Hr}"/>')
    a(txt(x0 + 16, 50, title, 30, "t", weight=700))
    a(txt(x0 + 16, 80, "What the repository can back up with evidence. Nothing has been deployed to AWS.", 16, "m", width=860, where="subtitle"))
    badges = [(f"{cnt['verified']} of {cnt['total']}", "verified locally", C["green"]), (f"{cnt['documented']}", "documented", C["blue"]), (f"{cnt['planned']}", "planned", C["slate"]), (f"{cnt['aws_verified']} of {cnt['total']}", "verified on AWS", C["amber"])]
    sx = Wr - x0 - 4 * 150 + 10
    for i, (big, small, col) in enumerate(badges):
        x = sx + i * 150
        a(f'<g><rect class="card" x="{x}" y="24" width="140" height="64" rx="10" stroke="{col}" stroke-opacity=".7"/>')
        a(txt(x + 70, 54, big, 22, "t", anchor="middle", weight=700) + txt(x + 70, 76, small, 13, "m", anchor="middle") + "</g>")
    for ri, row in enumerate(rows):
        top = top0 + ri * step
        ry = top + 32
        a(f'<path d="M{x0 + 32},{ry} H{x0 + len(row) * cw + (len(row) - 1) * gap - 32}" stroke="url(#rail)" stroke-width="4" stroke-linecap="round" opacity=".9"/>')
        for i, st in enumerate(row):
            x = x0 + i * (cw + gap)
            label, key = status_label(st)
            col = {"verified": C["green"], "documented": C["blue"], "planned": C["slate"]}[key]
            dash = ' stroke-dasharray="6 5"' if key == "planned" else ""
            a(f'<g id="stage-{st["id"]}"><rect class="card" x="{x}" y="{top}" width="{cw}" height="{ch}" rx="12"{dash}/>')
            a(f'<rect x="{x}" y="{top}" width="{cw}" height="5" rx="2.5" fill="{col}" opacity=".9"/>')
            a(f'<circle cx="{x + 34}" cy="{ry}" r="18" fill="#0a1428" stroke="{col}" stroke-width="2.5"/>')
            a(txt(x + 34, ry + 6.5, str(st["n"]), 18, "t", anchor="middle", weight=700))
            tl = wrap(st["short"], 17, cw - 84, 2, f"stage {st['n']} title")
            for k, ln in enumerate(tl):
                a(txt(x + 64, ry + 6 + k * 20 - (10 if len(tl) > 1 else 0), ln, 17, "t", weight=700))
            for k, ln in enumerate(wrap(TAGLINES[st["id"]], 14.5, cw - 36, 2, f"stage {st['n']} tagline")):
                a(txt(x + 18, top + 88 + k * 20, ln, 14.5, "m"))
            cwid = int(len(label) * 7.2 + 26)
            a(f'<rect class="chipbg" x="{x + 18}" y="{top + 130}" width="{cwid}" height="26" rx="13" stroke="{col}" stroke-width="1.2"/>')
            a(txt(x + 18 + cwid / 2, top + 148, label, 13, "t", anchor="middle", weight=600))
            aws_t = {"pending": "AWS: pending", "na": "AWS: n/a", "verified": "AWS: verified"}[st["aws"]]
            aws_c = C["amber"] if st["aws"] == "pending" else (C["green"] if st["aws"] == "verified" else C["dim"])
            awid = int(len(aws_t) * 7 + 26)
            ax = x + 18 + cwid + 10
            a(f'<rect class="chipbg" x="{ax}" y="{top + 130}" width="{awid}" height="26" rx="13" stroke="{aws_c}" stroke-width="1.2" stroke-dasharray="3 3"/>')
            a(txt(ax + awid / 2, top + 148, aws_t, 12.5, "m", anchor="middle"))
            a(txt(x + 18, top + 188, "Checks" if st["checks"] else ("Next" if st.get("next") else "Evidence"), 12, "d", weight=600))
            items = st["checks"][:3] or [e for e in st.get("next", [])[:1]] or ["Docs only; not machine-checked"]
            if st["checks"] and len(st["checks"]) > 3:
                items = st["checks"][:2] + [f"+{len(st['checks']) - 2} more"]
            yy, budget = top + 208, 4                     # at most four text lines per card
            for it in items:
                for ln in wrap(it, 13, cw - 44, 2, f"stage {st['n']} check")[:2]:
                    if budget == 0:
                        break
                    a(txt(x + 24, yy, "· " + ln, 13, "m"))
                    yy += 17
                    budget -= 1
            a("</g>")
    a(txt(x0 + 16, Hr - 24, "Interactive version with evidence, files and trade-offs: docs/roadmap/index.html   ·   green = automated local checks pass · blue = documented · grey dashed = planned · amber = needs AWS", 13, "d", width=Wr - 60, where="footer"))
    a("</svg>")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------------------------- docs + data
def fact_cards(f: dict) -> list[dict]:
    cap = lambda c: f"min {c[0]} / desired {c[1]} / max {c[2]}"  # noqa: E731
    return [
        {"label": "Availability Zones", "value": str(f["az_count"]), "source": "variables.tf (az_count)", "note": "Up to 3 supported."},
        {"label": "NAT gateways", "value": f"{f['az_count']} (one per AZ)" if f["nat_mode"] == "per_az" else "1 (shared)", "source": "variables.tf (nat_gateway_mode)", "note": "A single shared NAT is cheaper but loses egress if its zone fails."},
        {"label": "Frontend Auto Scaling group", "value": cap(f["fe_cap"]), "source": "variables.tf (frontend_capacity)", "note": f"{f['instance_type']} by default; CPU target {f['cpu_target']}%. Configured, not observed."},
        {"label": "Backend Auto Scaling group", "value": cap(f["be_cap"]), "source": "variables.tf (backend_capacity)", "note": "Configured, not observed."},
        {"label": "Database", "value": f"PostgreSQL {f['db_version']}, {f['db_class']}, Multi-AZ", "source": "modules/database/main.tf", "note": f"{f['db_storage']} GiB gp3, {f['db_backup']}-day backups, encrypted, private."},
        {"label": "CloudFront", "value": "3 behaviors", "source": "modules/edge/main.tf", "note": f"{f['price_class']}. Static assets cached; HTML and API are not."},
        {"label": "CloudWatch alarms", "value": str(f["alarms"]), "source": "modules/monitoring/main.tf", "note": f"Notify one SNS topic. Log retention {f['log_days']} days."},
        {"label": "Base image", "value": f["ami"], "source": "variables.tf (ami_id)", "note": "Never inspected: AWS credentials were invalid. The plan verifies it before creating anything."},
    ]


def roadmap_md(stages: list[dict], f: dict) -> str:
    cnt = counts(stages)
    L = [
        "<!-- Generated by scripts/build_visuals.py from docs/roadmap/roadmap.json. Edit the JSON, then re-run the script. -->",
        "# Roadmap",
        "",
        "Milestones of this project and the evidence behind each status. **Nothing has been deployed to AWS**, and AWS credentials were invalid throughout, so no stage is verified on AWS.",
        "",
        f"**{cnt['verified']} of {cnt['total']}** stages are verified locally, **{cnt['documented']}** are documented, **{cnt['planned']}** is planned, and **{cnt['aws_verified']} of {cnt['total']}** are verified on AWS. These are counts, not a completion percentage.",
        "",
        "![Roadmap](roadmap.svg)",
        "",
        "Interactive version: open [`roadmap/index.html`](roadmap/index.html) in a browser after cloning (GitHub's file view shows the source, not the page).",
        "",
        "| Stage | Status | AWS verification |",
        "|---|---|---|",
    ]
    for s in stages:
        lab, _ = status_label(s)
        aws = {"pending": "pending", "na": "not applicable", "verified": "verified"}[s["aws"]]
        L.append(f"| {s['n']}. {s['title']} | {lab} | {aws} |")
    L += ["", "**Status key.** *Verified locally*: automated checks pass on this machine (static analysis, mocked tests, local emulators). *Documented*: written and reviewed, not exercised by an automated check. *Planned*: not started. *AWS: pending*: needs a working AWS account.", ""]
    for s in stages:
        lab, _ = status_label(s)
        L += [f"## {s['n']}. {s['title']}", "", f"**{lab}** · AWS: {s['aws']}", "", s["summary"], ""]
        if s.get("ci"):
            L += [f"**Observed on GitHub:** {s['ci']}", ""]
        for head, key in (("Evidence", "evidence"), ("Checks", "checks"), ("Decisions and trade-offs", "decisions"), ("Limits", "limits"), ("Next", "next")):
            if s.get(key):
                L += [f"{head}:", ""] + [f"- {x}" for x in s[key]] + [""]
        if s["files"]:
            L += ["Files:", ""] + [f"- [`{x['path']}`](../{x['path']}) — {x['label']}" for x in s["files"]] + [""]
    return "\n".join(L).rstrip() + "\n"


def data_js(stages: list[dict], flow: dict, f: dict) -> str:
    payload = {"stages": stages, "flow": flow, "facts": fact_cards(f), "counts": counts(stages)}
    return "// Generated by scripts/build_visuals.py. Do not edit.\nwindow.RM_DATA = " + json.dumps(payload, indent=1, ensure_ascii=False) + ";\n"


BEGIN, END = "<!-- BEGIN GENERATED: architecture-svg -->", "<!-- END GENERATED: architecture-svg -->"


def index_html(f: dict) -> str:
    path = RM / "index.html"
    html = path.read_text(encoding="utf-8")
    if BEGIN not in html or END not in html:
        fail("docs/roadmap/index.html is missing the GENERATED markers")
        return html
    inline = arch_svg(f, standalone=False).replace('width="1600" height="1140" ', "")
    head, rest = html.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    return head + BEGIN + "\n" + inline + END + tail


def validate_inputs(stages: list[dict], flow: dict) -> None:
    ids = [s["id"] for s in stages]
    require(len(stages) == 12 and [s["n"] for s in stages] == list(range(1, 13)), "roadmap.json: expected 12 stages numbered 1..12")
    require(set(ids) == set(TAGLINES), "roadmap.json: stage ids differ from the taglines in build_visuals.py")
    for s in stages:
        require(s["local"] in ("verified", "documented", "planned"), f"stage {s['n']}: bad local status")
        require(s["aws"] in ("pending", "na", "verified"), f"stage {s['n']}: bad aws status")
        require(s["aws"] != "verified", f"stage {s['n']}: marked verified on AWS, but nothing has been deployed")
        for fl in s["files"]:
            require((ROOT / fl["path"]).exists(), f"stage {s['n']}: file does not exist: {fl['path']}")
    node_ids = set(NODES) | set(FRAMES) | set(CHIPS)
    for st in flow["steps"]:
        for n in st["nodes"]:
            require(n in node_ids, f"flow step {st['id']}: unknown node {n}")
        for p in st["path"] + st.get("side", []):
            require(p["edge"] in EDGES, f"flow step {st['id']}: unknown edge {p['edge']}")
        for r in st["refs"]:
            require((ROOT / r["path"]).exists(), f"flow step {st['id']}: file does not exist: {r['path']}")
    main = [p["edge"] for st in flow["steps"] for p in st["path"] if p["dir"] == "fwd" and EDGES[p["edge"]][1] == "req"]
    require(main == ["e_browser_cf", "e_cf_igw", "e_igw_alb", "e_alb_fe", "e_fe_int", "e_int_be", "e_be_rds"], f"flow: request edges out of order: {main}")
    rev = [p["edge"] for p in flow["steps"][-1]["path"]]
    require(rev == list(reversed(main)) and all(p["dir"] == "rev" for p in flow["steps"][-1]["path"]), "flow: the response must retrace the request path in reverse")


def static_checks(stages: list[dict]) -> None:
    """Syntax and reference checks for the generated and hand-written web assets (stdlib only)."""
    import xml.etree.ElementTree as ET
    from html.parser import HTMLParser

    # 1. SVG files are well-formed XML with unique ids
    for rel in ("docs/architecture.svg", "docs/roadmap.svg"):
        path = ROOT / rel
        if not path.exists():
            continue
        try:
            ET.parse(path)
        except ET.ParseError as exc:
            fail(f"{rel}: not well-formed XML: {exc}")
            continue
        ids = re.findall(r'\sid="([^"]+)"', path.read_text(encoding="utf-8"))
        dup = sorted({i for i in ids if ids.count(i) > 1})
        require(not dup, f"{rel}: duplicate ids {dup}")

    # 2. index.html: balanced tags, unique ids, resolvable anchors and relative references
    html_path = RM / "index.html"
    html = html_path.read_text(encoding="utf-8")
    void = {"meta", "link", "br", "input", "img", "hr", "source", "area", "base", "col", "embed", "track", "wbr"}
    stack: list[str] = []
    ids: list[str] = []

    class Balance(HTMLParser):
        def handle_starttag(self, tag, attrs):
            for k, v in attrs:
                if k == "id" and v:
                    ids.append(v)
            if tag not in void:
                stack.append(tag)

        def handle_startendtag(self, tag, attrs):  # self-closed (inline SVG)
            for k, v in attrs:
                if k == "id" and v:
                    ids.append(v)

        def handle_endtag(self, tag):
            if tag in void:
                return
            if not stack or stack[-1] != tag:
                fail(f"index.html: unexpected </{tag}> (open: {stack[-3:]})")
                if tag in stack:
                    while stack and stack.pop() != tag:
                        pass
            else:
                stack.pop()

    Balance().feed(html)
    require(not stack, f"index.html: unclosed tags {stack}")
    dup = sorted({i for i in ids if ids.count(i) > 1})
    require(not dup, f"index.html: duplicate ids {dup}")
    for target in re.findall(r'href="#([^"]+)"', html):
        require(target in ids, f"index.html: anchor #{target} has no target")
    for ref in re.findall(r'(?:href|src)="([^"#:]+)"', html):
        if not ref.startswith(("http", "mailto")):
            require((RM / ref).resolve().exists(), f"index.html: referenced file does not exist: {ref}")
    require("http://" not in html.replace("http://www.w3.org/2000/svg", "") and "https://" not in html, "index.html must not reference external URLs")

    # 3. CSS and JS: balanced braces, no external URLs, no network APIs
    css = (RM / "styles.css").read_text(encoding="utf-8")
    bare = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    require(bare.count("{") == bare.count("}"), "styles.css: unbalanced braces")
    require("@import" not in bare and "url(http" not in bare, "styles.css must not load external resources")
    require("prefers-reduced-motion" in bare, "styles.css must honor prefers-reduced-motion")
    js = (RM / "app.js").read_text(encoding="utf-8")
    for needle in ("fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "import(", "eval("):
        require(needle not in js, f"app.js must not use {needle}")
    require("matchMedia" in js and "prefers-reduced-motion" in js, "app.js must read the reduced-motion preference")

    # 4. README: roadmap before architecture, and its headline counts match the data
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    heads = [l for l in readme.splitlines() if l.startswith("## ")]
    require(heads[:2] == ["## Engineering Roadmap & Project Journey", "## Architecture"], f"README: first sections must be the roadmap then the architecture, got {heads[:2]}")
    cnt = counts(stages)
    require(f"**{cnt['verified']} of {cnt['total']} stages verified locally**" in readme, "README: headline status counts do not match docs/roadmap/roadmap.json")
    require(f"**{cnt['aws_verified']} of {cnt['total']} verified on AWS**" in readme, "README: AWS-verified count does not match docs/roadmap/roadmap.json")
    for rel in ("docs/roadmap.svg", "docs/architecture.svg", "docs/roadmap/index.html", "docs/ROADMAP.md", "docs/ARCHITECTURE.md"):
        require(f"]({rel}" in readme, f"README does not link {rel}")


def main() -> int:
    check = "--check" in sys.argv
    stages = json.loads((RM / "roadmap.json").read_text(encoding="utf-8"))["stages"]
    flow = json.loads((RM / "flow.json").read_text(encoding="utf-8"))
    facts = terraform_facts()
    validate_inputs(stages, flow)
    outputs = {
        DOCS / "architecture.svg": arch_svg(facts, standalone=True),
        DOCS / "roadmap.svg": roadmap_svg(stages),
        DOCS / "ROADMAP.md": roadmap_md(stages, facts),
        RM / "data.js": data_js(stages, flow, facts),
        RM / "index.html": index_html(facts),
    }
    for w in warnings:
        fail(w)
    static_checks(stages)
    if problems:
        print("Problems:")
        for p in dict.fromkeys(problems):
            print(f"  - {p}")
        return 1
    stale = []
    for path, content in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != content:
            stale.append(path.relative_to(ROOT).as_posix())
            if not check:
                path.write_text(content, encoding="utf-8", newline="\n")
    if check:
        if stale:
            print("Generated files are out of date (run: python scripts/build_visuals.py): " + ", ".join(stale))
            return 1
        print("visuals: Terraform facts match the diagram; generated files are up to date")
        return 0
    print("wrote: " + (", ".join(stale) if stale else "nothing (already up to date)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
