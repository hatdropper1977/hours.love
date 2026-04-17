FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WORKDIR=/work
ENV REPO_DIR=/work/hours.love

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    ca-certificates \
    bash \
    tzdata \
    curl \
    jq \
  && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI
RUN npm install -g @google/gemini-cli

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]

