# Changing the hard limits

The hooks (`framework/hooks/`) judge every call an agent makes. A change that blocks too much stops companies' everyday work; one that blocks too little is a security hole. Both have happened. Before releasing a change to the hooks, including adopter fixes:

1. **`bash tests/run.sh` is green.** It includes `tests/unit/test_skill_commands.py`: every command the skills, agents and `CLAUDE.md` tell an agent to run, and the everyday forms agents give them (commits with trailers, wrap-up, journal notes, dashboard), in a freshly installed company. When you add an instruction or meet a new everyday form, add it there; when an expected decision changes, say why in `EXPECTED`.
2. **Replay real commands** against the release before and the change, on the final code (not an earlier version of the change):

   ```
   python3 tests/replay-hook.py <company with the last release> <company with the change>
   ```

   Every command that becomes stricter is either intended (and covered by a test) or fixed. Every command that becomes looser is either an intended fix or a hole. Put the counts in the PR or release proposal; the commands themselves stay on your machine.
3. **An independent review** for anything that changes how commands are read, before a stable release.
4. **A release candidate first** when the change is broad (a new parser, a new kind of rule), installed with a real update in a test company.

No stable release of a hooks change without steps 1 and 2 on the final code.
