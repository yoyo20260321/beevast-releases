#!/usr/bin/env bash
#
# RFC 0010 M2 + #18 — BeeVast bootstrap installer.
#
# Installs the **dispatcher only** (~/.beevast/bin/beevast). No products
# are installed by this script — once `beevast` is on PATH, run:
#
#   beevast install master-brain --env prod
#
# Usage:
#   curl -fsSL <install.sh URL> | sh
#   BEEVAST_CHANNEL=beta curl -fsSL <install.sh URL> | sh       (rc.x stage)
#   BEEVAST_TARBALL=/path/to/beevast-0.1.0.tar.gz ./install.sh  (dev/test)
#
# Behavior:
#   - Fail-fast on missing prereqs (Node 22+, GitHub SSH key)
#   - Download beevast-<v>.tar.gz from public mirror
#   - Extract dispatcher to ~/.beevast/bin/beevast
#   - Clone beevast-shared to ~/.beevast/shared (for memory/skills)
#   - Append PATH export to .zshrc / .bashrc / .bash_profile (idempotent)
#   - Install shared-sync launchd job (every 30 min git pull, one per machine)
#

set -euo pipefail

CHANNEL="${BEEVAST_CHANNEL:-stable}"
PREFIX="${BEEVAST_PREFIX:-$HOME/.beevast}"
GITHUB_REPO="${BEEVAST_REPO:-yoyo20260321/beevast-releases}"
SHARED_REPO="${BEEVAST_SHARED_REPO:-git@github.com:yoyo20260321/beevast-shared.git}"
LOCAL_TARBALL="${BEEVAST_TARBALL:-}"

BIN_DIR="$PREFIX/bin"
SHARED_DIR="$PREFIX/shared"

# ── color/log helpers ──────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_RESET=''
fi
log()  { printf "%s[install]%s %s\n" "$C_DIM" "$C_RESET" "$*"; }
ok()   { printf "%s✔%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ── 1. prereq checks ───────────────────────────────────────────────────
log "Checking prerequisites..."

command -v node >/dev/null || err "Node 22+ not found. Install: https://nodejs.org/"
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
[ "$NODE_MAJOR" -ge 22 ] || err "Need Node 22+, found v$NODE_MAJOR. Install: https://nodejs.org/"
ok "Node v$(node -p 'process.versions.node')"

NEED_TOKEN=0
if [ -z "$LOCAL_TARBALL" ]; then
  case "$GITHUB_REPO" in
    yoyo20260321/beevast-releases) NEED_TOKEN=0 ;;
    *)                              NEED_TOKEN=1 ;;
  esac
  if [ "$NEED_TOKEN" -eq 1 ]; then
    [ -n "${GITHUB_TOKEN:-}" ] || err "GITHUB_TOKEN env var required for private repo $GITHUB_REPO"
    ok "GITHUB_TOKEN present"
  else
    log "Using public release mirror $GITHUB_REPO (no auth needed)"
  fi
fi

# GitHub SSH key — needed for beevast-shared clone.
if [ ! -d "$SHARED_DIR/.git" ]; then
  SSH_OUT=$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
  if echo "$SSH_OUT" | grep -q "successfully authenticated"; then
    ok "GitHub SSH key works"
  else
    err "GitHub SSH key not configured. beevast-shared clone needs it. Setup: https://github.com/settings/keys"
  fi
fi

# ── 2. fetch dispatcher tarball ────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "$LOCAL_TARBALL" ]; then
  log "Using local tarball: $LOCAL_TARBALL"
  [ -f "$LOCAL_TARBALL" ] || err "Tarball not found: $LOCAL_TARBALL"
  cp "$LOCAL_TARBALL" "$TMP/beevast.tar.gz"
  VERSION="local"
else
  log "Fetching latest $CHANNEL release of beevast dispatcher from $GITHUB_REPO..."
  AUTH_HEADER=()
  if [ "$NEED_TOKEN" -eq 1 ]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
  fi
  RELEASES_JSON=$(curl -fsSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=30") \
    || err "Failed to fetch releases"

  RELEASE_JSON=$(echo "$RELEASES_JSON" | CHANNEL="$CHANNEL" node -e "
    const all = JSON.parse(require('fs').readFileSync(0,'utf8'));
    const channel = process.env.CHANNEL;
    const match = all.find(r =>
      !r.draft &&
      r.tag_name.startsWith('beevast-v') &&
      (channel === 'beta' ? true : !r.prerelease)
    );
    if (!match) {
      console.error('no matching beevast release for channel=' + channel);
      process.exit(1);
    }
    process.stdout.write(JSON.stringify(match));
  ") || err "No matching beevast release for channel=$CHANNEL"

  VERSION=$(echo "$RELEASE_JSON" | node -p "
    JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name.replace(/^beevast-v/, '')
  ")
  if [ "$NEED_TOKEN" -eq 1 ]; then
    ASSET_URL=$(echo "$RELEASE_JSON" | node -p "
      const r = JSON.parse(require('fs').readFileSync(0,'utf8'));
      const a = r.assets.find(x => /^beevast-.*\\.tar\\.gz\$/.test(x.name) && !/\\.sha256\$/.test(x.name));
      if (!a) throw new Error('no beevast tarball asset in release');
      a.url
    ")
  else
    ASSET_URL=$(echo "$RELEASE_JSON" | node -p "
      const r = JSON.parse(require('fs').readFileSync(0,'utf8'));
      const a = r.assets.find(x => /^beevast-.*\\.tar\\.gz\$/.test(x.name) && !/\\.sha256\$/.test(x.name));
      if (!a) throw new Error('no beevast tarball asset in release');
      a.browser_download_url
    ")
  fi
  ok "Found beevast v$VERSION"

  log "Downloading dispatcher tarball..."
  DL_HEADERS=()
  if [ "$NEED_TOKEN" -eq 1 ]; then
    DL_HEADERS+=(-H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/octet-stream")
  fi
  curl -fsSL "${DL_HEADERS[@]}" "$ASSET_URL" -o "$TMP/beevast.tar.gz"
  ok "Downloaded $(du -h "$TMP/beevast.tar.gz" | cut -f1)"
fi

# ── 3. install dispatcher to ~/.beevast/bin/beevast ────────────────────
log "Installing dispatcher to $BIN_DIR ..."
mkdir -p "$BIN_DIR"
# Tarball contains: beevast.mjs + package.json + VERSION. We only need
# beevast.mjs for the dispatcher (no native deps).
tar -xzf "$TMP/beevast.tar.gz" -C "$TMP/extract" 2>/dev/null || {
  mkdir -p "$TMP/extract"
  tar -xzf "$TMP/beevast.tar.gz" -C "$TMP/extract"
}
[ -f "$TMP/extract/beevast.mjs" ] || err "beevast.mjs missing from tarball"
mv "$TMP/extract/beevast.mjs" "$BIN_DIR/beevast"
chmod +x "$BIN_DIR/beevast"
# Make sure the file starts with a shebang.
head -n 1 "$BIN_DIR/beevast" | grep -q '^#!' || {
  printf '#!/usr/bin/env node\n%s' "$(cat "$BIN_DIR/beevast")" > "$BIN_DIR/beevast"
  chmod +x "$BIN_DIR/beevast"
}
ok "Installed $BIN_DIR/beevast v$VERSION"

# Clean legacy per-env binaries left from pre-#18 installs.
rm -f "$BIN_DIR/master-brain-prod" "$BIN_DIR/master-brain-pre1" \
      "$BIN_DIR/master-brain-pre2" "$BIN_DIR/master-brain-pre3" \
      "$BIN_DIR/master-brain" 2>/dev/null || true

# ── 4. clone beevast-shared if missing ─────────────────────────────────
if [ ! -d "$SHARED_DIR/.agents" ]; then
  log "Cloning beevast-shared..."
  mkdir -p "$(dirname "$SHARED_DIR")"
  git clone --quiet "$SHARED_REPO" "$SHARED_DIR" || err "Failed to clone beevast-shared (check SSH key)"
  ok "beevast-shared cloned to $SHARED_DIR"
else
  log "beevast-shared already at $SHARED_DIR (skipping clone)"
fi

# ── 5. PATH wiring (multi-shell, idempotent) ───────────────────────────
PATH_LINE='export PATH="$HOME/.beevast/bin:$PATH"'
WROTE_ANY=0
for RC_NAME in .zshrc .bashrc .bash_profile; do
  RC="$HOME/$RC_NAME"
  [ -f "$RC" ] || continue
  if grep -qF '.beevast/bin' "$RC" 2>/dev/null; then
    log "PATH already in $RC (skipping)"
  else
    printf '\n# BeeVast (RFC 0010)\n%s\n' "$PATH_LINE" >> "$RC"
    ok "Appended PATH to $RC"
    WROTE_ANY=1
  fi
done
if [ "$WROTE_ANY" -eq 0 ] && [ ! -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.bash_profile" ]; then
  warn "No .zshrc / .bashrc / .bash_profile found. Add manually:"
  printf '  %s\n' "$PATH_LINE"
fi

# ── 6. shared-sync launchd job (every 30 min, one per machine) ─────────
if [[ "$(uname -s)" == "Darwin" ]]; then
  SYNC_LABEL="io.beevast.shared-sync"
  SYNC_PLIST="$HOME/Library/LaunchAgents/$SYNC_LABEL.plist"
  DESIRED=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SYNC_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>bash</string>
    <string>-c</string>
    <string>cd $SHARED_DIR &amp;&amp; git pull --ff-only --quiet 2&gt;&amp;1 | tee -a $PREFIX/shared-sync.log</string>
  </array>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>StandardOutPath</key>
  <string>$PREFIX/shared-sync.log</string>
  <key>StandardErrorPath</key>
  <string>$PREFIX/shared-sync.log</string>
</dict>
</plist>
PLIST
)
  BEEVAST_UID=$(id -u)
  if [ ! -f "$SYNC_PLIST" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    printf '%s\n' "$DESIRED" > "$SYNC_PLIST"
    launchctl bootstrap "gui/$BEEVAST_UID" "$SYNC_PLIST" >/dev/null 2>&1 \
      || launchctl load "$SYNC_PLIST" >/dev/null 2>&1 || true
    ok "Installed shared-sync launchd job (every 30 min)"
  elif [ "$(cat "$SYNC_PLIST")" != "$DESIRED" ]; then
    log "shared-sync plist changed, rewriting + reloading"
    launchctl bootout "gui/$BEEVAST_UID/$SYNC_LABEL" >/dev/null 2>&1 || true
    printf '%s\n' "$DESIRED" > "$SYNC_PLIST"
    launchctl bootstrap "gui/$BEEVAST_UID" "$SYNC_PLIST" >/dev/null 2>&1 \
      || launchctl load "$SYNC_PLIST" >/dev/null 2>&1 || true
    ok "Updated shared-sync launchd job"
  else
    log "shared-sync launchd job already up to date (one per machine)"
  fi
fi

# ── 7. done ────────────────────────────────────────────────────────────
echo
ok "Installed beevast dispatcher v$VERSION → $BIN_DIR/beevast"
echo
echo "Next steps:"
echo "  1. Reload your shell:    source ${RC:-<your rc file>}"
echo "  2. Install a product:    beevast install master-brain --env prod"
echo "                           # or: --env pre1 / pre2 / pre3"
echo "                           # use --channel beta for pre-release versions"
echo "  3. Configure a bot:      beevast setup master-brain --env prod"
echo "  4. Start the bot:        beevast start master-brain --env prod --bot <id>"
echo
echo "Docs: docs/runbooks/v2-deploy-workflow.md  |  RFC 0010 (decisions #18-#20)"
