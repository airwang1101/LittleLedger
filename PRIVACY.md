# Privacy

LittleLedger has no account sign-in, built-in cloud synchronization, advertising, or analytics SDK. The source stores ledger entries, preferences, and unfinished drafts in JSON files under `~/Library/Application Support/LittleLedger/`. These files are not encrypted by the app. Exported files and automatic local backups may also contain financial information.

When automatic exchange rates are enabled and refreshed, the app requests `https://open.er-api.com/v6/latest/USD` using URLSession. The URL is fixed and contains no ledger records, notes, or amounts. The provider receives normal connection metadata such as the client's IP address. Select manual exchange rates in settings to avoid this rate request.

The original ledger uses `ledger.json`, `settings.json`, and `draft.json`. Additional ledgers use `books/<UUID>/`. `books.json` records the ledger list; `quick-books.json` stores shortcut bindings and onboarding completion.

Personal ledger files, historical backups, generated binaries, build caches, and local work files are excluded from the repository. Do not attach real financial records to public issues. Create synthetic examples instead.

This document describes the current source behavior. OS backups and any external synchronization configured by the user operate separately.
