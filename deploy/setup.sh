#!/usr/bin/env bash
# One-time Fly.io VM provisioning for claude-teleport.
#
# Run this once. After it completes, `teleport setup` (or editing
# ~/.claude/teleport.conf) is all you need for each new machine.

set -euo pipefail

CONF="${HOME}/.claude/teleport.conf"
TOML="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fly.toml"

# ── preflight ─────────────────────────────────────────────────────────────────

command -v fly  &>/dev/null || { echo "flyctl not found — install from https://fly.io/docs/hands-on/install-flyctl/"; exit 1; }
command -v node &>/dev/null || { echo "node not found — needed to verify claude install"; exit 1; }

fly auth whoami &>/dev/null || { echo "Not logged in to Fly — run: fly auth login"; exit 1; }

# ── config ────────────────────────────────────────────────────────────────────

echo ""
echo "Claude Teleport — Fly.io Setup"
echo ""

read -rp "  App name (must be globally unique): " APP
read -rp "  Region [ord]: " REGION
REGION="${REGION:-ord}"

# ── provision ─────────────────────────────────────────────────────────────────

echo ""
echo "Creating app…"
fly apps create "$APP" --machines

echo "Creating persistent volume (20gb)…"
# The volume holds /root — project files and claude sessions survive restarts.
fly volumes create home \
  --app "$APP" \
  --region "$REGION" \
  --size 20 \
  --yes

echo "Patching fly.toml…"
sed -i.bak "s/^app.*=.*/app = \"$APP\"/" "$TOML"
sed -i.bak "s/^primary_region.*=.*/primary_region = \"$REGION\"/" "$TOML"
rm -f "${TOML}.bak"

echo "Deploying image (this builds and pushes — ~2 min first time)…"
fly deploy --app "$APP" --config "$TOML" --wait-timeout 120

# ── authenticate claude on the remote ─────────────────────────────────────────

echo ""
echo "VM is up. Authenticate claude on the remote now:"
echo ""
echo "  fly ssh console -a $APP"
echo "  claude   # follow the auth prompt, then Ctrl-D to exit"
echo ""
read -rp "Press Enter once you've authenticated claude on the remote…"

# Quick sanity check — if this fails the user sees a clear error.
fly ssh console -a "$APP" -C "claude --version" \
  || { echo "claude --version failed on remote — check the auth step above."; exit 1; }

# ── write local config ────────────────────────────────────────────────────────

cat > "$CONF" <<EOF
TELEPORT_AGENT=claude
TELEPORT_PROVIDER=fly
FLY_APP=$APP
EOF

echo ""
echo "Done."
echo "  Config → $CONF"
echo ""
echo "  Smoke test:  ./smoke_test.sh --remote"
echo "  Teleport:    /teleport  (inside a Claude Code session)"
echo ""
