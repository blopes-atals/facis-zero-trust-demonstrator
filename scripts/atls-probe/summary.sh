#!/usr/bin/env bash
# Prints, as Markdown, the verdict of each proof found under an evidence folder: one row per
# criterion, the checks that failed, and the session-loss findings. The CI workflow appends it
# to the job summary; it also reads the committed evidence.
#
# Usage: summary.sh [DIR]     (default: docs/evidences/cmc-atls-channel-binding)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$(git -C "$here" rev-parse --show-toplevel)/docs/evidences/cmc-atls-channel-binding}

echo "## Attested channel proofs"
echo
echo "| Criterion | Verdict | Checks | Run |"
echo "|---|---|---|---|"
for entry in \
	"criterion-1-mutual-handshake|1 — mutual handshake, identical binding" \
	"criterion-2-tampered-binding|2 — a report bound to another session is refused" \
	"criterion-3-session-loss|3 — session loss recorded per scenario"; do
	folder=${entry%%|*}
	label=${entry#*|}
	verdict=$dir/$folder/verdict.txt
	env=$dir/$folder/environment.json
	if [ ! -f "$verdict" ]; then
		echo "| $label | not run | — | — |"
		continue
	fi
	result=$(sed -n 's/^verdict: //p' "$verdict" | tail -n 1)
	passed=$(grep -c '^PASS ' "$verdict" || true)
	failed=$(grep -c '^FAIL ' "$verdict" || true)
	run="—"
	if [ -f "$env" ]; then
		run=$(jq -r '"\(.host_kind), commit `\(.commit[0:12])`\(if .dirty then " + changes" else "" end), \(.go_version), CMC \(.cmc_version), \(.date)"' "$env")
	fi
	echo "| $label | **${result:-unknown}** | $passed passed, $failed failed | $run |"
done

for folder in criterion-1-mutual-handshake criterion-2-tampered-binding criterion-3-session-loss; do
	verdict=$dir/$folder/verdict.txt
	if [ -f "$verdict" ] && grep -q '^FAIL ' "$verdict"; then
		echo
		echo "### Failed checks — $folder"
		echo
		grep '^FAIL ' "$verdict" | sed 's/^FAIL  */- /'
	fi
done

findings=$dir/criterion-3-session-loss/reconnect-findings.md
if [ -f "$findings" ]; then
	echo
	echo "### Session loss — findings of this run"
	echo
	grep '^|' "$findings"
fi
