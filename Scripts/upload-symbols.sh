#!/bin/sh
# Uploads the debug symbols (dSYMs) of an app build to Atriya, so crashes and
# hangs show functions, files and lines instead of offsets.
#
#   ATRIYA_UPLOAD_KEY=atr_sk_… upload-symbols.sh MyApp.app.dSYM [more.dSYM …]
#   ATRIYA_UPLOAD_KEY=atr_sk_… upload-symbols.sh path/to/MyApp.xcarchive
#
# Without arguments – as a Run Script phase in Xcode – it takes the dSYMs of
# the current build; Debug builds have none and are skipped. The key is shown
# in the Atriya dashboard under project settings → Debug symbols.
# ATRIYA_URL is the Atriya server, https://intern.atriya.io by default.
#
# Swift names are demangled here with swift-demangle, which only exists on a
# Mac with Xcode, and sent along with the DWARF file.
set -eu

url=${ATRIYA_URL:-https://intern.atriya.io}
key=${ATRIYA_UPLOAD_KEY:-}

# Inside an Xcode build, a failed upload is a warning and the build goes on.
fail() {
  if [ -n "${XCODE_VERSION_ACTUAL:-}" ]; then
    echo "warning: Atriya: $*" >&2
    exit 0
  fi
  echo "error: $*" >&2
  exit 1
}

[ -n "$key" ] || fail "ATRIYA_UPLOAD_KEY is not set – debug symbols were not uploaded."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

list="$work/dsyms"
: > "$list"
if [ $# -eq 0 ]; then
  if [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ] && [ -d "$DWARF_DSYM_FOLDER_PATH" ]; then
    find "$DWARF_DSYM_FOLDER_PATH" -maxdepth 1 -name '*.dSYM' -type d >> "$list"
  fi
else
  for path in "$@"; do
    case "$path" in
      *.dSYM | *.dSYM/) echo "${path%/}" >> "$list" ;;
      *) [ -d "$path" ] && find "$path" -name '*.dSYM' -type d -prune >> "$list" ;;
    esac
  done
fi
if [ ! -s "$list" ]; then
  echo "Atriya: no dSYMs found, nothing to upload."
  exit 0
fi

# POST a gzipped file with the upload key; more curl arguments may follow.
post() { # path, content type, file, …
  path=$1 type=$2 file=$3
  shift 3
  status=$(curl --silent --show-error --output "$work/response" --write-out '%{http_code}' \
    -H "Authorization: Bearer $key" -H "Content-Type: $type" -H 'Content-Encoding: gzip' \
    --data-binary @"$file" "$@" "$url$path") || fail "could not reach $url"
  [ "$status" = 200 ] || fail "upload to $path failed ($status): $(cat "$work/response")"
}

count=0
while IFS= read -r dsym; do
  plist="$dsym/Contents/Info.plist"
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)
  build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)
  for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
    [ -f "$dwarf" ] || continue
    name=$(basename "$dwarf")
    echo "Atriya: uploading $name $version ($build)"

    gzip -c "$dwarf" > "$work/dwarf.gz"
    post /api/symbols application/octet-stream "$work/dwarf.gz" \
      --url-query "name=$name" --url-query "version=$version" --url-query "build=$build"

    # Readable names: Swift via swift-demangle, C++ via c++filt.
    xcrun dwarfdump --debug-str "$dwarf" 2>/dev/null | sed -n 's/^0x[0-9a-f]*: "\([$_][^"]*\)"$/\1/p' > "$work/strings" || true
    nm -j "$dwarf" 2>/dev/null | sed -n 's/^_\([$_].*\)$/\1/p' >> "$work/strings" || true
    grep -E '^\$[sS]' "$work/strings" | sort -u > "$work/swift" || true
    grep -E '^_Z' "$work/strings" | sort -u > "$work/cpp" || true
    : > "$work/names"
    if [ -s "$work/swift" ]; then
      xcrun swift-demangle --simplified --compact < "$work/swift" | paste "$work/swift" - >> "$work/names"
    fi
    if [ -s "$work/cpp" ]; then
      xcrun c++filt < "$work/cpp" | paste "$work/cpp" - >> "$work/names"
    fi
    if [ -s "$work/names" ]; then
      gzip -c "$work/names" > "$work/names.gz"
      for uuid in $(xcrun dwarfdump --uuid "$dwarf" | awk '{ print $2 }'); do
        post "/api/symbols/$uuid/names" text/tab-separated-values "$work/names.gz"
      done
    fi
    count=$((count + 1))
  done
done < "$list"

echo "Atriya: uploaded $count debug symbol file(s) to $url."
