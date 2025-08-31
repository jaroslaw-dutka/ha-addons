#!/bin/bash
set -e

UPDATED_ADDONS=""
CHANGES_MADE=false

echo "🔍 Scanning for addons with config.json files..."

# Find all directories with config.json files and store in array
ADDON_DIRS=()
for dir in */; do
  if [[ -f "${dir}config.json" ]]; then
    ADDON_DIRS+=("$dir")
  fi
done

# Print count of found addons
ADDON_COUNT=${#ADDON_DIRS[@]}
if [[ $ADDON_COUNT -eq 0 ]]; then
  echo "❌ No addons found with config.json files"
  exit 0
fi

echo "📦 Found $ADDON_COUNT addon(s) to check"

# Loop through each addon directory
for addon_dir in "${ADDON_DIRS[@]}"; do
  addon_name=$(basename "$addon_dir")

  echo ""
  echo "🔍 Processing addon: $addon_name"

  # Read current version and URL from config.json
  CURRENT_VERSION=$(jq -r '.version' "${addon_dir}config.json")
  REPO_URL=$(jq -r '.url' "${addon_dir}config.json")

  if [[ "$REPO_URL" == "null" || "$REPO_URL" == "" ]]; then
    echo "⚠️  No URL found in ${addon_dir}config.json, skipping..."
    continue
  fi

  # Extract owner/repo from GitHub URL
  REPO_PATH=$(echo "$REPO_URL" | sed 's|https://github.com/||' | sed 's|\.git$||')
  echo "🔗 Repository: $REPO_PATH"
  echo "📌 Current version: $CURRENT_VERSION"

  # Get latest release from GitHub API
  echo "🚀 Fetching latest release..."
  LATEST_RELEASE=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$REPO_PATH/releases/latest")
  if echo "$LATEST_RELEASE" | jq -e '.message' > /dev/null 2>&1; then
    echo "❌ Error fetching releases: $(echo "$LATEST_RELEASE" | jq -r '.message')"
    continue
  fi

  LATEST_VERSION=$(echo "$LATEST_RELEASE" | jq -r '.tag_name' | sed 's/^v//')
  if [[ "$LATEST_VERSION" == "null" || "$LATEST_VERSION" == "" ]]; then
    echo "❌ No releases found for $REPO_PATH"
    continue
  fi

  echo "🆕 Latest version: $LATEST_VERSION"

  # Compare versions using semver
  if ! npx semver "$LATEST_VERSION" -r ">$CURRENT_VERSION" 2>/dev/null; then
    echo "✅ $addon_name is up to date ($CURRENT_VERSION)"
    continue
  fi

  echo "✅ Update available for $addon_name: $CURRENT_VERSION -> $LATEST_VERSION"

  # Get all releases between current and latest version
  echo "📋 Fetching all releases to collect changelog..."
  ALL_RELEASES=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$REPO_PATH/releases?per_page=50")

  # Filter releases that are newer than current version using semver
  NEW_RELEASES=$(echo "$ALL_RELEASES" | jq --arg current "$CURRENT_VERSION" '
    [.[] |
      select(.tag_name | ltrimstr("v") as $version |
            try (
              # Use a simple version comparison for semantic versions
              ($version | split(".") | map(tonumber)) as $v_parts |
              ($current | split(".") | map(tonumber)) as $c_parts |
              (
                ($v_parts[0] // 0) > ($c_parts[0] // 0) or
                (($v_parts[0] // 0) == ($c_parts[0] // 0) and ($v_parts[1] // 0) > ($c_parts[1] // 0)) or
                (($v_parts[0] // 0) == ($c_parts[0] // 0) and ($v_parts[1] // 0) == ($c_parts[1] // 0) and ($v_parts[2] // 0) > ($c_parts[2] // 0))
              )
            ) catch false
            )
    ] | sort_by(.published_at)')

  # Check if we found any new releases
  RELEASE_COUNT=$(echo "$NEW_RELEASES" | jq length)
  if [[ "$RELEASE_COUNT" -le 0 ]]; then
      echo "🤔 No new releases found despite version difference"
      continue
  fi

  echo "📦 Found $RELEASE_COUNT new release(s) since $CURRENT_VERSION"

  # Update config.json
  echo "📝 Updating config.json..."
  jq ".version = \"$LATEST_VERSION\"" "${addon_dir}config.json" > "${addon_dir}config.json.tmp"
  mv "${addon_dir}config.json.tmp" "${addon_dir}config.json"

  # Update CHANGELOG.md if it exists
  if [[ -f "${addon_dir}CHANGELOG.md" ]]; then
    echo "📝 Updating CHANGELOG.md with all new releases..."
    .github/scripts/update-changelog.sh "$addon_dir" "$REPO_PATH" "$NEW_RELEASES"
  fi

  UPDATED_ADDONS="${UPDATED_ADDONS}- $addon_name: $CURRENT_VERSION → $LATEST_VERSION ($RELEASE_COUNT new releases)"$'\n'
  CHANGES_MADE=true
done

echo ""
echo "🎯 Summary: Processed $ADDON_COUNT addon(s)"
if [[ "$CHANGES_MADE" == "true" ]]; then
  echo "✅ Updates found and applied"
else
  echo "✅ All addons are up to date"
fi

echo "changes_made=$CHANGES_MADE" >> $GITHUB_OUTPUT
{
  echo "updated_addons<<EOF"
  echo "$UPDATED_ADDONS"
  echo "EOF"
} >> $GITHUB_OUTPUT
