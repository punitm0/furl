#!/usr/bin/env bash
# Creates or updates the GitHub labels in .github/labels.yml. Needs the gh CLI, logged in with access to the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
grep -E '^- \{' .github/labels.yml | while IFS= read -r line; do
  name=$(sed -E 's/.*name: *([^,]+),.*/\1/' <<<"$line" | sed -E 's/ *$//')
  color=$(sed -E 's/.*color: *([0-9a-fA-F]{6}).*/\1/' <<<"$line")
  desc=$(sed -E 's/.*description: *"([^"]*)".*/\1/' <<<"$line")
  gh label create "$name" --color "$color" --description "$desc" --force
done
