#!/usr/bin/env bash
# One-time Fly.io VM provisioning for agent-warphole.
#
# Run this once. After it completes, `warphole setup` (or editing
# ~/.claude/warphole.conf) is all you need for each new machine.

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$DEPLOY_DIR")"
CONF="${HOME}/.claude/warphole.conf"
TOML="$DEPLOY_DIR/fly.toml"
DEFAULT_APP="ez-pz-agent-warphole"

# ── preflight ─────────────────────────────────────────────────────────────────

command -v fly &>/dev/null || { echo "flyctl not found — install from https://fly.io/docs/hands-on/install-flyctl/"; exit 1; }

fly auth whoami &>/dev/null || { echo "Not logged in to Fly — run: fly auth login"; exit 1; }

# ── config ────────────────────────────────────────────────────────────────────

echo ""
echo "agent-warphole — Fly.io Setup"
echo ""

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

APP_DEFAULT="${FLY_APP:-$DEFAULT_APP}"
read -rp "  App name [$APP_DEFAULT]: " APP
APP="${APP:-$APP_DEFAULT}"
read -rp "  Region [ord]: " REGION
REGION="${REGION:-ord}"
read -rp "  Persistent volume in GB [none]: " VOLUME_GB

# ── provision ─────────────────────────────────────────────────────────────────

echo ""
if fly apps show "$APP" >/dev/null 2>&1; then
  echo "Reusing existing app: $APP"
else
  echo "Creating app…"
  fly apps create "$APP" --machines
fi

echo "Patching fly.toml…"
sed -i.bak "s/^app *=.*/app = \"$APP\"/" "$TOML"
sed -i.bak "s/^primary_region *=.*/primary_region = \"$REGION\"/" "$TOML"
rm -f "${TOML}.bak"

DEPLOY_TOML="$(mktemp "$DEPLOY_DIR/fly.XXXXXX")"
cp "$TOML" "$DEPLOY_TOML"

if [[ -n "$VOLUME_GB" ]]; then
  if fly volumes list -a "$APP" | awk 'NR>1 {print $1}' | grep -qx 'home'; then
    echo "Reusing existing persistent volume: home"
  else
    echo "Creating persistent volume (${VOLUME_GB}gb)…"
    # The volume holds /home/user — claude auth and Claude-side session state survive restarts.
    fly volumes create home \
      --app "$APP" \
      --region "$REGION" \
      --size "$VOLUME_GB" \
      --yes
  fi

  cat >> "$DEPLOY_TOML" <<EOF

[[mounts]]
  source      = "home"
  destination = "/home/user"
  initial_size = "${VOLUME_GB}gb"
EOF
else
  echo "Skipping persistent volume — remote auth and Claude-side session state will not survive machine replacement."
  if fly volumes list -a "$APP" | awk 'NR>1 {print $1}' | grep -qx 'home'; then
    echo "Existing 'home' volume detected and left untouched. Destroy it manually if you want to release that storage."
  fi
fi

# ── SSH key for rsync ─────────────────────────────────────────────────────────

pubkey=""
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
  [[ -f "$f" ]] && { pubkey=$(cat "$f"); break; }
done
if [[ -z "$pubkey" ]]; then
  echo "No SSH public key found — generating ~/.ssh/id_ed25519…"
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
  pubkey=$(cat ~/.ssh/id_ed25519.pub)
fi
echo "Using SSH key: ${pubkey%% *} …"
fly secrets set SSH_PUBKEY="$pubkey" -a "$APP" --stage

echo "Deploying image (this builds and pushes — ~2 min first time)…"
# Run from DEPLOY_DIR so Fly uses the deploy/ Dockerfile as the build context.
(cd "$DEPLOY_DIR" && fly deploy --app "$APP" --config "$DEPLOY_TOML" --wait-timeout 120)
rm -f "$DEPLOY_TOML"

# ── authenticate agent CLIs on the remote ─────────────────────────────────────

echo ""
echo "VM is up. Authenticate Claude on the remote now if you plan to use the Claude adapter:"
echo ""
echo "  fly ssh console -a $APP"
echo "  runuser -u user -- claude   # one-time auth/onboarding, then Ctrl-D"
echo ""
echo "Codex is also installed on the VM."
echo "Codex auth is synced from local ~/.codex/auth.json during a codex warphole run,"
echo "so no separate remote codex login step is required unless you want one."
echo ""
read -rp "Press Enter once you're ready to continue…"

# Quick sanity checks — if these fail the user sees a clear error.
fly ssh console -a "$APP" -C "runuser -u user -- claude --version" \
  || { echo "claude --version failed on remote — check the auth step above."; exit 1; }
fly ssh console -a "$APP" -C "runuser -u user -- codex --version" \
  || { echo "codex --version failed on remote."; exit 1; }

# ── write local config ────────────────────────────────────────────────────────

cat > "$CONF" <<EOF
WARPHOLE_PROVIDER=fly
FLY_APP=$APP
REMOTE_HOME=/home/user
EOF

# ── install slash command ──────────────────────────────────────────────────────

INSTALL_DIR="${HOME}/.claude/warphole"
COMMANDS_DIR="${HOME}/.claude/commands"
CODEX_SKILLS_DIR="${HOME}/.codex/skills"
SOURCE_DIR="$(cd "$REPO_DIR" && pwd -P)"
INSTALL_DIR_REAL=""

echo "Installing warphole to $INSTALL_DIR..."
if [[ -e "$INSTALL_DIR" ]]; then
  INSTALL_DIR_REAL="$(cd "$INSTALL_DIR" && pwd -P)"
fi

if [[ "$SOURCE_DIR" == "$INSTALL_DIR_REAL" ]]; then
  echo "  Source already lives at $INSTALL_DIR; leaving it in place."
else
  rm -rf "$INSTALL_DIR"
  cp -r "$REPO_DIR" "$INSTALL_DIR"
fi

mkdir -p "$COMMANDS_DIR"
cp "$INSTALL_DIR/skill/warphole.md" "$COMMANDS_DIR/warphole.md"

mkdir -p "$CODEX_SKILLS_DIR/warphole"
cp "$INSTALL_DIR/codex-skill/warphole/SKILL.md" "$CODEX_SKILLS_DIR/warphole/SKILL.md"

echo ""
echo "Done."
echo "  Config  → $CONF"
echo "  Command → $COMMANDS_DIR/warphole.md"
echo "  Codex   → $CODEX_SKILLS_DIR/warphole/SKILL.md"
echo ""
echo "  Note: terminal attach is local best-effort (Ghostty/Terminal/iTerm supported explicitly)."
echo "  Smoke test:  ./smoke_test.sh --remote"
echo "  Warphole:    /warphole  (inside a Claude Code session)"
echo ""
