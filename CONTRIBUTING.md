# Contributing

Open an issue describing the problem, the macOS version, and clear reproduction steps. Use synthetic amounts and notes. Do not upload personal ledger files.

Build and run the existing tests with `./scripts/test.sh` before proposing changes. The test runner uses temporary directories.

Preserve existing options, keyboard shortcuts, ledger formats, calculation behavior, and UI unless the change explicitly calls for modifying them. Describe any data migration and include a regression test for behavior changes. Keep unrelated formatting changes separate.

The current source is under `outputs/小账本源码/`. `main.swift` contains the application and core ledger code, `账本.swift` contains multi-ledger management and onboarding, and `统计.swift` contains reporting and charts.

Contributions are accepted under the repository's MIT License. Include third-party attribution when adding external material.
