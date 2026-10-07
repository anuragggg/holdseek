# Security

## Reporting a vulnerability

Please don't report security problems in public issues. Use GitHub's private reporting instead: [**Report a vulnerability**](https://github.com/anuragggg/holdseek/security/advisories/new). Only the maintainer can see the report. You'll get a reply within a week.

## Supported versions

Only the [latest release](https://github.com/anuragggg/holdseek/releases/latest) gets security fixes.

## What HoldSeek can access

HoldSeek makes no network connections. It asks for:

- **Accessibility**, to catch the Next and Previous media keys. Every other key passes through untouched.
- **Automation** of Music and Spotify, to read whether they're playing and move the playback position.
- The **Chrome extension** runs on every site to detect when a video or audio player starts or stops, and changes the playback position when HoldSeek asks. It doesn't read page content or talk to any server.

Releases are built from this repository with `build.sh`. Each release lists the SHA-256 checksum of its zip, so you can check that your download matches.
