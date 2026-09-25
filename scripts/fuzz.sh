#!/usr/bin/env bash
# Build the libFuzzer harnesses in Fuzz/ and run each against its corpus.
#
#     scripts/fuzz.sh            # 60 s per harness (the CI budget)
#     scripts/fuzz.sh 600        # before a phase closes
#
# `-sanitize=fuzzer,address` goes to every module, so the parsers under test are instrumented and not just
# the harness. A crash writes its reproducer to Fuzz/Crashes/<harness>/ and fails the run; commit the input
# to the harness's corpus once the bug is fixed, so the regression stays covered.

set -euo pipefail

seconds="${1:-60}"
root=$(git rev-parse --show-toplevel)
cd "$root"

swift build --package-path Fuzz --scratch-path .build-fuzz \
	-Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
products=$(swift build --package-path Fuzz --scratch-path .build-fuzz --show-bin-path \
	-Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library)

# Seed a scratch corpus from knit-next's golden vectors; scripts/fuzz-seeds.py says what each harness gets.
seeds=$(mktemp -d)
trap 'rm -rf "$seeds"' EXIT
python3 scripts/fuzz-seeds.py "$seeds"

status=0
for source in Fuzz/Sources/*/; do
	harness=$(basename "$source")
	corpus="Fuzz/Corpus/$harness"
	crashes="Fuzz/Crashes/$harness"
	mkdir -p "$corpus" "$crashes"
	printf '\n== %s (%ss)\n' "$harness" "$seconds"
	# New interesting inputs land in a scratch corpus; the committed one only grows by hand.
	scratch=$(mktemp -d)
	if ! "$products/$harness" -max_total_time="$seconds" -print_final_stats=1 \
		-artifact_prefix="$crashes/" "$scratch" "$corpus" "$seeds/$harness"; then
		status=1
	fi
	rm -rf "$scratch"
done
exit "$status"
