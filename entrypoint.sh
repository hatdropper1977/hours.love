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

Narrative requirements:
- The first paragraph must introduce the story and preview what follows
- It must clearly state what happened and why it matters
- If a person is central, identify them immediately with name, role, and location
- Do not open with a scene or anecdote
- Do not open with generic background

Structure:
1. Opening: what happened and why it matters
2. Details: names, locations, specifics
3. Context: why it matters locally
4. Optional: related developments
5. No formal conclusion

Writing rules:
- 300 to 600 words
- Write like a local industry publication, not a personal blog
- No first-person narration
- No fictional scenes or invented experiences
- No sensory storytelling unless tied to a real reported fact
- Short paragraphs, factual tone
- No pontificating
- No generalizations
- No moralizing
- No reflective commentary
- No filler phrases
- No inspirational tone
- No em dashes
- No intensifiers like "very", "really", "deeply", "truly", "far more"
- Do not explain what you're about to say
- If a sentence sounds like a diary, remove it
- If a sentence could appear in a newspaper, keep it
- Keep sentences under 20 words when possible

Content rules:
- Use recent, real information when available via search grounding
- Summarize clearly and directly
- Combine multiple sources when relevant
- Do not fabricate facts
- Do not fabricate firsthand experience
- Focus on:
  - what happened
  - who is involved
  - where it happened
  - why it matters locally
  - practical implications

Topic balance rule:
- Choose ONE lane per post
- Rotate across lanes over time
- Do not choose the people lane two days in a row
- Prefer restaurant, winery, vineyard, business, or regional news over a profile
- Use the people lane only when a specific person is central to a current sourced development
- If recent posts focused on people, choose a non-people lane today
- Use recent posts to avoid repeating both topic and format

Topic lanes:
1. Restaurant / hospitality news
   - Marin, Novato, San Francisco, Bay Area openings, closures, chef changes, wine programs, tasting menus, awards

2. Winery / vineyard developments
   - Northern California winery news, vineyard acquisitions, harvest updates, tasting room changes, new releases, AVA developments

3. Wine business / production / distribution
   - bottling, logistics, distributors, DTC, tariffs, labor, pricing, climate, insurance, permits, land use

4. Regional / varietal explainer tied to current news
   - Napa, Sonoma, Marin, Mendocino, Anderson Valley, Russian River, Carneros, Petaluma Gap
   - Pinot Noir, Chardonnay, Syrah, Cabernet, Zinfandel, Rhône varieties

5. People in the Northern California wine scene
   - Use this lane only when the person is tied to a current event, appointment, opening, release, award, sale, controversy, or business change
   - Do not write generic profiles

People coverage rules:
- Do not default to a person profile
- People may appear in any article, but they should not become the article unless their action is the news
- If a person is central, focus on what changed because of them
- Include full name, role, business, and location only when supported by sources
- Do not invent people
- Do not write generic biographies

Sourcing rules:
- Prefer using 2 to 4 distinct sources when reporting news
- Prefer sources that mention specific businesses, places, events, or developments
- Prefer people sources only when the person is tied to a specific development
- Do not rely on a single source if multiple relevant sources exist
- Synthesize information across sources into a single narrative
- Do not summarize sources one-by-one
- Do not write "Article A says, Article B says"
- Combine facts into one coherent account

Citation rules:
- Every key factual claim must come from a grounding source
- Do not invent citations
- Do not fabricate details
- Use light attribution when necessary:
  - Marin Independent Journal reported that ...
  - The San Francisco Chronicle reported ...
  - WineBusiness noted ...
- Do not attribute every sentence
- Use markdown links inline when appropriate:
  - [publication name](url)
- Links must correspond to real grounding sources
- If multiple sources confirm a fact, present it once
- If sources differ, reflect that briefly without speculation

Footnote rules:
- Footnotes are allowed but optional
- If used, they must reference real sources
- Use markdown footnote syntax:
  - reference like [^1]
  - define at bottom:
    [^1]: Source Name - URL
- Do not invent footnotes

Failure rules:
- If fewer than 2 relevant sources are available, write a focused piece using one source plus context
- If no relevant sources are available, fall back to a non-news industry post
- Do NOT invent news or citations

Recent posts to avoid repeating in topic OR format:
${RECENT_POSTS_CONTEXT}

If a topic overlaps:
- choose a different angle instead of repeating

Title rules:
- Specific and concrete
- Not generic
- Should read like a headline
- Include a real place, business, event, or person when appropriate
- Do not force a person's name into the title unless the story is actually about that person
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

# --- style guard, warning only ---
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
