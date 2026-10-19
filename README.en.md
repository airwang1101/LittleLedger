# LittleLedger

A local macOS bookkeeping app built with SwiftUI, AppKit, and Swift Charts. Version 1.3.0 (build 4). The current UI is in Chinese.

[中文](README.md)

## Features

- Independent ledgers with separate entries, preferences, and drafts.
- Keyboard entry with arithmetic expressions such as `+100-20+50`.
- CNY, USD, HKD, EUR, and TWD, with automatic or manual exchange rates.
- Q/W/E/R ledger bindings and C/U/H/O/T currency shortcuts in the amount field.
- Ledger balances, daily balance changes, seven-day trends, statistics, categories, search, undo, import, and export.
- An onboarding guide with editable ledger bindings.

Balance growth reflects bookkeeping activity, including deposits and spending. It does not measure investment returns.

## Build and test

Requires macOS 13+ and Xcode Command Line Tools with the macOS SDK. The script builds for the host architecture, either Apple silicon or Intel.

```sh
git clone https://github.com/airwang1101/LittleLedger.git
cd LittleLedger
./scripts/build.sh
open build/小账本.app
./scripts/test.sh
```

Install the development tools with `xcode-select --install` if needed. Builds are ad hoc signed locally. A notarized downloadable release is not provided yet.

The local Apple silicon build and both existing regression suites have been verified. macOS 13 and Intel hardware compatibility still need testing. Current compilers emit some SwiftUI and Charts deprecation warnings. Tests use temporary directories and do not open personal ledgers.

## Privacy

Data stays in JSON files under `~/Library/Application Support/LittleLedger/`. Files are not encrypted by the app. Automatic rates contact `https://open.er-api.com/v6/latest/USD`; ledger entries are not included in requests. Manual rates are available. See [PRIVACY.md](PRIVACY.md).

Local backups, test data, caches, and old app bundles are excluded from Git. This repository publishes only the selected source files, resources, scripts, and documentation.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Released under the [MIT License](LICENSE).
