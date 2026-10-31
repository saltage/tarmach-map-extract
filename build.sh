#!/bin/bash
# Build Tarmach's monthly-roundup basemap extracts: PMTiles in the
# OpenMapTiles schema, cut down to the layers the Tarmac style and the
# roundup's cards read, with A/B roads at month scale.
#
#   ./build.sh setup            # JDK, planetiler, pmtiles, sources
#   ./build.sh london|gb|world  # one extract
#   ./build.sh gb-slim          # GB without place names
#   ./build.sh all              # all three
#   ./build.sh verify           # tile counts and layer checks
#
# Everything is written under $TARMAC_EXTRACTS (default ./work):
#   bin/      planetiler.jar
#   sources/  OSM PBFs (Geofabrik), water polygons, Natural Earth, lake lines
#   out/      the .pmtiles, plus each build's log and time/memory figures
#   tmp/      planetiler's scratch, deleted after every build
#
# Needs Java 21+ and Homebrew (macOS): this calls Homebrew's openjdk@21 by
# full path and never touches the system Java. Override with JAVA=... and
# PMTILES=... elsewhere. `setup --refresh` fetches fresh sources.
#
# The profile is profile/TarmacExtract.java: planetiler's own
# OpenMapTiles profile, subclassed to add primary/secondary roads at z5-8 and
# numbered roads' names and refs from z9. Java 21 runs it from source, so there
# is no compile step. See that file's header for exactly what it adds.
#
# Licences: the output is a Derivative Database of OpenStreetMap under the ODbL. This
# script, with the source dates recorded in out/SOURCES.txt, is the "method"
# ODbL 4.6 lets us offer instead of the database itself.

set -euo pipefail

ROOT="${TARMAC_EXTRACTS:-$(cd "$(dirname "$0")" && pwd)/work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="$HERE/profile/TarmacExtract.java"
PLANETILER_VERSION=0.10.2
JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
PMTILES="${PMTILES:-$(command -v pmtiles || echo /opt/homebrew/bin/pmtiles)}"

BIN="$ROOT/bin"; SRC="$ROOT/sources"; OUT="$ROOT/out"; TMP="$ROOT/tmp"

# The layers the app reads. Its map style draws water, waterway,
# transportation and (optionally) place; its summary cards read
# transportation_name (road-number shields), mountain_peak (a journey's high
# point) and water_name (sea names). The style's building layer starts at z15, beyond every
# extract here, so it is left out.
LAYERS="${LAYERS:-water,waterway,transportation,transportation_name,place,mountain_peak,water_name}"

die() { echo "build.sh: $*" >&2; exit 1; }

need_java() {
  [ -x "$JAVA" ] || die "no Java 21 at $JAVA. Run: brew install openjdk@21"
  "$JAVA" -version 2>&1 | grep -qE 'version "(2[1-9]|[3-9][0-9])' || die "$JAVA is not Java 21+"
}

# Pins. Where the upstream publishes a checksum next to the
# file (Geofabrik's .md5), the download is checked against it. Everywhere else
# the hash is recorded on first fetch (trust on first use) in $SRC/PINS.sha256,
# and every later reuse is checked against it, so a swapped or truncated file
# in sources/ is refused instead of silently reused. `setup --refresh`
# re-fetches and re-records.
pin_file() { echo "$SRC/PINS.sha256"; }

pin_check() { # dest -> 0 if ok or unpinned, 1 on mismatch
  local dest="$1" name want got
  name="$(basename "$dest")"
  [ -f "$(pin_file)" ] || return 0
  want="$(awk -v n="$name" '$2 == n { print $1 }' "$(pin_file)")"
  [ -n "$want" ] || return 0
  got="$(shasum -a 256 "$dest" | awk '{ print $1 }')"
  [ "$want" = "$got" ]
}

pin_record() { # dest
  local dest="$1" name tmp
  name="$(basename "$dest")"
  touch "$(pin_file)"
  tmp="$(pin_file).new"
  awk -v n="$name" '$2 != n' "$(pin_file)" > "$tmp"
  printf '%s  %s\n' "$(shasum -a 256 "$dest" | awk '{ print $1 }')" "$name" >> "$tmp"
  mv "$tmp" "$(pin_file)"
}

fetch() { # url dest [published-md5-url]
  local url="$1" dest="$2" md5url="${3:-}"
  if [ -s "$dest" ] && [ "${REFRESH:-0}" != 1 ]; then
    pin_check "$dest" || die "$(basename "$dest") does not match its recorded checksum in $(pin_file); delete it and re-run setup, or use setup --refresh"
    echo "have $(basename "$dest")"; return
  fi
  echo "fetching $url"
  curl -fSL --retry 3 -o "$dest.part" "$url" || { rm -f "$dest.part"; die "download failed: $url"; }
  if [ -n "$md5url" ]; then
    local want got
    want="$(curl -fsSL --retry 3 "$md5url" | awk '{ print $1; exit }')"
    got="$(md5 -q "$dest.part")"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      rm -f "$dest.part"; die "$(basename "$dest") fails the upstream checksum at $md5url"
    fi
  fi
  mv "$dest.part" "$dest"
  pin_record "$dest"
}

setup() {
  [ "${1:-}" = "--refresh" ] && REFRESH=1
  mkdir -p "$BIN" "$SRC" "$OUT"
  command -v brew >/dev/null || die "Homebrew is needed for the JDK and pmtiles"
  [ -x "$JAVA" ] || brew install openjdk@21
  command -v pmtiles >/dev/null || brew install pmtiles
  need_java
  fetch "https://github.com/onthegomap/planetiler/releases/download/v$PLANETILER_VERSION/planetiler.jar" "$BIN/planetiler.jar"
  fetch "https://download.geofabrik.de/europe/great-britain-latest.osm.pbf" "$SRC/great-britain-latest.osm.pbf" "https://download.geofabrik.de/europe/great-britain-latest.osm.pbf.md5"
  fetch "https://download.geofabrik.de/europe/united-kingdom/england/greater-london-latest.osm.pbf" "$SRC/greater-london-latest.osm.pbf" "https://download.geofabrik.de/europe/united-kingdom/england/greater-london-latest.osm.pbf.md5"
  fetch "https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip" "$SRC/water-polygons-split-3857.zip"
  fetch "https://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip" "$SRC/natural_earth_vector.sqlite.zip"
  fetch "https://github.com/acalcutt/osm-lakelines/releases/download/latest/lake_centerline.shp.zip" "$SRC/lake_centerline.shp.zip"
  # The world layer's OSM input: Geofabrik's smallest extract, because the
  # profile needs one. At z0-6 the world comes from Natural Earth (water,
  # rivers, major roads) and the water polygons (coastline).
  fetch "https://download.geofabrik.de/europe/monaco-latest.osm.pbf" "$SRC/monaco-latest.osm.pbf" "https://download.geofabrik.de/europe/monaco-latest.osm.pbf.md5"
  sources_record
}

sources_record() {
  # A failed `pmtiles show` used to be hidden (2>/dev/null || true) and wrote
  # "OSM as of , from". Now it stops the build and a missing date is an error.
  local f shown date url
  {
    echo "# Sources of the Tarmac roundup extracts (ODbL 4.6: the method to rebuild)"
    echo "built_with: build.sh, planetiler $PLANETILER_VERSION, profile TarmacExtract.java"
    for f in "$SRC"/*; do
      [ -f "$f" ] || continue
      printf '%s  %s bytes  modified %s\n' "$(basename "$f")" "$(stat -f %z "$f")" "$(stat -f %Sm -t %Y-%m-%d "$f")"
    done
    for f in "$OUT"/*.pmtiles; do
      [ -f "$f" ] || continue
      shown="$("$PMTILES" show "$f")" || die "pmtiles show failed on $f; SOURCES.txt not written"
      date="$(printf '%s\n' "$shown" | awk '/osmosisreplicationtime/{print $2}')"
      url="$(printf '%s\n' "$shown" | awk '/osmosisreplicationurl/{print $2}')"
      [ -n "$date" ] || die "$(basename "$f") carries no osmosisreplicationtime; SOURCES.txt not written"
      echo "$(basename "$f"): OSM as of $date, from $url"
    done
  } > "$OUT/SOURCES.txt.new" || { rm -f "$OUT/SOURCES.txt.new"; return 1; }
  mv "$OUT/SOURCES.txt.new" "$OUT/SOURCES.txt"
}

# build <name> <osm.pbf> <maxzoom> [extra planetiler args...]
build() {
  local name="$1" osm="$2" maxzoom="$3"; shift 3
  need_java
  [ -s "$SRC/$osm" ] || die "missing $SRC/$osm; run: $0 setup"
  mkdir -p "$OUT"; rm -rf "$TMP"; mkdir -p "$TMP"
  local out="$OUT/$name.pmtiles" log="$OUT/$name.log"
  echo "building $name (z0-$maxzoom) -> $out"
  # /usr/bin/time -l reports wall time and the peak resident set (bytes).
  /usr/bin/time -l "$JAVA" -Xmx"${XMX:-24g}" -cp "$BIN/planetiler.jar" "$PROFILE" \
    --download_dir="$SRC" \
    --osm_path="$SRC/$osm" \
    --output="$out" --force \
    --tmpdir="$TMP" \
    --maxzoom="$maxzoom" --render_maxzoom="$maxzoom" \
    --only_layers="$LAYERS" \
    --languages=en \
    --transportation_name_size_for_shield=true \
    --color=false \
    "$@" > "$log" 2>&1 || { tail -40 "$log"; rm -rf "$TMP"; die "$name failed; log $log"; }
  rm -rf "$TMP"
  local secs rss
  secs=$(grep -Eo '[0-9.]+ real' "$log" | tail -1 | cut -d' ' -f1)
  rss=$(awk '/maximum resident set size/{print $1}' "$log" | tail -1)
  local foot; foot=$(awk '/peak memory footprint/{print $1}' "$log" | tail -1)
  printf '%s\t%s bytes\t%ss\tpeak RSS %s\tpeak footprint %s\n' "$name" "$(stat -f %z "$out")" "$secs" "$rss" "$foot" | tee -a "$OUT/SIZES.tsv"
}

london() {
  # Greater London to z13: overzooms cleanly to street scale.
  build london greater-london-latest.osm.pbf "${LONDON_MAXZOOM:-13}" "$@"
}

gb() {
  # Great Britain to z12 (minor roads exist from z12; MapLibre overzooms).
  build "${GB_NAME:-gb}" great-britain-latest.osm.pbf "${GB_MAXZOOM:-12}" "$@"
}

gb_slim() {
  # Great Britain without the place layer (town and village names), which is
  # about a third of the bytes at z9-11 and which the default style never
  # draws (its place-label layer needs glyphs, and the app's map place names
  # are off by default; pin names come from the app's own Places).
  GB_NAME=gb-noplace LAYERS="water,waterway,transportation,transportation_name,mountain_peak,water_name" gb "$@"
}

world() {
  # The low-zoom world layer, for months abroad: z0-6, whole world bounds.
  # Natural Earth's major roads stand in for OSM's, which would need the
  # ~80 GB planet file.
  build world monaco-latest.osm.pbf "${WORLD_MAXZOOM:-6}" --bounds=world --tarmac_ne_roads=true "$@"
}

verify_one() { # file
  local f="$1"
  echo "== $(basename "$f")"
  "$PMTILES" show "$f" | grep -E -i "tile type|min zoom|max zoom|bounds|addressed tiles|tile contents|tile entries|clustered|attribution|name" || true
  "$PMTILES" verify "$f" && echo "verify: ok"
}

verify() {
  for f in "$OUT"/*.pmtiles; do verify_one "$f"; done
  python3 "$HERE/tools/inspect.py" "$OUT"/*.pmtiles
}

# Tests source this file for its functions.
[ "${EXTRACT_BUILD_SOURCED:-0}" = 1 ] && return 0

cmd="${1:-}"; shift || true
case "$cmd" in
  setup) setup "$@" ;;
  london) london "$@"; sources_record ;;
  gb) gb "$@"; sources_record ;;
  gb-slim) gb_slim "$@"; sources_record ;;
  world) world "$@"; sources_record ;;
  # gb-noplace is what the app ships as gb.pmtiles, so `all` builds it.
  all) london; gb; gb_slim; world; sources_record ;;
  sources) sources_record; cat "$OUT/SOURCES.txt" ;;
  verify) verify ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
