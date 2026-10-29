# KOReader

Read your BackIssue **Books library on an e-reader**, and keep your reading
in step with it. The plugin has two halves: a BackIssue plugin that adds a
small API and a card on your Profile page, and a KOReader plugin for the
device, downloaded from that card with your server's address already inside.

On the device, **Tools → BackIssue → Dashboard** opens a cover-led view of
the library: a row of books under way, a row of the newest, and buttons for
all books, authors, series, what is on this device and what is finished.
Every list is a grid of covers with paging; a tap opens the book's page, with
cover, author, series, format, progress and description, and buttons to read
or download it and to mark it finished. A long press on a cover downloads at
once. While you read, the plugin keeps BackIssue up to date, and brings back
what changed elsewhere:

- **Positions.** Between KOReader devices the position is exact (the same
  paragraph in an EPUB, the same page in a PDF); with the web reader and the
  apps it is shared by percentage, within a page or so.
- **Finished status.** A book marked complete on the device is finished in
  BackIssue; a book finished on the web is marked complete on the device.
- **Highlights and notes.** Highlights made on the device appear in the
  web reader's bookmarks drawer and the apps' Highlights page, with their
  passage, colour and note. A note changed there follows back to the device;
  a highlight deleted there, or on another KOReader device, is removed. A
  highlight made on another KOReader device lands at its exact spot in an
  EPUB.
- **Reading time.** KOReader's page-reading statistics are uploaded, and
  the Profile page shows your reading time by book, grouped into sittings.

A book that was not downloaded through the plugin (fetched over OPDS, copied
by USB) is recognised by a fingerprint of its first and last 64 KiB, so it
syncs too as long as the same file is in the library. **Sync all books**
walks the reading history, so books read before the plugin was installed are
synced as well.

## Install

**Server:** one click from **Sidebar → Plugins** in BackIssue, or drop this
folder into the app's `plugins/` directory and restart. A Books library is
needed (the Ebooks plugin); without one the device has nothing to list.

**Device:** on your Profile page in BackIssue, under **KOReader**, press
**Download the KOReader plugin**. Copy the `backissue.koplugin` folder from
the zip into KOReader's `plugins` folder on the device (next to the other
`.koplugin` folders) and restart KOReader. Then, in KOReader, open the top
menu → **Tools** → **BackIssue** and paste a personal key from **API key** on
your Profile page. The server address is already filled in; **Test
connection** confirms the two can talk.

On Android, KOReader's `plugins` folder is `Internal storage/koreader/plugins`.

**Updating the device plugin:** **Check for plugin update** in the same menu
compares the device's copy with the server's and installs the newer one; a
restart of KOReader finishes it.

## Use

- **Dashboard** is the cover view described above. **Browse library**,
  **Continue reading**, **Recently added**, **Authors**, **Series** and
  **Search library** open the same cover grids directly; tap a cover for the
  book's page, hold it to download at once. Covers are fetched once and kept
  in KOReader's cache folder, scaled to the screen. Books already on the
  device say so.
- **Pull progress from server**, **Push progress to server** and **Sync
  highlights of this book** sync the open book by hand.
- **Sync all books** sweeps the reading history: every book the server knows
  gets its position (unless the server's is newer), status, highlights and
  reading time uploaded, and reports what it did.
- **Automatic sync** (on by default) pulls the newest position when a book
  opens, and pushes this device's position as you read, when the book closes
  and when the device goes to sleep. A position further along elsewhere is
  followed without asking; one behind asks first.
- **Sync highlights and notes** and **Sync reading statistics** (both on by
  default) run alongside the position sync and can be switched off.
- **Download folder**, **This device** (the name other devices and the
  Profile page see) and the server address are set in the same menu.

The Profile page lists every device that has synced, with its plugin version,
when it was last seen and what it read last, plus reading time on KOReader
for the last week and all time. **Forget** drops a device from the list.

Access rides the `koreader.use` permission (viewer tier). Restricted books
follow the same rules as everywhere else: a role without access, or an
account with mature content switched off, does not see them.

Limits worth knowing: a highlight made in the web reader or an app has no
KOReader position, so it stays there; highlights from another KOReader device
are placed in EPUBs, not PDFs. Reading time from a book arrives a few seconds
after the book closes, when KOReader has written its statistics.

## Tests

```
npm test
```

## License

GPL-3.0-or-later.
