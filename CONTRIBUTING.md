# Contributing to Luma Bar

Thanks for helping. Small, focused changes land faster than large rewrites.

Please also read:

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Open source / license](docs/OPEN_SOURCE.md)
- [Security policy](SECURITY.md)

## Before you start

1. Search [Issues](https://github.com/Linus-Shyu/Luma-Bar/issues) for duplicates.
2. For non-trivial work, open an issue first so we can align on scope.
3. Fork the repo and branch from `main`.

## Development

```bash
git clone https://github.com/YOUR_USER/Luma-Bar.git
cd Luma-Bar
swift build
./run.sh
```

Or build a local app bundle:

```bash
./build_app.sh
open "luma bar.app"
```

Needs **macOS 14+** and a Swift 6 toolchain. A notched MacBook is recommended for the full island layout.

## Pull requests

- One concern per PR (bug fix, feature, or docs).
- Prefer clear commit messages that explain *why*.
- Use the repository PR template: summary + test plan.
- Do **not** commit secrets, API keys, certificates, or local `.app` / build products.
- **Liquid Glass / island chrome is frozen.** Do not restyle glass fills, panel transparency, or related theme tokens unless maintainers explicitly ask.
- **Do not change GitHub Actions / release / notarization pipelines** (anything under `.github/workflows/`) unless maintainers request it.

## Bug reports

Include:

- macOS version and Mac model (notched or not)
- Luma Bar version / tag
- Steps to reproduce, expected vs actual
- Screenshots or a short screen recording when UI-related

## License

By contributing, you agree your contributions are licensed under the
[Apache License 2.0](LICENSE).
