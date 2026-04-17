#!/usr/bin/env bash
set -euo pipefail

: "${GEMINI_API_KEY:?GEMINI_API_KEY is required}"
: "${GIT_REPO_SSH:?GIT_REPO_SSH is required}"
: "${GIT_USER_NAME:=Gemini CLI}"
: "${GIT_USER_EMAIL:=gemini-hours-love@users.noreply.github.com}"
: "${SSH_KEY_SRC:=/run/secrets/gemini_hours_love}"
: "${TZ:=America/New_York}"

export TZ
export HOME=/root
export REPO_DIR="${REPO_DIR:-/work/hours.love}"
export POSTS_DIR="${POSTS_DIR:-posts}"
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

ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
chmod 644 /root/.ssh/known_hosts

# --- clone or update repo ---
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

# --- prompt ---
PROMPT=$(cat <<EOF
Write exactly one Eleventy blog post as valid markdown.

Output rules:
- Output ONLY the post file contents
- No explanations or commentary
- No code fences

Required format:
---
title: <short title>
date: ${DATE_LOCAL}
tags:
  - posts
layout: post.liquid
---

Then the article body.

Writing rules:
- 400 to 700 words
- grounded, specific, human
- no AI meta commentary
- no emojis
- Be direct. Lead with the problem, not an observation about the problem.
- No transitions like "the payoff is", "the key point is", "the combination is". Just say the thing.
- No em dashes.
- No intensifiers: "very", "really", "deeply", "truly", "far more", "that is just".
- Concrete before abstract. Start with a specific scene, object, or example.
- Use active voice. Short sentences.
- Do not explain what you're about to say.
- No filler phrases: "it's worth noting", "importantly", "fundamentally".
- Avoid generic statements. Every paragraph must contain at least one concrete detail.
- No conclusions that summarize the article. End naturally.
- Do not repeat topics from recent posts.
- Avoid generic wine education content.
- After writing, remove 20% of the words without losing meaning.

Style:
- Write like a person who actually did the thing.
- Slight edge is fine. Avoid sounding inspirational.
- If a sentence could be removed without losing meaning, remove it.

Structure:
- Open with a concrete situation.
- Build from specific → meaning.
- No formal "introduction" or "conclusion".

Topic:
Choose one topic related to Northern California wine:
- winery profile
- wine + food pairing
- local wine culture observation
- seasonal or regional experience
EOF
)

# --- build request safely ---
jq -n --arg prompt "$PROMPT" '{
  contents: [
    {
      parts: [
        { text: $prompt }
      ]
    }
  ],
  tools: [
    {
      google_search: {}
    }
  ]
}' > /tmp/gemini_request.json

# --- call Gemini API ---
curl -sS \
  -H "Content-Type: application/json" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent" \
  -d @/tmp/gemini_request.json \
  > /tmp/gemini_response.json

# --- extract text ---
jq -r '.candidates[0].content.parts[0].text' /tmp/gemini_response.json > "$POST_FILE"

# --- contamination guard ---
if grep -qE 'I have written the blog post|/work/|^Here is|^Sure|^```' "$POST_FILE"; then
  echo "❌ Contaminated output. Aborting."
  cat "$POST_FILE"
  exit 1
fi

# --- extract sources (if any) ---
jq -r '
.candidates[0].groundingMetadata.groundingChunks[]? 
| "- [" + .web.title + "](" + .web.uri + ")"
' /tmp/gemini_response.json > /tmp/sources.md || true

if [[ -s /tmp/sources.md ]]; then
  echo -e "\n\n## Sources\n" >> "$POST_FILE"
  cat /tmp/sources.md >> "$POST_FILE"
fi

# --- build validation ---
npm ci
npm run build

# --- commit ---
git add "$POST_FILE"

if git diff --cached --quiet; then
  echo "No changes to commit."
  exit 0
fi

git commit -m "Auto post ${DATE_LOCAL}"
git push origin main

echo "Done."

