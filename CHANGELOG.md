# Changelog

Notable, user-facing changes per release. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow the tags in this repository (`vX.Y.Z` → the release bundle BackIssue's plugin catalog installs).

Contributors: please **don't** edit this file in pull requests — entries are added
by the maintainers when changes merge, so concurrent PRs don't conflict here.

## [Unreleased]

### Added

- First release. A **KOReader** card on the Profile page hands out the device
  plugin with the server's address inside. On the device, **Tools →
  BackIssue** browses, searches and downloads the Books library, and keeps
  reading progress in sync: exact between KOReader devices (xpointer or
  page), by percentage with the web reader. Books not downloaded through the
  plugin are recognised by a fingerprint of their first and last 64 KiB,
  computed on the server after each scan.
