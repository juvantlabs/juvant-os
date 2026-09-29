#!/usr/bin/env python3
"""
tests/verify-canon.py — Canon coherence verifier (decisions#275).

Verifies that identifiers named in adopter canon files exist in the paired
system surface: schema allowlists, GitHub ProjectV2 fields, GitHub
milestones, GitHub GraphQL mutation names, agent role slugs, MCP server
names, and Turso DB names.

Mechanism ships upstream (juvantlabs/juvant-os); adopter configures via
.juvant/config.json → canon_verification block. Upstream repo has no
adopter config — verifier exits 0 (not enabled) when config is absent or
canon_verification.enabled is false.

Usage:
  python3 tests/verify-canon.py             # normal run (reads .juvant/config.json)
  python3 tests/verify-canon.py --self-test # fixture-based tests; no config needed
  python3 tests/verify-canon.py --json      # also write structured JSON to
                                             # canon-coherence-results.json
  python3 tests/verify-canon.py --config PATH  # override config file path

Exit: 0 = all pass or not enabled; 1 = any FAIL

Nine perimeter check classes (decisions#275 §PERIMETER):
  1  decisions_category      → decisions.category allowlist (schema.sql)
  2  decisions_status        → decisions.status enum
  3  knowledge_base_category → knowledge_base.category enum
  4  gh_project_fields       → GitHub ProjectV2 field names (gh api graphql)
  5  gh_milestones           → GitHub milestone titles (gh api REST)
  6  gh_mutations            → GitHub GraphQL mutation names (gh api graphql)
  7  agent_role_slugs        → agents/ inventory
  8  mcp_server_names        → .claude/settings.json + docs/MCP_INVENTORY.md
  9  turso_db_names          → turso db list

Out-of-scope (decisions#275 §LIMIT): prose semantics, SQL statement
fragments, section anchors, file-path existence, cross-adopter divergence.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent


# ─────────────────────────────────────────────────────────────────────────────
# Schema parsing
# ─────────────────────────────────────────────────────────────────────────────

def _parse_category_allowlist(schema_sql: str) -> frozenset[str]:
    """Extract decisions.category allowlist from the schema.sql trigger body.

    Reuses the same extraction pattern as tests/schema/validate.py (BUG-063)
    so both guards stay in sync with the same source of truth.
    """
    cat_re = re.compile(r"NEW\.category NOT IN \((.*?)\)", re.S)
    val_re = re.compile(r"'([a-z][a-z-]*)'")
    matches = cat_re.findall(schema_sql)
    if not matches:
        return frozenset()
    return frozenset(val_re.findall(matches[0]))


# ─────────────────────────────────────────────────────────────────────────────
# Data types
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class CheckResult:
    claim: str
    source_location: str
    system_surface: str
    verdict: str   # 'pass' | 'fail' | 'unknown'
    detail: str = ""


# ─────────────────────────────────────────────────────────────────────────────
# Known enums (no trigger CHECK constraint in schema; authoritative via comment)
# ─────────────────────────────────────────────────────────────────────────────

_DECISIONS_STATUS_SET = frozenset({
    "proposed", "approved", "rejected", "executed", "superseded"
})

_KB_CATEGORY_SET = frozenset({
    "strategic", "technical", "skill", "research"
})


# ─────────────────────────────────────────────────────────────────────────────
# Identifier shape patterns
# ─────────────────────────────────────────────────────────────────────────────

_BACKTICK_RE = re.compile(r"`([^`\n]+)`")

# Category / role / MCP server names: kebab-case, lowercase alpha + hyphens, 3+ chars
_KEBAB_RE = re.compile(r"^[a-z][a-z-]{2,}$")
# Status / kb-category values: single lowercase word, 3+ chars, no hyphens
_WORD_RE = re.compile(r"^[a-z]{3,}$")
# GitHub ProjectV2 field names: Title Case or PascalCase, 2+ chars
_FIELD_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 ]{1,}$")
# GraphQL mutation names: camelCase starting with lowercase
_MUTATION_NAME_RE = re.compile(r"^[a-z][a-zA-Z0-9]{2,}$")
# Turso DB names: kebab-case, may include digits
_DB_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{2,}$")


# ─────────────────────────────────────────────────────────────────────────────
# Context classification — 150-char window each side of each span
# ─────────────────────────────────────────────────────────────────────────────

_CTX: dict[str, re.Pattern[str]] = {
    "decisions_category":      re.compile(
        r"decisions?\.category|category\s+[`'\"]", re.I
    ),
    "decisions_status":        re.compile(
        r"decisions?\.status|\.status\s*[=:to\s]|status\s+[`'\"]", re.I
    ),
    "knowledge_base_category": re.compile(
        r"knowledge_base\.category|kb\.category", re.I
    ),
    "gh_project_fields":       re.compile(
        r"board\s+field|project.*?field|github.*?field", re.I
    ),
    "gh_milestones":           re.compile(r"milestone", re.I),
    "gh_mutations":            re.compile(r"\bmutation\b|graphql", re.I),
    "agent_role_slugs":        re.compile(
        r"agent.*?role|role.*?slug|agent\s+[`'\"]", re.I
    ),
    "mcp_server_names":        re.compile(r"mcp.*?server|mcpServer", re.I),
    "turso_db_names":          re.compile(r"turso\s+db|turso.*?database|db\s+name", re.I),
}


# ─────────────────────────────────────────────────────────────────────────────
# Subprocess helper
# ─────────────────────────────────────────────────────────────────────────────

def _run(*args: str) -> tuple[int, str]:
    """Run a command. Returns (returncode, stdout); (-1, message) on error."""
    try:
        r = subprocess.run(list(args), capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return -1, str(exc)


# ─────────────────────────────────────────────────────────────────────────────
# Canon extraction
# ─────────────────────────────────────────────────────────────────────────────

def extract_spans(text: str, filepath: str) -> list[tuple[str, str, str]]:
    """Extract backtick code spans with surrounding context.

    Returns [(span, context_window, source_location), ...].
    The context window is 150 chars on each side of the span — wide enough
    to capture 'decisions.category' immediately before a span like
    `gh-execution-confirmed`, without pulling in unrelated text.
    """
    results = []
    for m in _BACKTICK_RE.finditer(text):
        span = m.group(1).strip()
        if not span:
            continue
        start = max(0, m.start() - 150)
        end = min(len(text), m.end() + 150)
        context = text[start:end]
        line_no = text[: m.start()].count("\n") + 1
        results.append((span, context, f"{filepath}:{line_no}"))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 1 — decisions.category
# ─────────────────────────────────────────────────────────────────────────────

def check_decisions_category(
    spans: list[tuple[str, str, str]],
    allowlist: frozenset[str],
) -> list[CheckResult]:
    """Class 1: kebab-case spans in a 'decisions.category' context.

    Acceptance test (decisions#275): canon §9 prescribed
    `gh-execution-confirmed` — the trigger allowlist rejects it. This
    check must produce verdict=fail for that span.
    """
    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _KEBAB_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["decisions_category"].search(ctx):
            continue
        seen.add(span)
        if span in allowlist:
            results.append(CheckResult(
                span, loc, "decisions.category allowlist (schema.sql)", "pass"
            ))
        else:
            results.append(CheckResult(
                span, loc, "decisions.category allowlist (schema.sql)", "fail",
                f"'{span}' absent from decisions.category allowlist — "
                "this category will be rejected by the schema trigger"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 2 — decisions.status
# ─────────────────────────────────────────────────────────────────────────────

def check_decisions_status(
    spans: list[tuple[str, str, str]],
) -> list[CheckResult]:
    """Class 2: single-word spans in a 'decisions.status' context."""
    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _WORD_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["decisions_status"].search(ctx):
            continue
        seen.add(span)
        if span in _DECISIONS_STATUS_SET:
            results.append(CheckResult(
                span, loc, "decisions.status enum", "pass"
            ))
        else:
            results.append(CheckResult(
                span, loc, "decisions.status enum", "fail",
                f"'{span}' not in decisions.status enum "
                f"({sorted(_DECISIONS_STATUS_SET)})"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 3 — knowledge_base.category
# ─────────────────────────────────────────────────────────────────────────────

def check_kb_category(
    spans: list[tuple[str, str, str]],
) -> list[CheckResult]:
    """Class 3: single-word spans in a 'knowledge_base.category' context."""
    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _WORD_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["knowledge_base_category"].search(ctx):
            continue
        seen.add(span)
        if span in _KB_CATEGORY_SET:
            results.append(CheckResult(
                span, loc, "knowledge_base.category enum", "pass"
            ))
        else:
            results.append(CheckResult(
                span, loc, "knowledge_base.category enum", "fail",
                f"'{span}' not in knowledge_base.category enum "
                f"({sorted(_KB_CATEGORY_SET)})"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 4 — GitHub ProjectV2 field names
# ─────────────────────────────────────────────────────────────────────────────

def check_gh_project_fields(
    spans: list[tuple[str, str, str]],
    gh_project_id: Optional[str],
    _mock_field_names: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 4: field-name spans in a 'board field' / 'project field' context.

    Requires gh_project_id in config. Pass _mock_field_names in self-test.
    """
    if _mock_field_names is not None:
        field_names: frozenset[str] = _mock_field_names
    elif gh_project_id:
        query = (
            "query($id:ID!){node(id:$id){...on ProjectV2{"
            "fields(first:50){nodes{"
            "...on ProjectV2Field{name}"
            "...on ProjectV2IterationField{name}"
            "...on ProjectV2SingleSelectField{name}"
            "}}}}}"
        )
        rc, out = _run(
            "gh", "api", "graphql",
            "-f", f"query={query}", "-f", f"id={gh_project_id}"
        )
        if rc != 0:
            return [CheckResult(
                "gh_project_fields", "gh api", "GitHub ProjectV2 fields",
                "unknown", f"gh api call failed (rc={rc})"
            )]
        try:
            data = json.loads(out)
            nodes = data["data"]["node"]["fields"]["nodes"]
            field_names = frozenset(n.get("name", "") for n in nodes if n)
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            return [CheckResult(
                "gh_project_fields", "gh api", "GitHub ProjectV2 fields",
                "unknown", str(exc)
            )]
    else:
        return []

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _FIELD_NAME_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["gh_project_fields"].search(ctx):
            continue
        seen.add(span)
        if span in field_names:
            results.append(CheckResult(span, loc, "GitHub ProjectV2 fields", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "GitHub ProjectV2 fields", "fail",
                f"'{span}' not found in project {gh_project_id} fields"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 5 — GitHub milestone titles
# ─────────────────────────────────────────────────────────────────────────────

def check_gh_milestones(
    spans: list[tuple[str, str, str]],
    github_repos: list[str],
    _mock_milestones: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 5: any spans in a 'milestone' context vs. live GitHub milestones."""
    if _mock_milestones is not None:
        all_milestones: frozenset[str] = _mock_milestones
    elif github_repos:
        ms: set[str] = set()
        for repo in github_repos:
            rc, out = _run(
                "gh", "api", f"/repos/{repo}/milestones",
                "--jq", ".[].title"
            )
            if rc == 0:
                ms.update(t.strip() for t in out.splitlines() if t.strip())
        if not ms:
            return [CheckResult(
                "gh_milestones", "gh api", "GitHub milestones", "unknown",
                "no milestones retrieved — check gh auth and repos list"
            )]
        all_milestones = frozenset(ms)
    else:
        return []

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if span in seen:
            continue
        if not _CTX["gh_milestones"].search(ctx):
            continue
        seen.add(span)
        if span in all_milestones:
            results.append(CheckResult(span, loc, "GitHub milestones", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "GitHub milestones", "fail",
                f"'{span}' not found in milestones for {github_repos}"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 6 — GitHub GraphQL mutation names
# ─────────────────────────────────────────────────────────────────────────────

def check_gh_mutations(
    spans: list[tuple[str, str, str]],
    _mock_mutations: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 6: camelCase spans in a 'mutation' / 'graphql' context."""
    if _mock_mutations is not None:
        mutation_names: frozenset[str] = _mock_mutations
    else:
        query = "{ __schema { mutationType { fields { name } } } }"
        rc, out = _run("gh", "api", "graphql", "-f", f"query={query}")
        if rc != 0:
            return [CheckResult(
                "gh_mutations", "gh api", "GitHub GraphQL mutations",
                "unknown", f"gh api call failed (rc={rc})"
            )]
        try:
            data = json.loads(out)
            mutation_names = frozenset(
                f["name"]
                for f in data["data"]["__schema"]["mutationType"]["fields"]
            )
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            return [CheckResult(
                "gh_mutations", "gh api", "GitHub GraphQL mutations",
                "unknown", str(exc)
            )]

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _MUTATION_NAME_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["gh_mutations"].search(ctx):
            continue
        seen.add(span)
        if span in mutation_names:
            results.append(CheckResult(span, loc, "GitHub GraphQL mutations", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "GitHub GraphQL mutations", "fail",
                f"'{span}' not in GitHub GraphQL mutation schema"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 7 — agent role slugs
# ─────────────────────────────────────────────────────────────────────────────

def check_agent_role_slugs(
    spans: list[tuple[str, str, str]],
    repo_root: Path,
    _mock_slugs: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 7: kebab-case spans in an 'agent role' context vs. agents/ inventory."""
    if _mock_slugs is not None:
        agent_slugs: frozenset[str] = _mock_slugs
    else:
        agents_dir = repo_root / "agents"
        if not agents_dir.is_dir():
            return [CheckResult(
                "agent_role_slugs", "agents/", "agents/ inventory",
                "unknown", "agents/ directory not found"
            )]
        slugs: set[str] = set()
        for p in agents_dir.rglob("*.md"):
            slugs.add(p.stem)
        for p in agents_dir.iterdir():
            if p.is_dir():
                slugs.add(p.name)
        agent_slugs = frozenset(slugs)

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _KEBAB_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["agent_role_slugs"].search(ctx):
            continue
        seen.add(span)
        if span in agent_slugs:
            results.append(CheckResult(span, loc, "agents/ inventory", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "agents/ inventory", "fail",
                f"'{span}' not found in agents/ inventory"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 8 — MCP server names
# ─────────────────────────────────────────────────────────────────────────────

def check_mcp_server_names(
    spans: list[tuple[str, str, str]],
    repo_root: Path,
    _mock_names: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 8: kebab-case spans in an 'MCP server' context vs. the registry."""
    if _mock_names is not None:
        mcp_names: frozenset[str] = _mock_names
    else:
        names: set[str] = set()
        settings_path = repo_root / ".claude" / "settings.json"
        if settings_path.exists():
            try:
                data = json.loads(settings_path.read_text())
                names.update(data.get("mcpServers", {}).keys())
            except (json.JSONDecodeError, OSError):
                pass
        inventory_path = repo_root / "docs" / "MCP_INVENTORY.md"
        if inventory_path.exists():
            for m in _BACKTICK_RE.finditer(inventory_path.read_text()):
                s = m.group(1).strip()
                if _KEBAB_RE.fullmatch(s):
                    names.add(s)
        if not names:
            return [CheckResult(
                "mcp_server_names", ".claude/settings.json",
                "mcpServers registry", "unknown",
                "no MCP server names found in settings.json or docs/MCP_INVENTORY.md"
            )]
        mcp_names = frozenset(names)

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _KEBAB_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["mcp_server_names"].search(ctx):
            continue
        seen.add(span)
        if span in mcp_names:
            results.append(CheckResult(span, loc, "mcpServers registry", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "mcpServers registry", "fail",
                f"'{span}' not found in mcpServers registry"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Check class 9 — Turso DB names
# ─────────────────────────────────────────────────────────────────────────────

def check_turso_db_names(
    spans: list[tuple[str, str, str]],
    _mock_db_names: Optional[frozenset[str]] = None,
) -> list[CheckResult]:
    """Class 9: kebab-case spans in a 'turso db' context vs. turso db list."""
    if _mock_db_names is not None:
        db_names: frozenset[str] = _mock_db_names
    else:
        try:
            r = subprocess.run(
                ["turso", "db", "list"],
                capture_output=True, text=True, timeout=30
            )
            if r.returncode != 0:
                raise RuntimeError(r.stderr.strip() or "non-zero exit")
            # Output: header line then rows; first token on each row = DB name.
            lines = r.stdout.splitlines()
            db_names = frozenset(
                ln.split()[0]
                for ln in lines
                if ln.split() and not ln.split()[0].upper().startswith("NAME")
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, RuntimeError) as exc:
            return [CheckResult(
                "turso_db_names", "turso cli", "turso db list",
                "unknown", f"turso cli unavailable: {exc}"
            )]

    results = []
    seen: set[str] = set()
    for span, ctx, loc in spans:
        if not _DB_NAME_RE.fullmatch(span):
            continue
        if span in seen:
            continue
        if not _CTX["turso_db_names"].search(ctx):
            continue
        seen.add(span)
        if span in db_names:
            results.append(CheckResult(span, loc, "turso db list", "pass"))
        else:
            results.append(CheckResult(
                span, loc, "turso db list", "fail",
                f"'{span}' not found in turso db list"
            ))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Main runner
# ─────────────────────────────────────────────────────────────────────────────

def run_canon_checks(
    canon_paths: list[Path],
    allowlist: frozenset[str],
    check_classes: list[str],
    gh_project_id: Optional[str],
    github_repos: list[str],
    repo_root: Path,
) -> list[CheckResult]:
    """Run all enabled check classes over the provided canon files."""
    all_spans: list[tuple[str, str, str]] = []
    for cp in canon_paths:
        if not cp.exists():
            print(f"  WARN: canon path not found: {cp}")
            continue
        all_spans.extend(extract_spans(cp.read_text(), str(cp)))

    all_results: list[CheckResult] = []
    class_set = set(check_classes)

    if "decisions_category" in class_set:
        all_results.extend(check_decisions_category(all_spans, allowlist))
    if "decisions_status" in class_set:
        all_results.extend(check_decisions_status(all_spans))
    if "knowledge_base_category" in class_set:
        all_results.extend(check_kb_category(all_spans))
    if "gh_project_fields" in class_set:
        all_results.extend(check_gh_project_fields(all_spans, gh_project_id))
    if "gh_milestones" in class_set:
        all_results.extend(check_gh_milestones(all_spans, github_repos))
    if "gh_mutations" in class_set:
        all_results.extend(check_gh_mutations(all_spans))
    if "agent_role_slugs" in class_set:
        all_results.extend(check_agent_role_slugs(all_spans, repo_root))
    if "mcp_server_names" in class_set:
        all_results.extend(check_mcp_server_names(all_spans, repo_root))
    if "turso_db_names" in class_set:
        all_results.extend(check_turso_db_names(all_spans))

    return all_results


# ─────────────────────────────────────────────────────────────────────────────
# Self-test fixtures — one PASS and one FAIL per check class
# ─────────────────────────────────────────────────────────────────────────────

# Class 1: decisions.category
_FX_CAT_FAIL = (
    "Record the outcome by setting decisions.category to "
    "`gh-execution-confirmed` once the step completes."
)
_FX_CAT_PASS = (
    "Open a new row with decisions.category set to `pr-spec` "
    "once the PR is ready for review."
)

# Class 2: decisions.status
_FX_STATUS_FAIL = (
    "Transition decisions.status to `pending` when the item is queued."
)
_FX_STATUS_PASS = (
    "Transition decisions.status to `proposed` at intake."
)

# Class 3: knowledge_base.category
_FX_KB_FAIL = (
    "Assign knowledge_base.category `process` for workflow entries."
)
_FX_KB_PASS = (
    "Assign knowledge_base.category `technical` for architecture notes."
)

# Class 4: GH project fields (mock surface)
_FX_FIELD_FAIL = (
    "Set the board field `NonExistentField` to the current iteration."
)
_FX_FIELD_PASS = (
    "Set the board field `Status` to Done when the PR merges."
)
_MOCK_FIELDS = frozenset({"Status", "Priority", "Iteration", "Assignees", "Milestone"})

# Class 5: GH milestones (mock surface)
_FX_MILESTONE_FAIL = (
    "Attach milestone `ghost-milestone-xyz` to every open issue in this wave."
)
_FX_MILESTONE_PASS = (
    "Attach milestone `v1.0` to every open issue in this wave."
)
_MOCK_MILESTONES = frozenset({"v1.0", "v1.1", "v2.0", "MVP"})

# Class 6: GH mutations (mock surface)
_FX_MUTATION_FAIL = (
    "Execute GraphQL mutation `nonExistentMutation` to link the item."
)
_FX_MUTATION_PASS = (
    "Execute GraphQL mutation `addProjectV2ItemById` to link the item."
)
_MOCK_MUTATIONS = frozenset({
    "addProjectV2ItemById",
    "updateProjectV2ItemFieldValue",
    "createIssue",
})

# Class 7: agent role slugs (mock surface)
_FX_AGENT_FAIL = (
    "Route to agent role `ghost-agent-xyz` for the final review step."
)
_FX_AGENT_PASS = (
    "Route to agent role `eng-platform` for the infra review step."
)
_MOCK_AGENT_SLUGS = frozenset({
    "eng-platform", "arch", "shield", "sage", "theos", "cos",
})

# Class 8: MCP server names (mock surface)
_FX_MCP_FAIL = (
    "Call MCP server `ghost-mcp-server` to retrieve the resource."
)
_FX_MCP_PASS = (
    "Call MCP server `github` to retrieve the repository metadata."
)
_MOCK_MCP_NAMES = frozenset({"github", "m365-graph", "turso", "computer-use"})

# Class 9: Turso DB names (mock surface)
_FX_TURSO_FAIL = (
    "Initialize turso db `ghost-db-xyz` at bootstrap."
)
_FX_TURSO_PASS = (
    "Initialize turso db `company-juvant` at bootstrap."
)
_MOCK_DB_NAMES = frozenset({"company-juvant", "project-hardys", "project-dog-ai"})


# ─────────────────────────────────────────────────────────────────────────────
# Self-test runner
# ─────────────────────────────────────────────────────────────────────────────

def run_self_tests(allowlist: frozenset[str]) -> tuple[int, int]:
    """Run fixture-based self-tests. Returns (passes, fails).

    Covers all 9 check classes with one PASS and one FAIL fixture each.
    The acceptance test (decisions#275 trigger case) is class 1 FAIL:
    `gh-execution-confirmed` must produce verdict=fail.
    """
    passes = 0
    fails: list[str] = []

    def assert_result(
        results: list[CheckResult],
        expected_verdict: str,
        test_name: str,
    ) -> None:
        nonlocal passes
        if not results:
            print(f"  FAIL: {test_name} — no spans extracted from fixture")
            fails.append(test_name)
            return
        actual = results[0].verdict
        if actual == expected_verdict:
            passes += 1
            print(f"  PASS: {test_name}")
        else:
            detail = results[0].detail or ""
            print(f"  FAIL: {test_name}")
            print(f"    expected={expected_verdict!r} got={actual!r}")
            if detail:
                print(f"    detail: {detail}")
            fails.append(test_name)

    # ── Class 1: decisions.category ─────────────────────────────────────────
    print("\n=== self-test: class 1 — decisions.category ===")

    spans = extract_spans(_FX_CAT_FAIL, "fixture:1-fail")
    r = check_decisions_category(spans, allowlist)
    assert_result(r, "fail",
                  "gh-execution-confirmed absent from allowlist  [ACCEPTANCE TEST]")

    spans = extract_spans(_FX_CAT_PASS, "fixture:1-pass")
    r = check_decisions_category(spans, allowlist)
    assert_result(r, "pass", "pr-spec present in allowlist")

    # ── Class 2: decisions.status ────────────────────────────────────────────
    print("\n=== self-test: class 2 — decisions.status ===")

    spans = extract_spans(_FX_STATUS_FAIL, "fixture:2-fail")
    r = check_decisions_status(spans)
    assert_result(r, "fail", "'pending' not in status enum")

    spans = extract_spans(_FX_STATUS_PASS, "fixture:2-pass")
    r = check_decisions_status(spans)
    assert_result(r, "pass", "'proposed' in status enum")

    # ── Class 3: knowledge_base.category ─────────────────────────────────────
    print("\n=== self-test: class 3 — knowledge_base.category ===")

    spans = extract_spans(_FX_KB_FAIL, "fixture:3-fail")
    r = check_kb_category(spans)
    assert_result(r, "fail", "'process' not in kb.category enum")

    spans = extract_spans(_FX_KB_PASS, "fixture:3-pass")
    r = check_kb_category(spans)
    assert_result(r, "pass", "'technical' in kb.category enum")

    # ── Class 4: GH project fields ───────────────────────────────────────────
    print("\n=== self-test: class 4 — gh_project_fields ===")

    spans = extract_spans(_FX_FIELD_FAIL, "fixture:4-fail")
    r = check_gh_project_fields(spans, None, _mock_field_names=_MOCK_FIELDS)
    assert_result(r, "fail", "NonExistentField not in mock field set")

    spans = extract_spans(_FX_FIELD_PASS, "fixture:4-pass")
    r = check_gh_project_fields(spans, None, _mock_field_names=_MOCK_FIELDS)
    assert_result(r, "pass", "Status in mock field set")

    # ── Class 5: GH milestones ───────────────────────────────────────────────
    print("\n=== self-test: class 5 — gh_milestones ===")

    spans = extract_spans(_FX_MILESTONE_FAIL, "fixture:5-fail")
    r = check_gh_milestones(spans, [], _mock_milestones=_MOCK_MILESTONES)
    assert_result(r, "fail", "ghost-milestone-xyz not in mock milestone set")

    spans = extract_spans(_FX_MILESTONE_PASS, "fixture:5-pass")
    r = check_gh_milestones(spans, [], _mock_milestones=_MOCK_MILESTONES)
    assert_result(r, "pass", "v1.0 in mock milestone set")

    # ── Class 6: GH mutations ────────────────────────────────────────────────
    print("\n=== self-test: class 6 — gh_mutations ===")

    spans = extract_spans(_FX_MUTATION_FAIL, "fixture:6-fail")
    r = check_gh_mutations(spans, _mock_mutations=_MOCK_MUTATIONS)
    assert_result(r, "fail", "nonExistentMutation not in mock mutation set")

    spans = extract_spans(_FX_MUTATION_PASS, "fixture:6-pass")
    r = check_gh_mutations(spans, _mock_mutations=_MOCK_MUTATIONS)
    assert_result(r, "pass", "addProjectV2ItemById in mock mutation set")

    # ── Class 7: agent role slugs ─────────────────────────────────────────────
    print("\n=== self-test: class 7 — agent_role_slugs ===")

    spans = extract_spans(_FX_AGENT_FAIL, "fixture:7-fail")
    r = check_agent_role_slugs(spans, ROOT, _mock_slugs=_MOCK_AGENT_SLUGS)
    assert_result(r, "fail", "ghost-agent-xyz not in mock agent slug set")

    spans = extract_spans(_FX_AGENT_PASS, "fixture:7-pass")
    r = check_agent_role_slugs(spans, ROOT, _mock_slugs=_MOCK_AGENT_SLUGS)
    assert_result(r, "pass", "eng-platform in mock agent slug set")

    # ── Class 8: MCP server names ─────────────────────────────────────────────
    print("\n=== self-test: class 8 — mcp_server_names ===")

    spans = extract_spans(_FX_MCP_FAIL, "fixture:8-fail")
    r = check_mcp_server_names(spans, ROOT, _mock_names=_MOCK_MCP_NAMES)
    assert_result(r, "fail", "ghost-mcp-server not in mock MCP name set")

    spans = extract_spans(_FX_MCP_PASS, "fixture:8-pass")
    r = check_mcp_server_names(spans, ROOT, _mock_names=_MOCK_MCP_NAMES)
    assert_result(r, "pass", "github in mock MCP name set")

    # ── Class 9: Turso DB names ───────────────────────────────────────────────
    print("\n=== self-test: class 9 — turso_db_names ===")

    spans = extract_spans(_FX_TURSO_FAIL, "fixture:9-fail")
    r = check_turso_db_names(spans, _mock_db_names=_MOCK_DB_NAMES)
    assert_result(r, "fail", "ghost-db-xyz not in mock DB name set")

    spans = extract_spans(_FX_TURSO_PASS, "fixture:9-pass")
    r = check_turso_db_names(spans, _mock_db_names=_MOCK_DB_NAMES)
    assert_result(r, "pass", "company-juvant in mock DB name set")

    return passes, len(fails)


# ─────────────────────────────────────────────────────────────────────────────
# CLI entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Canon coherence verifier (decisions#275)"
    )
    parser.add_argument(
        "--config",
        default=".juvant/config.json",
        help="path to config file (default: .juvant/config.json)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="write structured results to canon-coherence-results.json",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        dest="self_test",
        help="run fixture-based self-tests without reading config or canon files",
    )
    args = parser.parse_args()

    # Load category allowlist from schema.sql (same parse as BUG-063)
    schema_path = ROOT / "scripts" / "schema.sql"
    if schema_path.exists():
        allowlist = _parse_category_allowlist(schema_path.read_text())
    else:
        allowlist = frozenset()
        print("WARN: scripts/schema.sql not found — class 1 check will yield no results")

    # ── Self-test mode ────────────────────────────────────────────────────────
    if args.self_test:
        print("=== verify-canon.py self-test ===")
        passes, fail_count = run_self_tests(allowlist)
        print("\n===================================================")
        total = passes + fail_count
        print(f"Total: {total} · Passed: {passes} · Failed: {fail_count}")
        return 1 if fail_count else 0

    # ── Normal mode ───────────────────────────────────────────────────────────
    config_path = Path(args.config)
    if not config_path.exists():
        print(
            f"verify-canon: config not found at {config_path} "
            f"(canon_verification not enabled)"
        )
        return 0

    try:
        config_data = json.loads(config_path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        print(f"verify-canon: cannot read config: {exc}")
        return 1

    cv = config_data.get("canon_verification", {})
    if not cv.get("enabled", False):
        print("verify-canon: canon_verification.enabled=false — nothing to check")
        return 0

    canon_paths = [Path(p) for p in cv.get("canon_paths", [])]
    if not canon_paths:
        print("verify-canon: canon_verification.canon_paths is empty — nothing to check")
        return 0

    check_classes: list[str] = cv.get("check_classes", [
        "decisions_category", "decisions_status", "knowledge_base_category",
        "gh_project_fields", "gh_milestones", "gh_mutations",
        "agent_role_slugs", "mcp_server_names", "turso_db_names",
    ])
    gh_project_id: Optional[str] = cv.get("gh_project_id")
    github_repos: list[str] = config_data.get("github_repos", [])

    print("=== verify-canon: canon coherence check ===")
    print(f"Canon paths : {[str(p) for p in canon_paths]}")
    print(f"Check classes: {check_classes}")

    results = run_canon_checks(
        canon_paths=canon_paths,
        allowlist=allowlist,
        check_classes=check_classes,
        gh_project_id=gh_project_id,
        github_repos=github_repos,
        repo_root=ROOT,
    )

    # Report
    passes = 0
    fail_count = 0
    unknown_count = 0
    for res in results:
        if res.verdict == "pass":
            passes += 1
            print(f"  PASS [{res.system_surface}]: {res.claim}  ({res.source_location})")
        elif res.verdict == "fail":
            fail_count += 1
            print(f"  FAIL [{res.system_surface}]: {res.claim}  ({res.source_location})")
            if res.detail:
                print(f"    {res.detail}")
        else:
            unknown_count += 1
            print(f"  UNKN [{res.system_surface}]: {res.claim}  ({res.source_location})")
            if res.detail:
                print(f"    {res.detail}")

    print("\n===================================================")
    total = passes + fail_count + unknown_count
    print(
        f"Total claims: {total}  "
        f"Pass: {passes}  Fail: {fail_count}  Unknown: {unknown_count}"
    )

    if args.json:
        out_path = Path("canon-coherence-results.json")
        out_path.write_text(
            json.dumps([asdict(r) for r in results], indent=2)
        )
        print(f"Structured results written to {out_path}")

    return 1 if fail_count else 0


if __name__ == "__main__":
    sys.exit(main())
