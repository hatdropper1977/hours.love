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
- Do not include notes, explanations, confirmations, or commentary
- Do not say you wrote the file
- Do not wrap the answer in code fences

Required format:
1. YAML front matter:
---
title: <short title>
date: ${DATE_LOCAL}
tags:
  - posts
layout: post.liquid
---
2. Then the article body

Writing rules:
- 500 to 1000 words
- concrete, specific, human
- no self-help fluff
- no AI meta-commentary
- no emojis
- no hashtags
- no lists unless absolutely necessary
- mild personality is fine
- avoid sounding inspirational or preachy
- cite works whenever you summarize or research a topic 

Topic:
Choose a topic, one per day, that relates to the Northern California Wine industy.  Potential topics include:
- Google search recent news on the NorCal wine industry, summarize and cite the article.
- Google search recent restaurant openings or news in the Novato/ Marin County/ San Fran/ Bay Area.  Summarize and cite, and where it makes sense, talk about recommended dishes and recommended wine parings
- Find a local Northern California winery and discuss it, diving into its notes, parings, history, etc.
- Find a local NorCal wine making family, give their history 
- Write about one small, real, everyday observation that feels lived-in and specific, and how NorCal wines can enhance the experience
- Google search news for recent events in the area that can spur discussions of wine


EOF
)

# Non-interactive Gemini CLI

jq -n --arg text "$PROMPT" '{
  contents: [
    {
      parts: [
        { text: $text }
      ]
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


# Basic cleanup (optional)

# --- contamination guard ---
if grep -qE 'I have written the blog post|/work/|^Here is|^Sure' "$POST_FILE"; then
  echo "❌ Gemini output contaminated. Aborting commit."
  cat "$POST_FILE"
  exit 1
fi

# Validate build before push
npm ci
npm run build

git add "$POST_FILE" package-lock.json package.json . || true

if git diff --cached --quiet; then
  echo "No changes to commit."
  exit 0
fi

git commit -m "Auto post ${DATE_LOCAL}"
git push origin main

echo "Done."

