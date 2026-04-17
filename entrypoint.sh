#!/usr/bin/env bash
set -euo pipefail

: "${GEMINI_API_KEY:?GEMINI_API_KEY is required}"
: "${GIT_REPO_SSH:?GIT_REPO_SSH is required, e.g. git@github-hours-love:hatdropper1977/hours.love.git}"
: "${GIT_USER_NAME:=Gemini CLI}"
: "${GIT_USER_EMAIL:=gemini-hours-love@users.noreply.github.com}"
: "${SSH_KEY_SRC:=/run/secrets/gemini_hours_love}"
: "${TZ:=America/New_York}"

export TZ
export HOME=/root
export REPO_DIR="${REPO_DIR:-/work/hours.love}"
export POSTS_DIR="${POSTS_DIR:-posts}"
export DATE_UTC="$(date -u +%F)"
export DATE_LOCAL="$(date +%F)"

mkdir -p /root/.ssh /work
chmod 700 /root/.ssh

if [[ ! -f "$SSH_KEY_SRC" ]]; then
  echo "Missing SSH key at $SSH_KEY_SRC"
  exit 1
fi

cp "$SSH_KEY_SRC" /root/.ssh/gemini_hours_love
chmod 600 /root/.ssh/gemini_hours_love

cat >/root/.ssh/config <<'EOF'
Host github-hours-love
  HostName github.com
  User git
  IdentityFile /root/.ssh/gemini_hours_love
  IdentitiesOnly yes
EOF
chmod 600 /root/.ssh/config

# Pre-trust GitHub host key so there is no interactive prompt
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
chmod 644 /root/.ssh/known_hosts

if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone "$GIT_REPO_SSH" "$REPO_DIR"
fi

cd "$REPO_DIR"

git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

git fetch origin
git checkout main
git reset --hard origin/main

mkdir -p "$POSTS_DIR"

POST_FILE="$POSTS_DIR/${DATE_LOCAL}.md"

if [[ -f "$POST_FILE" ]]; then
  echo "Post already exists for ${DATE_LOCAL}; exiting."
  exit 0
fi

PROMPT=$(cat <<EOF
Write exactly one Eleventy blog post as valid markdown.

Output rules:
- Output ONLY the post file contents
- No explanations, no commentary, no meta text
- No code fences

Required format:
---
title: <short title>
date: ${DATE_LOCAL}
tags:
  - posts
layout: post.liquid
sources:
  - title: <source 1 title>
    url: <source 1 url>
  - title: <source 2 title>
    url: <source 2 url>
---

Then the article body.

Writing rules:
- 500 to 900 words
- grounded, specific, human
- no AI meta commentary
- no emojis
- no hashtags
- avoid preachy tone
- use recent web information when relevant
- only cite sources returned by grounding
- if grounding returns no usable sources, write an evergreen NorCal wine post and omit invented citations

Topic:
Choose one topic related to the Northern California wine industry.
Possible angles:
- recent NorCal wine industry news
- a recent Bay Area restaurant opening with wine pairings
- a local winery profile
- a local wine family history
- a local event or seasonal moment tied to wine
EOF
)

jq -n --arg text "$PROMPT" '{
  contents: [
    {
      parts: [
        { text: $text }
      ]
    }
  ],
  tools: [
    {
      google_search: {}
    }
  ]
}' > /tmp/gemini_request.json

curl -sS \
  -H "Content-Type: application/json" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent" \
  -d @/tmp/gemini_request.json \
  > /tmp/gemini_response.json

jq -r '.candidates[0].content.parts[0].text' /tmp/gemini_response.json > "$POST_FILE"

# Save grounding metadata for debugging
jq '.candidates[0].groundingMetadata' /tmp/gemini_response.json > /tmp/gemini_grounding.json || true

# Contamination guard
if grep -qE 'I have written the blog post|/work/|^Here is|^Sure|^```' "$POST_FILE"; then
  echo "❌ Gemini output contaminated. Aborting commit."
  cat "$POST_FILE"
  exit 1
fi

# Require grounding when the post claims to be based on recent web info
if grep -qiE 'recent|today|this week|opened|announced|reported' "$POST_FILE"; then
  if ! jq -e '.candidates[0].groundingMetadata.groundingChunks | length > 0' /tmp/gemini_response.json >/dev/null 2>&1; then
    echo "❌ Post looks newsy but no grounding metadata was returned. Aborting."
    exit 1
  fi
fi

# Validate build before push
npm ci
npm run build

git add "$POST_FILE"

if git diff --cached --quiet; then
  echo "No changes to commit."
  exit 0
fi

git commit -m "Auto post ${DATE_LOCAL}"
git push origin main

echo "Done."

