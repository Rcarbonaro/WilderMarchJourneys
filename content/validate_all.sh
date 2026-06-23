#!/bin/bash
# Quick content validator: checks every .json file under content/ for valid
# JSON syntax. Run this after editing content to catch typos before booting
# Godot. (This checks SYNTAX only -- ContentLoader.gd's own required-field
# checks at runtime catch missing/incorrect fields.)
fail=0
while IFS= read -r -d '' f; do
  if ! python3 -m json.tool < "$f" > /dev/null 2>&1; then
    echo "INVALID JSON: $f"
    fail=1
  fi
done < <(find content -name "*.json" -print0)
if [ $fail -eq 0 ]; then
  echo "All content JSON files are syntactically valid."
else
  echo "One or more content files have JSON syntax errors -- see above."
fi
exit $fail
