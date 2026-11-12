# Contributing

Thanks for your interest in Tabula! Bug reports, ideas and pull requests are welcome.

## Getting started

```bash
brew install postgresql@17 mariadb-connector-c   # native client libraries used at build time
swift build && .build/debug/Tabula               # run from source
scripts/test-dbs.sh                              # Docker: seeded Postgres / MySQL / Redis test databases
.build/debug/Tabula --selftest                   # driver + tokenizer checks against those databases
```

Developer tools built into the binary:

- `--snapshot "<connection name or url>" <dir>` renders key screens offscreen to PNG. Add `--erd-only` to render just the ER diagram.
- `--scrollbench <url> <table>` measures grid scrolling performance.
- `--erd-dump <url> [schema]` prints the ER graph as JSON.
- `--ai-test <kind> <endpoint> <model> <auth> [key]` makes a single streaming request through a provider.

## Guidelines

- Keep the app native (SwiftUI + AppKit) and dependency-light. Database access goes through the C client libraries.
- Run `--selftest` (and a `--snapshot` for UI changes) before opening a PR.
- Never commit credentials. Passwords and API keys belong in the Keychain.

## License of contributions

By submitting a contribution you agree that it is licensed under the project's license (PolyForm Noncommercial 1.0.0, see `LICENSE`). You also agree that the copyright holder may license your contribution under other terms, including commercial terms.
