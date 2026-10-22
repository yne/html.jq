#!/bin/bash
JQ="${JQ:-jq}"
echo $JQ
$JQ --version

FAILED=0
for test_file in tests/*.{xml,html}; do
	printf %-32s "$test_file"
	output=$($JQ -csRf "${test_file##*.}.jq" "$test_file")
	expect=$($JQ -c < "$test_file.json")
	if diff <(printf '%s\n' "$output") <(printf '%s\n' "$expect"); then
		printf "PASS\n"
	else
		printf "FAIL\n"
		cmp -l <(printf '%s' "$output") <(printf '%s' "$expect") | head -n 1
		FAILED=1
	fi
done
exit $FAILED
