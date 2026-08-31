# Security Policy

## Supported versions

We support the latest GitHub Release on `main` (currently `v1.x`). Older tags may not receive backports.

## Reporting a vulnerability

Please **do not** open a public issue for security-sensitive reports.

Email the maintainers via GitHub: open a **private** security advisory on this repository  
([Security → Advisories → New draft advisory](https://github.com/Linus-Shyu/Luma-Bar/security/advisories/new)),  
or contact the owner listed on the [GitHub profile](https://github.com/Linus-Shyu).

Include:

- Impact and affected versions if known
- Reproduction steps or proof-of-concept (as little as needed)
- Whether the issue is already public

We will acknowledge receipt as soon as practical and work on a fix before any coordinated disclosure.

## Secrets & keys

- Never commit API keys, certificates, or notary credentials.
- User OpenAI keys belong in macOS Keychain or local environment variables — not the repo.
- Report accidental secret commits immediately so tokens can be rotated.
