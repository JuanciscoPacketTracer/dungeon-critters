#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: DATABASE_URL=postgresql://... $0 /secure/path/backup.dump" >&2
  exit 64
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL must be set." >&2
  exit 64
fi

output=$1
parent_dir=$(dirname -- "$output")

if [[ ! -d "$parent_dir" ]]; then
  echo "Backup directory does not exist: $parent_dir" >&2
  exit 66
fi

if [[ -e "$output" ]]; then
  echo "Refusing to overwrite an existing backup: $output" >&2
  exit 73
fi

for command in pg_dump pg_restore; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is not installed: $command" >&2
    exit 69
  fi
done

umask 077
trap 'rm -f -- "$output"' ERR

pg_dump \
  --dbname="$DATABASE_URL" \
  --format=custom \
  --no-owner \
  --no-acl \
  --file="$output"

pg_restore --list "$output" >/dev/null
trap - ERR

echo "Verified database backup: $output"
