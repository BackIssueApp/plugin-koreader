# KOReader

Read your BackIssue **Books library on an e-reader**. The plugin has two
halves: a BackIssue plugin that adds a small API and a card on your Profile
page, and a KOReader plugin for the device, downloaded from that card with
your server's address already inside.

On the device, **Tools → BackIssue** browses the Books library (all books,
recently added, search), downloads a book to a folder of your choice and opens
it. While you read, the position is pushed to BackIssue; when a book opens,
the newest position from anywhere comes back:

- between KOReader devices the position is exact (the same paragraph in an
  EPUB, the same page in a PDF);
- with the web reader it is shared by percentage, within a page or so.

A book that was not downloaded through the plugin (fetched over OPDS, copied
by USB) is recognised by a fingerprint of its first and last 64 KiB, so it
syncs too as long as the same file is in the library.

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

## Use

- **Browse library**, **Recently added** and **Search library** list the
  books; tap one to download it (and open it straight away if you like),
  hold one for its details. Books already on the device say so.
- **Pull progress from server** and **Push progress to server** sync the open
  book by hand.
- **Automatic sync** (on by default) pulls the newest position when a book
  opens, and pushes this device's position as you read, when the book closes
  and when the device goes to sleep. A position further along elsewhere is
  followed without asking; one behind asks first.
- **Download folder**, **This device** (the name other devices see) and the
  server address are set in the same menu.

Access rides the `koreader.use` permission (viewer tier). Restricted books
follow the same rules as everywhere else: a role without access, or an
account with mature content switched off, does not see them.

## Tests

```
npm test
```

## License

GPL-3.0-or-later.
