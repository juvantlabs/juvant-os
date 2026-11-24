# Tenant scope: a connected mailbox or file store is not the company's by default

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/tenant-scope.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: applies to the Microsoft 365 connector (Outlook, SharePoint/OneDrive, Teams); ownership is checked against the company's files instead of an onboarding block.

**Shared across skills.** The failure this prevents: a skill needs past
proposals, searches SharePoint, and the Microsoft 365 account attached to the
session belongs to a different organisation (a client's tenant where the CEO is
a guest, a previous employer, a personal account). The skill reads another
company's confidential documents and treats them as this company's. Nothing in
the connector says whose tenant it is.

## The rules

1. **A mailbox or file store is an input for the company's own data only.**
   Before the first read in a session, confirm it is the company's: the
   connected account's email domain matches the company's domain (from
   `memory/map.md`, `memory/knowledge/` or the role cards), or the CEO has named
   the mailbox, site or folder in this session. If nothing in the repo states
   the domain, or the account does not match, stop and ask in one line ("The
   Microsoft 365 account connected here is <account>; is that the company's, or
   should I work from files you give me?") and read nothing until the answer.
2. **Search by name, never browse.** Every SharePoint/OneDrive query carries the
   client name, the project name, or the site, library or file name that
   `memory/map.md` or the CEO gives. "Recent files" and unscoped folder listings
   are never a discovery path.
3. **A missing source never falls back to "look around".** No ledger, no CRM,
   no export means asking the CEO for the file or the figure. It never means
   searching the file store for something similar.
4. **Anything read from a mismatched store is discarded, not summarised.** If a
   read happened before the mismatch was noticed, say so, drop it from the
   working set and carry none of it into any output.
5. **Guest access is not ownership.** A Teams team or SharePoint site the CEO
   can see as a guest of a client belongs to that client. Read it only when the
   CEO names it for the task at hand, and never copy its content into
   `memory/`.

## Skills this governs

`proposal-builder` (past proposals and templates from SharePoint/OneDrive),
`inbox-manager`, `business-pulse`, `monday-brief`, and every other skill that
reads Outlook, SharePoint, OneDrive or Teams.
