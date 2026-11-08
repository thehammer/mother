# Strip `lease.offer.repo_path` before any network carrier (P2)

`coord/dispatch.go` fills `LeaseOffer.RepoPath` with the coordinator machine's checkout path. Fine on a local
Unix socket; before the protocol rides a network carrier (wss relay, P2) drop it from the offer (the worker
resolves the repo from `repo`), and keep it out of audit and status output.

Also for P2: the worker secret is handed over an inherited fd and held in memory, so a coordinator restart
needs the launcher to re-feed secrets (`--secrets-fd`); a network carrier needs a rotating credential.

Acceptance: no coordinator-local absolute path in any frame sent over a non-local carrier; test asserts it.
