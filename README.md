# MongoDB Weekly Backups to S3-Compatible Storage

A small, production-practical container that runs `mongodump` on a MongoDB cluster once per week (cron inside the container) and uploads a single-file gzip archive plus a `.sha256` sidecar to any S3-compatible storage (including DigitalOcean Spaces). It also keeps only the last N successful weekly backups per host/prefix.

## What It Does
- Runs `mongodump --archive --gzip` against a MongoDB URI.
- Uploads `mongo-<timestamp>.archive.gz` and `mongo-<timestamp>.archive.gz.sha256` to Spaces.
- Keeps only the last `RETENTION` backups by filename order (count-based retention).
- Logs to stdout via a tailed cron log.

## Requirements
- Docker + Docker Compose.
- MongoDB connection string (`MONGO_URI`).
- S3-compatible bucket and access keys (least-privilege recommended).

## Quickstart
1. Copy env example and fill values:

```bash
cp .env.example .env
```

2. Build and start:

```bash
docker compose up -d --build
```

3. Check logs:

```bash
docker compose logs -f --tail=200
```

## Configuration
Required env vars:
- `MONGO_URI`
- `SPACE_NAME`
- `SPACE_ENDPOINT`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `CRON_SCHEDULE`

Optional env vars:
- `TZ` (default `Etc/UTC`)
- `RETENTION` (default `6`)
- `HOST_TAG` (default hostname short)
- `EXTRA_MONGODUMP_ARGS` (default empty; example `--db mydb`)
- `AWS_S3_FORCE_PATH_STYLE` (default `false`)
- `MONGO_TLS_CA_FILE` (default empty)
- `RUN_ON_START` (default `false`)

## Schedule Examples
- Europe/Rome (DST-aware with `TZ=Europe/Rome`), weekly on Sunday at 03:15:

```
TZ=Europe/Rome
CRON_SCHEDULE=15 3 * * 0
```

- UTC, weekly on Sunday at 03:15:

```
TZ=Etc/UTC
CRON_SCHEDULE=15 3 * * 0
```

## Object Layout
Objects are written to:

```
s3://<SPACE_NAME>/<HOST_TAG>/<YYYY-MM>/mongo-<timestamp>.archive.gz
s3://<SPACE_NAME>/<HOST_TAG>/<YYYY-MM>/mongo-<timestamp>.archive.gz.sha256
```

`<YYYY-MM>` is based on the backup time in UTC. `<timestamp>` is UTC in `YYYYMMDDTHHMMSSZ` format, so lexicographic order matches time order.

## Restore Example
Download and stream-restore an archive:

```bash
aws --endpoint-url <SPACE_ENDPOINT> \
  s3 cp s3://<SPACE_NAME>/<HOST_TAG>/<YYYY-MM>/mongo-<timestamp>.archive.gz - \
| mongorestore --archive --gzip --uri "<MONGO_URI>"
```

Local backup then restore to remote (two-step):

1. Create a local backup file with `mongodump`:

```bash
mongodump --uri "<SOURCE_MONGO_URI>" --archive=backup.archive.gz --gzip
```

2. Restore that local backup into the remote cluster:

```bash
mongorestore --uri "<REMOTE_MONGO_URI>" --archive=backup.archive.gz --gzip
```

## MongoDB TLS Notes
- Many managed MongoDB services use TLS by default. Your `MONGO_URI` should include TLS parameters (for example `tls=true`).
- If your driver tools need a CA cert file, mount it into the container and set `MONGO_TLS_CA_FILE` to that path. Example:

```
MONGO_TLS_CA_FILE=/certs/ca.pem
```

Mount example (compose):

```
volumes:
  - ./certs/ca.pem:/certs/ca.pem:ro
```

## Retention and Naming Strategy
- Retention is **count-based**. The script keeps the newest `RETENTION` archives by filename order, and deletes older `.archive.gz` plus matching `.sha256` sidecars.
- The month segment is always the UTC year-month of the backup (e.g. `2026-02`).
- Retention is applied within the current month segment (`<HOST_TAG>/<YYYY-MM>`).
- Set `HOST_TAG` to identify the source host or cluster if you run multiple instances.
- The AWS CLI paginates `list-objects-v2` automatically, so retention remains correct even with many objects under the prefix.

## Security
### Least-Privilege Spaces Credentials
Create a scoped Spaces access key with permissions limited to the specific bucket and prefix. Example IAM-style policy (adjust bucket, host tag, and month pattern as needed):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-space-name"
      ],
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "your-host/????-??/*"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::your-space-name/your-host/????-??/*"
      ]
    }
  ]
}
```

### Secret Handling
- Do not hardcode credentials.
- Prefer `env_file` or Docker secrets. The included `docker-compose.yml` uses `.env` via `env_file`.

## Troubleshooting
- **Cron not running**: Ensure `CRON_SCHEDULE` is set and valid. Check logs with `docker compose logs -f`.
- **Authentication failed (Spaces)**: Verify `SPACE_ENDPOINT`, `SPACE_NAME`, and Spaces access keys.
- **Mongo TLS issues**: Add `tls=true` in `MONGO_URI` or provide a CA file via `MONGO_TLS_CA_FILE`.
- **Retention deletes too much**: Verify `RETENTION` is a positive integer and your naming format is consistent.

## Shellcheck
If you have `shellcheck` locally, run:

```bash
make lint
```

## Cost Note
Storage costs for Spaces are external. This container only runs weekly and does not maintain local backups.

## License
MIT
