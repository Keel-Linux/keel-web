#!/bin/bash
# Line coverage of the project-authored shell of this repository, measured
# with kcov (decision 0004). Exits 1 when any measured file is below the
# threshold (default 95, the bar for project-authored code), 2 when a tool
# is missing.
#
#   COVERAGE_THRESHOLD=95 tests/coverage.sh
#
# COVERAGE_DIR keeps the kcov reports, one directory per measured file
# (default: a temporary directory). Needs the Debian packages bats and
# kcov. tests/boot-test.sh is the thin main that runs keel and LXC as
# root; it is exercised by the LXC run in test-appliance.yml, not measured
# here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
threshold="${COVERAGE_THRESHOLD:-95}"

# Each entry is a sourceable library and the bats file that exercises it.
targets=(
    "tests/lib/boot-test-lib.sh:tests/boot-test.bats"
    "packages/keel-web/anubis-front:tests/anubis-front.bats"
    "conf.d/main:tests/image-conf.bats"
)

for tool in kcov bats; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

reports="${COVERAGE_DIR:-$(mktemp -d)}"
failed=0

for target in "${targets[@]}"; do
    library="${target%%:*}"
    suite="${target#*:}"
    name="$(basename "$library")"
    report="$reports/$name"
    mkdir -p "$report"
    kcov --include-path="$root/$library" "$report" bats "$root/$suite"

    # with --include-path the report holds one file, so its first entry is ours
    json="$(find "$report" -name coverage.json -not -path '*/kcov-merged/*' | head -1)"
    percent="$(grep -o '"percent_covered": "[0-9.]*"' "$json" | head -1 | grep -o '[0-9.]*')"
    covered="$(grep -o '"covered_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"
    total="$(grep -o '"total_lines": "[0-9]*"' "$json" | head -1 | grep -o '[0-9]*')"

    echo "$name: $percent percent ($covered of $total lines) covered, threshold $threshold"
    if ! awk -v p="$percent" -v t="$threshold" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
        echo "$name: coverage below threshold (report: $report)" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
