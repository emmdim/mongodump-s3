SHELL := /bin/bash

.PHONY: build run-once up down logs shell lint

build:
	docker build -t do-mongo-weekly-backup:local .

up:
	docker compose up -d --build

down:
	docker compose down

run-once:
	docker compose run --rm --entrypoint /app/backup.sh backup

logs:
	docker compose logs -f --tail=200

shell:
	docker compose run --rm --entrypoint /bin/bash backup

lint:
	shellcheck app/*.sh
