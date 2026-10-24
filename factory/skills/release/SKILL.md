---
name: release
description: Release this node's claims and mark it paused before taking the box offline for more than a day. Use when a member says "I'm going offline", "pause my node", or runs /factory:release.
---

# /factory:release

**Status: build order step 2 (not built). Until then: delete your own lock refs by hand
(`git push origin --delete refs/locks/issue-N` for each lock you hold) and set
`"status": "paused"` in your manifest on the `nodes` branch.**

What the script will do: stop every run loop on this box after its current strike, push
any partial `ticket/<id>/<handle>` branch, delete every lock ref this node holds (never one
it does not), write `status: paused` and a fresh `last_seen` to the manifest, push the
`nodes` branch. A node that skips this is `stale` after 24 h and `retired` after 7 days,
when the janitor revokes its token and releases its claims.
