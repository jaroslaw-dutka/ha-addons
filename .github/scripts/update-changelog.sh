#!/bin/bash
set -e

ADDON_DIR="$1"
REPO_PATH="$2"
NEW_RELEASES="$3"

# Create temporary file with new changelog entries
TEMP_CHANGELOG=$(mktemp)

# Add each new release to changelog
echo "$NEW_RELEASES" | jq -r '.[] | "\(.tag_name)|\(.published_at)|\(.body)"' | while IFS='|' read -r tag_name published_at body; do
  VERSION=$(echo "$tag_name" | sed 's/^v//')
  RELEASE_DATE=$(echo "$published_at" | cut -d'T' -f1)
  
  {
    echo "## $VERSION ($RELEASE_DATE)"
    echo ""
    echo "### Updates from upstream ($REPO_PATH)"
    echo ""
    # Clean up release notes - remove excessive newlines and limit length
    echo "$body" | sed 's/\r$//' | head -30 | sed '/^$/N;/^\n$/d'
    echo ""
  } >> "$TEMP_CHANGELOG"
done

# Combine new entries with existing changelog
{
  cat "$TEMP_CHANGELOG"
  if [[ -f "${ADDON_DIR}CHANGELOG.md" ]]; then
    cat "${ADDON_DIR}CHANGELOG.md"
  fi
} > "${ADDON_DIR}CHANGELOG.md.tmp"

mv "${ADDON_DIR}CHANGELOG.md.tmp" "${ADDON_DIR}CHANGELOG.md"
rm -f "$TEMP_CHANGELOG"
