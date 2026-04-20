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

# Context mode:
#   good   = titles only
#   better = titles + short snippets
export RECENT_POSTS_MODE="${RECENT_POSTS_MODE:-better}"

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

# --- recent post context ---
build_recent_titles_context() {
  local recent_files=()
  mapfile -t recent_files < <(find "$POSTS_DIR" -maxdepth 1 -type f -name "*.md" ! -name "${DATE_LOCAL}.md" | sort -r | head -n 5)

  if [[ ${#recent_files[@]} -eq 0 ]]; then
    echo "No recent posts yet."
    return
  fi

  for f in "${recent_files[@]}"; do
    local title
    title="$(grep -m1 '^title:' "$f" | sed 's/^title:[[:space:]]*//')"
    if [[ -z "$title" ]]; then
      title="$(basename "$f" .md)"
    fi
    echo "- ${title}"
  done
}

build_recent_snippets_context() {
  local recent_files=()
  mapfile -t recent_files < <(find "$POSTS_DIR" -maxdepth 1 -type f -name "*.md" ! -name "${DATE_LOCAL}.md" | sort -r | head -n 3)

  if [[ ${#recent_files[@]} -eq 0 ]]; then
    echo "No recent posts yet."
    return
  fi

  for f in "${recent_files[@]}"; do
    local title
    local snippet
    title="$(grep -m1 '^title:' "$f" | sed 's/^title:[[:space:]]*//')"
    if [[ -z "$title" ]]; then
      title="$(basename "$f" .md)"
    fi

    snippet="$(
      awk '
        BEGIN { in_frontmatter=0; started=0; lines=0 }
        /^---$/ {
          if (started == 0) { in_frontmatter=1; started=1; next }
          else if (in_frontmatter == 1) { in_frontmatter=0; next }
        }
        in_frontmatter == 0 && NF {
          print
          lines++
          if (lines >= 6) exit
        }
      ' "$f" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g'
    )"

    echo "- Title: ${title}"
    if [[ -n "$snippet" ]]; then
      echo "  Snippet: ${snippet}"
    fi
  done
}

if [[ "$RECENT_POSTS_MODE" == "good" ]]; then
  RECENT_POSTS_CONTEXT="$(build_recent_titles_context)"
else
  RECENT_POSTS_CONTEXT="$(build_recent_snippets_context)"
fi

# --- prompt ---
PROMPT=$(cat <<EOF
Write exactly one Eleventy post as valid markdown.

Output rules:
- Output ONLY the post file contents
- No explanations, no commentary, no meta text
- No code fences

Required format:
---
title: <specific title>
date: ${DATE_LOCAL}
tags:
  - posts
layout: post.liquid
---

Then the article body.

Editorial goal:
Write something a real person in Novato, Marin, or Northern California wine country would actually read.
This site is not a personal reflection blog. It is a small local publication.
Prioritize recent, concrete developments over abstract wine writing.

Allowed formats:
- News brief
- Short roundup of 2 to 4 items
- News-driven explainer
- Restaurant + wine angle

Writing rules:
- 1000 to 1500 words
- Lead with what happened
- No throat-clearing
- No em dashes
- No filler, no inspirational tone, no pontificating
- Short paragraphs
- Concrete before abstract
- If multiple sources overlap, stitch them together cleanly
- Name places, people, wineries, restaurants, dishes, bottles, neighborhoods, streets when relevant
- Explain why the item matters to Marin / Novato / Northern California readers
- If a restaurant is discussed, mention what kind of wine would make sense with the food
- If a winery or varietal is discussed, tie it to a real producer, region, or current development
- Do not invent citations
- Do not repeat recent posts; choose a different angle if overlap exists

Topic selection priorities:
1. Recent Marin / Novato / Bay Area restaurant or hospitality news
2. Recent Northern California wine industry news
3. A local winery, grower, or wine family in the news
4. A region or varietal only if tied to something current and specific

Recent posts to avoid repeating:
${RECENT_POSTS_CONTEXT}

EOF
)

# --- build request ---
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

# --- fail fast on API errors ---
if jq -e '.error' /tmp/gemini_response.json >/dev/null 2>&1; then
  echo "❌ Gemini API returned an error:"
  jq '.error' /tmp/gemini_response.json
  exit 1
fi

# --- extract text safely ---
POST_TEXT="$(jq -r '.candidates[0].content.parts[0].text // empty' /tmp/gemini_response.json)"

if [[ -z "$POST_TEXT" ]]; then
  echo "❌ Empty post content returned from Gemini."
  jq '.' /tmp/gemini_response.json
  exit 1
fi

printf '%s\n' "$POST_TEXT" > "$POST_FILE"

# --- contamination guard ---
if grep -qE 'I have written the blog post|/work/|^Here is|^Sure|^```' "$POST_FILE"; then
  echo "❌ Contaminated output. Aborting."
  cat "$POST_FILE"
  exit 1
fi

# --- basic format checks ---
if ! grep -q '^---$' "$POST_FILE"; then
  echo "❌ Missing front matter."
  cat "$POST_FILE"
  exit 1
fi

if ! grep -q '^title:' "$POST_FILE"; then
  echo "❌ Missing title in front matter."
  cat "$POST_FILE"
  exit 1
fi

# --- extract real sources, deduped ---
jq -r '
  [
    .candidates[0].groundingMetadata.groundingChunks[]?.web
    | select(.title and .uri)
    | "- [" + .title + "](" + .uri + ")"
  ] | unique | .[]
' /tmp/gemini_response.json > /tmp/sources.md || true

if [[ -s /tmp/sources.md ]]; then
  {
    printf '\n\n## Sources\n\n'
    cat /tmp/sources.md
    printf '\n'
  } >> "$POST_FILE"
fi

# --- style guard (lightweight) ---
if grep -qE '—| very | really | deeply | truly | far more | that is just ' "$POST_FILE"; then
  echo "⚠️ Style warning: banned phrasing detected."
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

