# Contributing to HoldSeek

Thanks for helping. HoldSeek is maintained by [@anuragggg](https://github.com/anuragggg), who reviews and merges every change.

## Before you write code

- **Open an issue first** for anything bigger than a small fix, so we can agree on the change before you spend time on it.
- **Keep HoldSeek small.** Pull requests that add dependencies, network access, or new permissions (macOS or Chrome extension) won't be merged without prior discussion. HoldSeek's privacy promise depends on this, and CI checks for it.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make one focused change. Match the style of the surrounding code.
3. Run `./build.sh`. It builds the app and runs the self-check, which must pass.
4. Test on a real Mac with the players your change affects.
5. Open the pull request and fill in the template.

Every pull request needs a passing CI run and the maintainer's approval, and it is squash-merged. For first-time contributors, CI waits until the maintainer approves the run.

## What gets extra scrutiny

- `extension/manifest.json` and anything else that changes what the Chrome extension can access
- The key listener and event handling in `HoldSeek.swift`
- `build.sh`, `Info.plist`, `HoldSeek.entitlements`, and `.github/`

## Security issues

Please don't open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
