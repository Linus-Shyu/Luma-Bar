# Open source

Luma Bar is an **open-source** native macOS project.

## License

The source code in this repository is licensed under the
[Apache License 2.0](../LICENSE).

That means you may:

- use, study, modify, and redistribute the software
- use it in personal or commercial products
- keep derivatives private or open them

subject to the Apache-2.0 terms (including retaining copyright / license notices
and the patent grant / trademark limits described in the license).

Attribution notices live in [`NOTICE`](../NOTICE).

## Why Apache 2.0

We follow the same permissive style used by many modern open-source SDKs and
reference projects (including OpenAI’s public libraries): a clear copyright
grant, an explicit patent grant, and a trademark reservation so the name
“Luma Bar” is not freely usable as a brand simply because the code is open.

Earlier tags may have shipped under a proprietary or MIT notice. Current `main`
and releases from **v1.0.2** onward are Apache-2.0.

## What is in scope

| Included | Notes |
|---|---|
| Application source under `Sources/` | Primary product code |
| Build / packaging scripts (`build_app.sh`, `scripts/` helpers) | Except local secrets |
| Docs, templates, issue / PR templates | Community docs |
| App icons and in-repo screenshots under `docs/images/` | As redistributable project assets |

| Not in the repo (by design) | Notes |
|---|---|
| API keys, notary credentials, signing secrets | Local / CI secrets only |
| `BundledAgentSecrets.swift` | Gitignored; use the example stub |
| Third-party app data (Cursor / NetEase DBs, etc.) | Read at runtime on your Mac |

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md), [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md),
and [SECURITY.md](../SECURITY.md).

**Release CI / notarization workflows are maintained by the core team.** Please
do not open PRs that rewrite `.github/workflows/` unless maintainers ask.

## Historical commercial docs

Files such as `docs/COMMERCIALIZATION.md` and `docs/GO_TO_MARKET.md` may still
describe older product experiments. They are **not** the license of this
repository. When in doubt, `LICENSE` + `NOTICE` win.
