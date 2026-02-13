FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    cron \
    curl \
    gnupg \
    awscli \
    tzdata \
  && rm -rf /var/lib/apt/lists/*

# Install MongoDB Database Tools (mongodump/mongorestore)
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg; \
  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg arch=${arch}] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" \
    > /etc/apt/sources.list.d/mongodb-org-7.0.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends mongodb-database-tools; \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app/ /app/
RUN chmod +x /app/*.sh

ENTRYPOINT ["/app/entrypoint.sh"]
