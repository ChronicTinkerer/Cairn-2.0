# Changelog

All notable changes to Cairn-2.0 are recorded here. Versions are sequential integer build numbers (one increment per `release.ps1` run).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Repo scaffolded.** Five flavor TOCs (Mainline / Mists / TBC / Vanilla / XPTR), vendored LibStub, MIT LICENSE, BigWigs packager workflow, sequential build-numbering `release.ps1`, `.pkgmeta` skeleton. No libraries yet — each lands as it's built and lock-passes the simplicity-first design rule.
- **Design principles.** Locked in `.dev/docs/OBJECTIVES.md` (local-only). Headline: keep things simple wherever possible; when complexity is unavoidable, wrap it behind an interface that lets consumers stay simple.
