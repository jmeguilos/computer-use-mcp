#!/usr/bin/env bash

set -euo pipefail

minimum_test_count=44
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_directory/.." && pwd)"
package_path="$repository_root/apps/macos-host"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

developer_directory="$(xcode-select -p 2>/dev/null || true)"
if ! xcrun --find xctest >/dev/null 2>&1; then
  fail "native Swift tests require full Xcode 16 or later; the active developer directory ('$developer_directory') has no xctest. Command Line Tools can compile the package but may silently run zero Swift Testing tests. Select a full Xcode developer directory and retry."
fi

command -v swift >/dev/null 2>&1 || fail "swift is not available"
xml_lint="$(command -v xmllint || true)"
test -n "$xml_lint" || fail "xmllint is required to validate Swift test execution results"
test -d "$package_path" || fail "Swift package was not found at '$package_path'"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-mcp-swift-tests.XXXXXX")"
test_list="$temporary_root/discovered-tests.txt"
test_results="$temporary_root/test-results.xml"

cleanup() {
  rm -f -- "$test_list" "$test_results"
  rmdir -- "$temporary_root" 2>/dev/null || true
}
trap cleanup EXIT

printf 'Discovering native Swift tests (minimum: %s)...\n' "$minimum_test_count"
swift test \
  --package-path "$package_path" \
  --enable-swift-testing \
  --disable-xctest \
  list | tee "$test_list"

discovered_test_count="$(awk 'NF { count++ } END { print count + 0 }' "$test_list")"
if (( discovered_test_count < minimum_test_count )); then
  fail "SwiftPM discovered $discovered_test_count tests; expected at least $minimum_test_count"
fi
printf 'SwiftPM discovered %s native tests.\n' "$discovered_test_count"

printf 'Running native Swift tests with machine-readable results...\n'
swift test \
  --package-path "$package_path" \
  --enable-swift-testing \
  --disable-xctest \
  --xunit-output "$test_results"

test -s "$test_results" || fail "SwiftPM produced no test execution report"
executed_test_count="$($xml_lint --xpath 'count(/testsuites/testsuite/testcase[not(skipped)])' "$test_results")"
case "$executed_test_count" in
  ''|*[!0-9]*) fail "SwiftPM produced an invalid executed-test count ('$executed_test_count')" ;;
esac

if (( executed_test_count < minimum_test_count )); then
  fail "SwiftPM executed $executed_test_count tests; expected at least $minimum_test_count"
fi
if (( executed_test_count != discovered_test_count )); then
  fail "SwiftPM discovered $discovered_test_count tests but executed $executed_test_count"
fi

printf 'Swift test sentinel passed: %s discovered and %s executed.\n' \
  "$discovered_test_count" "$executed_test_count"
