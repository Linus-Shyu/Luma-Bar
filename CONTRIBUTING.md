# Contributing to Luma Bar

Thanks for helping. Small, focused changes land faster than large rewrites.

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

## Pull requests

- One concern per PR (bugfix, feature, or docs).
- Prefer clear commit messages that explain *why*.
- Do **not** commit secrets, API keys, or local `.app` / build products.
- **Liquid Glass / island chrome is frozen.** Do not restyle glass fills, panel transparency, or related theme tokens unless maintainers explicitly ask.
- Do not change GitHub Actions release pipelines unless maintainers request it.

## Bug reports

Include:

- macOS version and Mac model (notched or not)
- Luma Bar version / tag
- Steps to reproduce, expected vs actual
- Screenshots or a short screen recording when UI-related

## Code of collaboration

Be respectful. Assume good intent. We follow a lightweight [Contributor Covenant](https://www.contributor-covenant.org/) spirit: harassment-free participation for everyone.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
