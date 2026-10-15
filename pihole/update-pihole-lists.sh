#!/bin/bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$root_dir/pihole.tsv"
output_dir="$root_dir"
mkdir -p "$output_dir/.etags"
temp_dir="$(mktemp -d "$output_dir/.download.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
failures=0

while IFS=$'\t' read -r filename url || [[ -n "$filename" ]]; do
    url="${url%$'\r'}"
    [[ -z "$filename" || "$filename" == filename ]] && continue
    if [[ "$filename" == */* || "$filename" == .* || -z "$url" ]]; then
        printf 'Invalid manifest row: %s\n' "$filename" >&2
        failures=$((failures + 1))
        continue
    fi

    destination="$output_dir/$filename"
    etag="$output_dir/.etags/$filename"
    options=(--fail)
    if [[ -f "$destination" && -s "$etag" ]]; then
        options+=(--etag-compare "$etag")
    fi

    if ! http_code="$(curl --location --silent --show-error \
        --retry 2 --connect-timeout 20 --max-time 180 \
        "${options[@]}" --etag-save "$temp_dir/etag" \
        --output "$temp_dir/body" --write-out '%{http_code}' "$url")"; then
        printf 'Failed: %s\n' "$filename" >&2
        failures=$((failures + 1))
        continue
    fi

    if [[ "$http_code" == 304 ]]; then
        printf 'Not modified (HTTP 304; download skipped): %s\n' "$filename"
        continue
    fi
    if [[ "$http_code" != 200 || ! -s "$temp_dir/body" ]]; then
        printf 'Rejected empty or unexpected response (%s): %s\n' "$http_code" "$filename" >&2
        failures=$((failures + 1))
        continue
    fi

    if [[ -f "$destination" ]] && cmp -s "$temp_dir/body" "$destination"; then
        printf 'Downloaded (HTTP 200; identical contents): %s\n' "$filename"
    else
        mv -- "$temp_dir/body" "$destination"
        printf 'Updated: %s\n' "$filename"
    fi
    if [[ -s "$temp_dir/etag" ]]; then
        mv -- "$temp_dir/etag" "$etag"
    else
        rm -f -- "$etag"
    fi
done < "$manifest"

if [[ "$failures" -gt 0 ]]; then
    printf '%s download(s) failed. Existing files were preserved.\n' "$failures" >&2
    exit 1
fi