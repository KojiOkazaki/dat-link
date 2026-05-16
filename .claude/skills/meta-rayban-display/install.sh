#!/usr/bin/env bash
# Install the meta-rayban-display skill into your Claude Code user scope.
# After install, you can invoke it from any Claude Code session with
# `/meta-rayban-display` or by mentioning Meta Ray-Ban Display in a prompt.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEST="${HOME}/.claude/skills/meta-rayban-display"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$SCRIPT_DIR" "$DEST"
# Don't ship the installer itself into the global skill dir.
rm -f "$DEST/install.sh"

echo "Installed meta-rayban-display skill to: $DEST"
echo ""
echo "Skill contents:"
ls -la "$DEST"
echo ""
echo "Try it from any Claude Code session: /meta-rayban-display"
