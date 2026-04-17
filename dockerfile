FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York
ENV REPO_DIR=/work/hours.love

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    ca-certificates \
    bash \
    tzdata \
    curl \
    jq \
  && ln -fs /usr/share/zoneinfo/$TZ /etc/localtime \
  && dpkg-reconfigure -f noninteractive tzdata \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY entrypoint.sh /work/entrypoint.sh
RUN chmod +x /work/entrypoint.sh

ENTRYPOINT ["/work/entrypoint.sh"]
