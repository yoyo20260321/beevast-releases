#!/usr/bin/env bash
#
# RFC 0010 M2 — BeeVast one-line installer.
#
# Usage:
#   GITHUB_TOKEN=ghp_xxx curl -fsSL <install.sh URL> | sh
#
#   # Install a specific env (default prod):
#   GITHUB_TOKEN=ghp_xxx BEEVAST_ENV=pre1 curl -fsSL <install.sh URL> | sh
#
#   # Install a specific channel (default stable):
#   GITHUB_TOKEN=ghp_xxx BEEVAST_CHANNEL=beta curl -fsSL <install.sh URL> | sh
#
#   # Dev/test: install from a local tarball without GitHub:
#   BEEVAST_TARBALL=/path/to/beevast-0.1.0.tar.gz ./install.sh
#
# Behavior (RFC 0010 决策 2/3/4/5/6/10/11/12):
#   - Fail-fast on missing prereqs (Node 22+, npm, GITHUB_TOKEN, GitHub SSH key)
#   - Install into ~/.beevast/apps/<product>/envs/<env>/
#   - npm install better-sqlite3 (no native in tarball)
#   - Clone beevast-shared via SSH (if not already present)
#   - Build ~/.beevast/bin/beevast-<env> symlink
#   - Append PATH export to .zshrc / .bashrc (idempotent)
#

set -euo pipefail

PRODUCT="${BEEVAST_PRODUCT:-master-brain}"
ENV_NAME="${BEEVAST_ENV:-prod}"
CHANNEL="${BEEVAST_CHANNEL:-stable}"
PREFIX="${BEEVAST_PREFIX:-$HOME/.beevast}"
# Default to the PUBLIC release mirror — no PAT required.
# Set BEEVAST_REPO=yoyo20260321/beevast to pull from the private source
# repo (legacy / dev test path); that needs GITHUB_TOKEN.
GITHUB_REPO="${BEEVAST_REPO:-yoyo20260321/beevast-releases}"
SHARED_REPO="${BEEVAST_SHARED_REPO:-git@github.com:yoyo20260321/beevast-shared.git}"
LOCAL_TARBALL="${BEEVAST_TARBALL:-}"

ENV_DIR="$PREFIX/apps/$PRODUCT/envs/$ENV_NAME"
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

# ── 1. prereq checks (RFC 0010 决策 2/3/5) ─────────────────────────────
log "Checking prerequisites..."

# 1.1 Node 22+
command -v node >/dev/null || err "Node 22+ not found. Install: https://nodejs.org/"
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
[ "$NODE_MAJOR" -ge 22 ] || err "Need Node 22+, found v$NODE_MAJOR. Install: https://nodejs.org/"
ok "Node v$(node -p 'process.versions.node')"

# 1.2 npm
command -v npm >/dev/null || err "npm not found (should ship with Node)"
ok "npm $(npm -v)"

# 1.3 GitHub PAT — only required for private repos.
# beevast-releases is public; no token needed. The legacy private-repo
# path (BEEVAST_REPO=yoyo20260321/beevast) still requires GITHUB_TOKEN.
NEED_TOKEN=0
if [ -z "$LOCAL_TARBALL" ]; then
  case "$GITHUB_REPO" in
    yoyo20260321/beevast-releases) NEED_TOKEN=0 ;;
    *)                              NEED_TOKEN=1 ;;
  esac
  if [ "$NEED_TOKEN" -eq 1 ]; then
    [ -n "${GITHUB_TOKEN:-}" ] || err "GITHUB_TOKEN env var required for private repo $GITHUB_REPO. Create at: https://github.com/settings/tokens"
    ok "GITHUB_TOKEN present"
  else
    log "Using public release mirror $GITHUB_REPO (no auth needed)"
  fi
fi

# 1.4 GitHub SSH key (for beevast-shared private repo)
# Note: ssh github.com always exits 1 (no shell), so we can't use the exit
# code. We capture stderr and pattern-match the auth message.
if [ ! -d "$SHARED_DIR/.git" ]; then
  SSH_OUT=$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
  if echo "$SSH_OUT" | grep -q "successfully authenticated"; then
    ok "GitHub SSH key works"
  else
    err "GitHub SSH key not configured. beevast-shared clone needs it. Setup: https://github.com/settings/keys"
  fi
fi

# ── 2. fetch tarball (RFC 0010 §3) ─────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "$LOCAL_TARBALL" ]; then
  log "Using local tarball: $LOCAL_TARBALL"
  [ -f "$LOCAL_TARBALL" ] || err "Tarball not found: $LOCAL_TARBALL"
  cp "$LOCAL_TARBALL" "$TMP/beevast.tar.gz"
  VERSION="local"
else
  log "Fetching latest $CHANNEL release from $GITHUB_REPO..."
  # /releases (plural) returns all releases including prereleases.
  # stable channel filters prerelease=false; beta accepts any.
  AUTH_HEADER=()
  if [ "$NEED_TOKEN" -eq 1 ]; then
    AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
  fi
  RELEASES_JSON=$(curl -fsSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=20") \
    || err "Failed to fetch releases"

  RELEASE_JSON=$(echo "$RELEASES_JSON" | CHANNEL="$CHANNEL" node -e "
    const all = JSON.parse(require('fs').readFileSync(0,'utf8'));
    const channel = process.env.CHANNEL;
    const match = all.find(r =>
      !r.draft && (channel === 'beta' ? true : !r.prerelease)
    );
    if (!match) {
      console.error('no matching release for channel=' + channel);
      process.exit(1);
    }
    process.stdout.write(JSON.stringify(match));
  ") || err "No matching release found on $CHANNEL channel"

  VERSION=$(echo "$RELEASE_JSON" | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name.replace(/^v/,'')")
  # Public repos: use browser_download_url (no auth, plain CDN).
  # Private repos: use asset 'url' + Authorization header + octet-stream.
  if [ "$NEED_TOKEN" -eq 1 ]; then
    ASSET_URL=$(echo "$RELEASE_JSON" | node -p "
      const r = JSON.parse(require('fs').readFileSync(0,'utf8'));
      const a = r.assets.find(x => /\\.tar\\.gz\$/.test(x.name) && !/\\.sha256\$/.test(x.name));
      if (!a) throw new Error('no tarball asset in release');
      a.url
    ")
  else
    ASSET_URL=$(echo "$RELEASE_JSON" | node -p "
      const r = JSON.parse(require('fs').readFileSync(0,'utf8'));
      const a = r.assets.find(x => /\\.tar\\.gz\$/.test(x.name) && !/\\.sha256\$/.test(x.name));
      if (!a) throw new Error('no tarball asset in release');
      a.browser_download_url
    ")
  fi
  ok "Found v$VERSION ($ASSET_URL)"

  log "Downloading tarball..."
  DL_HEADERS=()
  if [ "$NEED_TOKEN" -eq 1 ]; then
    DL_HEADERS+=(-H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/octet-stream")
  fi
  curl -fsSL "${DL_HEADERS[@]}" "$ASSET_URL" -o "$TMP/beevast.tar.gz"
  ok "Downloaded $(du -h "$TMP/beevast.tar.gz" | cut -f1)"
fi

# ── 3. extract to env dir (RFC 0010 §1 layout) ─────────────────────────
log "Installing to $ENV_DIR ..."
mkdir -p "$ENV_DIR"
# Clean previous beevast.mjs / package.json / VERSION (preserve bots/ runtime/ .staging/)
rm -f "$ENV_DIR/beevast.mjs" "$ENV_DIR/package.json" "$ENV_DIR/VERSION"
tar -xzf "$TMP/beevast.tar.gz" -C "$ENV_DIR"
chmod +x "$ENV_DIR/beevast.mjs"
ok "Extracted to $ENV_DIR"

# ── 4. npm install (RFC 0010 决策 4: better-sqlite3 at install time) ───
log "Installing native dependencies (better-sqlite3)..."
(cd "$ENV_DIR" && npm install --omit=dev --silent --no-audit --no-fund) \
  || err "npm install failed in $ENV_DIR"
ok "Native deps installed"

# ── 5. clone beevast-shared if missing (RFC 0009.5) ────────────────────
if [ ! -d "$SHARED_DIR/.agents" ]; then
  log "Cloning beevast-shared..."
  mkdir -p "$(dirname "$SHARED_DIR")"
  git clone --quiet "$SHARED_REPO" "$SHARED_DIR" || err "Failed to clone beevast-shared (check SSH key)"
  ok "beevast-shared cloned to $SHARED_DIR"
else
  log "beevast-shared already at $SHARED_DIR (skipping clone)"
fi

# ── 6. build PATH symlink (RFC 0010 决策 12) ───────────────────────────
mkdir -p "$BIN_DIR"
BIN_LINK="$BIN_DIR/beevast-$ENV_NAME"
ln -sfn "$ENV_DIR/beevast.mjs" "$BIN_LINK"
ok "Linked $BIN_LINK → $ENV_DIR/beevast.mjs"

# Also create / refresh the canonical `beevast` entry — used for the
# unified setup wizard (no env in name). Points at the most recently
# installed env. setup detects "no env from binary path" and prompts.
ln -sfn "$ENV_DIR/beevast.mjs" "$BIN_DIR/beevast"
ok "Linked $BIN_DIR/beevast → $ENV_DIR/beevast.mjs (unified entry)"

# ── 7. PATH wiring (RFC 0010 决策 6: idempotent) ───────────────────────
PATH_LINE='export PATH="$HOME/.beevast/bin:$PATH"'
RC=""
case "${SHELL:-}" in
  */zsh)  RC="$HOME/.zshrc" ;;
  */bash) RC="$HOME/.bashrc" ;;
esac

if [ -n "$RC" ]; then
  if grep -qF '.beevast/bin' "$RC" 2>/dev/null; then
    log "PATH already in $RC (skipping)"
  else
    printf '\n# BeeVast (RFC 0010)\n%s\n' "$PATH_LINE" >> "$RC"
    ok "Appended PATH to $RC"
  fi
else
  warn "Unknown shell ($SHELL). Add this manually to your rc file:"
  printf '  %s\n' "$PATH_LINE"
fi

# ── 8. install shared-sync launchd job (one per machine, idempotent) ──
# Every 30 min pulls ~/.beevast/shared so memory/skills/subagents stay
# current across all envs on this machine. Label is env-independent, so
# installing multiple envs on the same machine only creates ONE job.
if [[ "$(uname -s)" == "Darwin" ]]; then
  SYNC_LABEL="io.beevast.shared-sync"
  SYNC_PLIST="$HOME/Library/LaunchAgents/$SYNC_LABEL.plist"
  if [ ! -f "$SYNC_PLIST" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    # Every 30 minutes (1800 seconds). launchd fires shortly after install
    # too (RunAtLoad implicit via StartInterval scheduling).
    cat > "$SYNC_PLIST" <<PLIST
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
    <string>cd $SHARED_DIR && git pull --ff-only --quiet 2>&amp;1 | tee -a $PREFIX/shared-sync.log</string>
  </array>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>StandardOutPath</key><string>$PREFIX/shared-sync.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/shared-sync.log</string>
</dict>
</plist>
PLIST
    UID=$(id -u)
    launchctl bootstrap "gui/$UID" "$SYNC_PLIST" >/dev/null 2>&1 \
      || launchctl load "$SYNC_PLIST" >/dev/null 2>&1 || true
    ok "Installed shared-sync launchd job (every 30 min)"
  else
    log "shared-sync launchd job already installed (one per machine)"
  fi
fi

# ── 9. done ────────────────────────────────────────────────────────────
echo
ok "Installed beevast-$ENV_NAME v$VERSION → $ENV_DIR"
echo
echo "Next steps:"
echo "  1. Reload your shell:    source ${RC:-<your rc file>}"
echo "  2. Configure a bot:      mkdir -p $ENV_DIR/bots && \\"
echo "                           vim $ENV_DIR/bots/<botId>.json"
echo "  3. Start it:             beevast-$ENV_NAME brain start --bot <botId>"
echo
echo "Optional — launchd autostart (macOS):"
echo "  beevast-$ENV_NAME install --autostart --bot <botId>"
echo
echo "Documentation: docs/runbooks/v2-deploy-workflow.md"
