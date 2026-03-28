#!/bin/bash
# Scrape/mirror the Icarus wiki from wiki.gg for local hosting.
# Designed to be run by a systemd timer (weekly) or manually.
#
# Usage: ./scrape_wiki.sh

set -uo pipefail
# Note: -e intentionally omitted — we handle errors manually so wget
# non-zero exits (common for 404s, rate limits) don't kill the script.

WIKI_URL="https://icarus.wiki.gg"
WIKI_DIR="/srv/wiki/icarus"
TEMP_DIR="/srv/wiki/.scrape-tmp"
LOG_FILE="/srv/wiki/scrape.log"
LOCK_FILE="/tmp/wiki-scrape.lock"

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Scrape already in progress (PID $pid), skipping." >> "$LOG_FILE"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log "=== Starting wiki scrape from ${WIKI_URL} ==="

# Create directories
mkdir -p "$WIKI_DIR" "$TEMP_DIR"

# Clean temp dir from any previous failed run
rm -rf "${TEMP_DIR:?}/"*

# Use wget to mirror the wiki.
# wiki.gg wikis are MediaWiki-based with mostly server-rendered HTML.
# We start from Main_Page and follow links recursively.
#
# wget --mirror returns non-zero on 404s, robots blocks, etc. — that's
# expected and fine. We check the actual output afterward.
log "Starting wget mirror..."
wget \
    --recursive \
    --level=inf \
    --convert-links \
    --adjust-extension \
    --page-requisites \
    --no-parent \
    --domains=icarus.wiki.gg \
    --reject-regex='(Special:|action=|oldid=|diff=|printable=|User:|User_talk:|Talk:|File:|Template:|Category:.*&|index\.php\?)' \
    --exclude-directories="/w/,/wiki/Special:,/wiki/User:,/wiki/Talk:,/wiki/User_talk:,/wiki/Template:" \
    --wait=1 \
    --random-wait \
    --limit-rate=500K \
    --timeout=30 \
    --tries=3 \
    --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    --directory-prefix="$TEMP_DIR" \
    --execute robots=off \
    --no-verbose \
    "${WIKI_URL}/wiki/Main_Page" \
    >> "$LOG_FILE" 2>&1 || true

# wget with default settings creates TEMP_DIR/icarus.wiki.gg/...
SCRAPED_DIR="${TEMP_DIR}/icarus.wiki.gg"
if [ ! -d "$SCRAPED_DIR" ]; then
    # Fallback: maybe --no-host-directories was used or structure differs
    SCRAPED_DIR="$TEMP_DIR"
fi

HTML_COUNT=$(find "$SCRAPED_DIR" -name "*.html" -o -name "*.htm" 2>/dev/null | wc -l)
log "Scraped ${HTML_COUNT} HTML pages"

if [ "$HTML_COUNT" -lt 1 ]; then
    log "ERROR: No pages scraped at all. wget likely failed to connect or was blocked."
    log "Check if ${WIKI_URL} is reachable: curl -sI ${WIKI_URL}/wiki/Main_Page"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Post-process: strip edit buttons, login links, tracking scripts
log "Post-processing HTML files..."
find "$SCRAPED_DIR" -name "*.html" -print0 | xargs -0 -r sed -i \
    -e 's|<script[^>]*google[^>]*>.*</script>||g' \
    -e 's|<script[^>]*analytics[^>]*>.*</script>||g' \
    -e 's|<script[^>]*tracking[^>]*>.*</script>||g' \
    -e '/<li[^>]*id="ca-edit"[^>]*>/,/<\/li>/d' \
    -e '/<li[^>]*id="ca-viewsource"[^>]*>/,/<\/li>/d' \
    -e '/<div[^>]*id="p-login"[^>]*>/,/<\/div>/d' \
    -e '/<div[^>]*class="mw-indicators"[^>]*>/,/<\/div>/d' \
    2>/dev/null || true

# Inject a local mirror banner into HTML pages
BANNER='<style>.mw-mirror-banner{background:#1a1a2e;color:#e6c65c;text-align:center;padding:6px 12px;font-size:0.8rem;border-bottom:1px solid #e6c65c33;position:sticky;top:0;z-index:1000}.mw-mirror-banner a{color:#e6c65c}</style><div class="mw-mirror-banner">\xf0\x9f\x93\x96 Local mirror hosted by <a href="https://services.meduseld.io">Meduseld</a></div>'

find "$SCRAPED_DIR" -name "*.html" -print0 | xargs -0 -r sed -i \
    -e "s|<body|<body data-mirror=\"meduseld\"|" \
    2>/dev/null || true

# Use perl for the banner injection — sed struggles with multi-line HTML
find "$SCRAPED_DIR" -name "*.html" -print0 | xargs -0 -r perl -pi -e '
    s{(<body[^>]*>)}{$1<style>.mw-mirror-banner{background:#1a1a2e;color:#e6c65c;text-align:center;padding:6px 12px;font-size:0.8rem;border-bottom:1px solid #e6c65c33;position:sticky;top:0;z-index:1000}.mw-mirror-banner a{color:#e6c65c}</style><div class="mw-mirror-banner">\x{1f4d6} Local mirror hosted by <a href="https://services.meduseld.io">Meduseld</a></div>}i;
' 2>/dev/null || true

# Create a simple index.html redirect if one doesn't exist
if [ ! -f "${SCRAPED_DIR}/index.html" ]; then
    # Find the Main_Page file
    MAIN_PAGE=$(find "$SCRAPED_DIR" -path "*/wiki/Main_Page*" -name "*.html" | head -1)
    if [ -n "$MAIN_PAGE" ]; then
        REL_PATH=$(realpath --relative-to="$SCRAPED_DIR" "$MAIN_PAGE")
        cat > "${SCRAPED_DIR}/index.html" << EOF
<!DOCTYPE html>
<html><head><meta http-equiv="refresh" content="0;url=${REL_PATH}"><title>Icarus Wiki</title></head>
<body><a href="${REL_PATH}">Go to wiki</a></body></html>
EOF
    fi
fi

# Swap in the new mirror
if [ -d "$WIKI_DIR" ] && [ "$HTML_COUNT" -gt 0 ]; then
    BACKUP_DIR="/srv/wiki/.icarus-backup"
    rm -rf "$BACKUP_DIR"
    mv "$WIKI_DIR" "$BACKUP_DIR" 2>/dev/null || true
    mv "$SCRAPED_DIR" "$WIKI_DIR"
    rm -rf "$BACKUP_DIR"
else
    mv "$SCRAPED_DIR" "$WIKI_DIR"
fi

# Write sync timestamp
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${WIKI_DIR}/.last-sync"

# Cleanup temp dir
rm -rf "$TEMP_DIR"

FINAL_COUNT=$(find "$WIKI_DIR" -name "*.html" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$WIKI_DIR" 2>/dev/null | cut -f1)
log "Wiki scrape complete: ${FINAL_COUNT} pages, ${TOTAL_SIZE} total"
log "=== Scrape finished ==="
