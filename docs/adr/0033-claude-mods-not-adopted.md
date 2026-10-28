# ADR 0033 — Do not adopt Claude Mods; governance stays in the bash-hook layer

## Status

**Accepted** — 2026-10-28 (CEO-ratified). Claude Mods are not adopted for governance; governance stays in the bash-hook layer, with a narrow revisit condition. Resolves juvant-os-pm#174 (ARCH-020). Part of the 2026-Q4 platform-modernization backlog.

## Context

**Claude Mods** (shipped v2.1.287, Oct 2026) are TypeScript/JavaScript functions
distributed inside a plugin (a plugin with a `modules` key is a mod) that run
**before / after / instead-of / around** tool calls, permission requests, and
render events. Unlike hooks — which only react — a mod can rewrite prompts,
rewrite/retry/replace tool calls, approve or deny permissions, strip secrets from
tool output, and replace built-in UI. Two capabilities are directly attractive
for a governance-heavy framework:

- **`tool.check` with `decider: "person"`** — a hard human-in-the-loop gate where
  only a human / host callback may approve (cleaner than our confirmation-token
  deny-pattern dialogs).
- **Secret-stripping from tool output** — the use case FEAT-065 was reframed
  toward.

The decisive property, stated by Anthropic: **mods are NOT sandboxed; they
inherit Claude Code's full machine access.**

## Decision drivers

1. **Unsandboxed code in the trust base is a threat-model expansion.** The
   framework's thesis is structural safety through least privilege and one
   threat-model boundary per MCP server (handbook MCP-scope ADR; SYSTEM_INVARIANTS
   §4). A mod is arbitrary TS/JS with machine access running around *every* tool
   call — the opposite of least privilege, and far harder for the CSO 5-layer
   audit to reason about than a reviewed bash hook.
2. **It arrives via the plugin surface.** ADR 0031 deliberately keeps agents out
   of the plugin and treats the plugin as a supply-chain boundary the CSO reviews.
   A mod would be the single most powerful component on that surface — unsandboxed
   code the adopter installs — compounding the supply-chain concern.
3. **The hook layer already delivers the governance.** `pre-tool-use.sh`
   (deny-list, per-agent allow-list, single-writer gate Track 2d, scope guards
   2b/2c, sensitive-space 2e, guardrail tamper-floor 2f), the append-only audit
   log (Track 3), `onFailure:"block"` fail-closed (FEAT-061), and the confirmation
   tokens cover deny / least-privilege / audit / HITL today — in auditable bash,
   not arbitrary JS.
4. **The attractive bits don't justify the cost.** `decider:"person"` is cleaner
   HITL ergonomics but a marginal gain over the existing confirmation flow;
   secret-stripping is defense-in-depth already largely covered by the
   `permissions.deny` on `.env*`/`credentials*`. Neither warrants putting
   unsandboxed code in the trust base.

## Decision

1. **Do not adopt Claude Mods** in the framework. Governance remains in the
   bash-hook layer (`hooks/*.sh` + `bash-policy.json`) and the confirmation/audit
   tracks, consistent with the "structural safety lives in the hook, not in prompt
   friction / not in arbitrary code" posture.
2. **Narrow revisit condition.** Reopen only if **either** Anthropic ships a
   **sandboxed** mod capability (removing driver 1), **or** a concrete governance
   requirement arises that hooks provably cannot meet — and even then, scoped to
   the minimum capability, behind a CSO threat-model review and the handbook
   MCP-scope ADR, never as a blanket adoption.
3. **Record the decline.** This ADR exists so a future contributor who discovers
   mods understands they were evaluated and declined on threat-model grounds, not
   overlooked.

## Consequences

- **Positive:** the trust base stays bash + reviewed config; the CSO audit surface
  doesn't grow by an unsandboxed-code layer; no new supply-chain-critical plugin
  component.
- **Negative / watch:** we forgo `decider:"person"` HITL and mod-based
  secret-stripping — judged acceptable (existing confirmation + deny-list cover
  the need). Monitor whether a sandboxed-mod capability appears.
- **Reversible:** a pure "no + revisit-condition" — nothing is built to undo.

## Implementation

None. Reaffirms the existing hook-based governance. If the revisit condition
triggers, a successor ADR scopes the adoption.

## References

- ADR 0031 (plugin packaging — supply-chain boundary), handbook MCP-scope ADR,
  SYSTEM_INVARIANTS §4/§5. Mods docs: `code.claude.com/docs/en/plugins/mods`.
- FEAT-061/062/064 (bash-hook governance layer this decision keeps).
- juvant-os-pm#174 (ARCH-020); backlog `docs/modernization-2026q4-claude-platform.md`.
