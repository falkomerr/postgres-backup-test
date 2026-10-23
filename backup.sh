#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

cd "$(dirname "$0")"
set -a
source .env
set +a
export AWS_PAGER=""
: "${POSTGRES_DB:?}" "${POSTGRES_USER:?}" "${S3_BUCKET:?}" "${S3_ENDPOINT:?}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"

if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
else
    compose=(docker-compose)
fi

s3() {
    aws --endpoint-url "$S3_ENDPOINT" "$@"
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prefix="backups/$POSTGRES_DB/"
name="$(date -u +%Y%m%dT%H%M%SZ)-$$$RANDOM.dump"

"${compose[@]}" exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$workdir/database.dump"
test -s "$workdir/database.dump"
s3 s3 cp "$workdir/database.dump" "s3://$S3_BUCKET/$prefix$name" --only-show-errors
printf 'Uploaded %s\n' "$prefix$name"

cutoff=$(date -u -d '30 days ago' +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -v-30d +%Y%m%dT%H%M%SZ)
keys=$(s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" --query 'Contents[].Key' --output text)
for key in $keys; do
    filename="${key#"$prefix"}"
    if [[ "$filename" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+\.dump$ && "$filename" < "$cutoff" ]]; then
        s3 s3api delete-object --bucket "$S3_BUCKET" --key "$key" >/dev/null
        printf 'Deleted expired backup %s\n' "$key"
    fi
done
