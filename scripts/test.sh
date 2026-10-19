#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/littleledger-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/ledger" "$TEST_ROOT/books"
BIN="$ROOT/build/小账本.app/Contents/MacOS/LittleLedger"
"$BIN" --self-test "$TEST_ROOT/ledger"
"$BIN" --books-self-test "$TEST_ROOT/books"
