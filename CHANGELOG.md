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
- A fault inside the device plugin is shown as a message and written to
  `backissue_crash.log` in KOReader's data folder, instead of taking KOReader
  down with it.
- **Highlights and notes** sync both ways: marks made on the device appear in
  the web reader's bookmarks drawer and the apps' Highlights page with their
  passage, colour and note; a note changed there follows back, a mark deleted
  there is removed, and marks from another KOReader device land at their
  exact spot in EPUBs.
- **Reading status**: complete on the device is finished in BackIssue and the
  other way round.
- **Reading time**: KOReader's page statistics are uploaded, and the Profile
  card shows reading time by book, grouped into sittings.
- **Sync all books** sweeps the reading history so books read before the
  plugin was installed are synced, with the server keeping any newer position.
- A **Dashboard** on the device: rows of covers for books under way and the
  newest, and buttons for all books, authors, series, on this device and
  finished. Every list is a cover grid with paging; a tap opens a book page
  with cover, metadata, progress and description, and Read / Download / Mark
  finished buttons. Covers are scaled once and cached on the device.
- Browse by **Continue reading**, **Authors** and **Series**; a book's page
  shows its description.
- **Check for plugin update** installs the server's newer copy of the device
  plugin in place.
- The Profile card lists the devices that have synced (plugin version, last
  seen, last book) with a Forget button, and the device is told when the
  server's copy of a book changed under its position.
