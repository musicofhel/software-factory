STATUS: IN_PROGRESS

- [x] TB0: Register, tickets T6–T11, and the pinned tools on this box — `0391ae1`: register re-measured (bwrap needs a bound root; landlock via vetto doctor ABI 7); vetto 0.6.5, ralon 0.1.7, tamperguard 0.2.0, dcg v0.15.3, cux v0.4.1 installed user-space + pinned; fleet sandbox now MET (bubblewrap, refused=false), dry-run exit 0; ADR-0005 proposed (ralon -C/agent.lock, vetto --policy, no cux status --json, success reason=null, absolute pre-strike argv); T6–T11 created (+edges T6→T10, T9→T10 for merge-forecast co-change), doctor ok, coldstart gaps empty, merge-forecast exit 0; make test/lint exit 0 (records/TB0.md)
- [ ] TB1: Node policy: sandbox profiles, rails lock, destructive-command hook, adapter pins (ticket T6)
- [ ] TB2: Join wizard (ticket T7)
- [ ] TB3: Budget governor (ticket T8)
- [ ] TB4: Run loop and /factory:run (ticket T9)
- [ ] TB5: Step-1 rulings and follow-ups in code (ticket T10)
- [ ] TB6: Live smoke on this box and close-out (ticket T11)
