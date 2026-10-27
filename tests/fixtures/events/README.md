# GitHub event payloads (tests/test_gate_context.sh)

GitHub's own example webhook payloads, copied byte for byte. GitHub's webhook docs
(<https://docs.github.com/en/webhooks/webhook-events-and-payloads>, sections `pull_request` and
`merge_group`) render their examples from the `octokit/webhooks` repository, pinned here at commit
`aa80c24a3f55354465b8b1438d33dd5602956d0d`. The files were last changed there in
`bc5f6fd16b0df0e3058512e7d44dcba9ba3e0bb0` (2024-03-11).

The tests never edit these files. A case copies one and rewrites only what the test's own world
decides: the shas (onto a local repo), the head ref, the body and the author association. The fields
gate-context reads keep GitHub's names and nesting. The tests check every hash below, so a re-fetch that
changes a file fails until this table is updated.

| file | source (`https://raw.githubusercontent.com/octokit/webhooks/<commit>/…`) | sha256 |
|---|---|---|
| `pull_request-opened.json` | `payload-examples/api.github.com/pull_request/opened.payload.json` | `d34772e6b4b912586626b71101fd7e9f529943866c895dcb3381ec476003e834` |
| `pull_request-synchronize.json` | `payload-examples/api.github.com/pull_request/synchronize.payload.json` | `f44e3cd19cbaab487e59bfe89ce571661927247c229ccd051238c73f5c014792` |
| `merge_group-checks_requested.json` | `payload-examples/api.github.com/merge_group/checks_requested.payload.json` | `aad36521fd4aaa2398dd87a06ec1b4aca49b4be9d52ece82a91d104f50204874` |

Facts the gates rely on, read from these payloads:
- `pull_request`: `.pull_request.{number, base.sha, head.sha, head.ref, head.repo.full_name, user.login,
  author_association, body}`.
- `merge_group`: `.merge_group.{base_sha, head_sha, head_ref}`. The head ref is
  `refs/heads/gh-readonly-queue/main/pr-<N>-<sha>`. It carries no PR object, so gate-context reads PR
  N through `GET repos/<repo>/pulls/<N>`. That answer is the same pull-request object `pull_request`
  carries.
