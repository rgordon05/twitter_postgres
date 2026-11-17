#!/bin/sh
set -eu

files='
test-data.zip
'

export PGPASSWORD=pass
normalized='postgresql://postgres:pass@localhost:21136/postgres'
denormalized='postgresql://postgres:pass@localhost:21135/postgres'

echo 'load normalized'
for file in $files; do
    python3 load_tweets.py --db "postgresql+psycopg2://postgres:pass@localhost:21136/postgres" --inputs "$file"
done

psql "$normalized" -v ON_ERROR_STOP=1 \
    -c 'REFRESH MATERIALIZED VIEW tweet_tags_total;' \
    -c 'REFRESH MATERIALIZED VIEW tweet_tags_cooccurrence;'

echo 'prepare denormalized'
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT

for file in $files; do
    python3 - "$file" >> "$temporary" <<'PY'
import csv
import io
import json
import sys
import zipfile

def clean(value):
    if isinstance(value, str):
        return value.replace('\x00', '')
    if isinstance(value, list):
        return [clean(item) for item in value]
    if isinstance(value, dict):
        return {clean(key): clean(item) for key, item in value.items()}
    return value

writer = csv.writer(sys.stdout, lineterminator='\n')
with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in sorted(archive.namelist(), reverse=True):
        if name.endswith('/'):
            continue
        with io.TextIOWrapper(archive.open(name), encoding='utf-8') as source:
            for line in source:
                tweet = clean(json.loads(line))
                writer.writerow([json.dumps(tweet)])
PY
done

echo 'load denormalized'
psql "$denormalized" -v ON_ERROR_STOP=1 --single-transaction \
    -c 'TRUNCATE tweets_jsonb;' \
    -c "\copy tweets_jsonb(data) FROM '$temporary' WITH (FORMAT csv)"
