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

# ── preflight ─────────────────────────────────────────────────────────────────

command -v fly &>/dev/null || { echo "flyctl not found — install from https://fly.io/docs/hands-on/install-flyctl/"; exit 1; }

fly auth whoami &>/dev/null || { echo "Not logged in to Fly — run: fly auth login"; exit 1; }

# ── config ────────────────────────────────────────────────────────────────────

echo ""
echo "agent-warphole — Fly.io Setup"
echo ""

read -rp "  App name (must be globally unique): " APP
read -rp "  Region [ord]: " REGION
REGION="${REGION:-ord}"
read -rp "  Persistent volume in GB [none]: " VOLUME_GB

# ── provision ─────────────────────────────────────────────────────────────────

echo ""
echo "Creating app…"
fly apps create "$APP" --machines

echo "Patching fly.toml…"
sed -i.bak "s/^app *=.*/app = \"$APP\"/" "$TOML"
sed -i.bak "s/^primary_region *=.*/primary_region = \"$REGION\"/" "$TOML"
rm -f "${TOML}.bak"

DEPLOY_TOML="$(mktemp "$DEPLOY_DIR/fly.XXXXXX")"
cp "$TOML" "$DEPLOY_TOML"

if [[ -n "$VOLUME_GB" ]]; then
  echo "Creating persistent volume (${VOLUME_GB}gb)…"
  # The volume holds /home/user — claude auth and Claude-side session state survive restarts.
  fly volumes create home \
    --app "$APP" \
    --region "$REGION" \
    --size "$VOLUME_GB" \
    --yes

  cat >> "$DEPLOY_TOML" <<EOF

[[mounts]]
  source      = "home"
  destination = "/home/user"
  initial_size = "${VOLUME_GB}gb"
EOF
else
  echo "Skipping persistent volume — remote auth and Claude-side session state will not survive machine replacement."
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

# ── authenticate claude on the remote ─────────────────────────────────────────

echo ""
echo "VM is up. Authenticate claude on the remote now:"
echo ""
echo "  fly ssh console -a $APP"
echo "  runuser -u user -- claude   # one-time auth/onboarding, then Ctrl-D"
echo ""
read -rp "Press Enter once you've authenticated claude on the remote…"

# Quick sanity check — if this fails the user sees a clear error.
fly ssh console -a "$APP" -C "runuser -u user -- claude --version" \
  || { echo "claude --version failed on remote — check the auth step above."; exit 1; }

# ── write local config ────────────────────────────────────────────────────────

cat > "$CONF" <<EOF
WARPHOLE_AGENT=claude
WARPHOLE_PROVIDER=fly
FLY_APP=$APP
REMOTE_HOME=/home/user
EOF

# ── install slash command ──────────────────────────────────────────────────────

INSTALL_DIR="${HOME}/.claude/warphole"
COMMANDS_DIR="${HOME}/.claude/commands"
SOURCE_DIR="$(cd "$REPO_DIR" && pwd -P)"
INSTALL_DIR_REAL=""

echo "Installing warphole to $INSTALL_DIR…"
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

echo ""
echo "Done."
echo "  Config  → $CONF"
echo "  Command → $COMMANDS_DIR/warphole.md"
echo ""
echo "  Note: terminal attach is local best-effort (Ghostty/Terminal/iTerm supported explicitly)."
echo "  Smoke test:  ./smoke_test.sh --remote"
echo "  Warphole:    /warphole  (inside a Claude Code session)"
echo ""
