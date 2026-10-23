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
restore_db="restore_check_$$_$RANDOM"
db_created=false

cleanup() {
    status=$?
    trap - EXIT
    if [[ "$db_created" == true ]]; then
        if ! "${compose[@]}" exec -T postgres dropdb -U "$POSTGRES_USER" --if-exists "$restore_db"; then
            status=1
        fi
    fi
    rm -rf "$workdir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prefix="backups/$POSTGRES_DB/"
keys=$(s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" --query 'Contents[].Key' --output text)
latest=""
for key in $keys; do
    filename="${key#"$prefix"}"
    if [[ "$filename" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+\.dump$ && "$key" > "$latest" ]]; then
        latest="$key"
    fi
done
if [[ -z "$latest" ]]; then
    printf 'No backups found in s3://%s/%s\n' "$S3_BUCKET" "$prefix" >&2
    exit 1
fi

printf 'Restoring %s into %s\n' "$latest" "$restore_db"
s3 s3 cp "s3://$S3_BUCKET/$latest" "$workdir/database.dump" --only-show-errors
"${compose[@]}" exec -T postgres createdb -U "$POSTGRES_USER" -T template0 "$restore_db"
db_created=true
"${compose[@]}" exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$restore_db" --exit-on-error --single-transaction --no-owner --no-acl < "$workdir/database.dump"

check_sql="${RESTORE_CHECK_SQL:-SELECT EXISTS (SELECT 1 FROM public.backup_probe WHERE id = 1 AND value = 'backup-ok')}"
result=$("${compose[@]}" exec -T postgres psql -X -U "$POSTGRES_USER" -d "$restore_db" -v ON_ERROR_STOP=1 -At -c "$check_sql")
if [[ "$result" != "t" ]]; then
    printf 'Restore data check failed (expected t, got %s)\n' "$result" >&2
    exit 1
fi
printf 'Restore data check passed\n'
