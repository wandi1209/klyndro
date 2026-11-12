#!/usr/bin/env bash
# One entry point for a full release check: both unit suites, both release builds, and the
# repository hygiene checks from the security review (docs/security/review-checklist.md).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/scripts/audit-repo.sh"
"$repo_root/scripts/release-android.sh"
"$repo_root/scripts/release-macos.sh"

echo "Release artefacts are in $repo_root/dist"
