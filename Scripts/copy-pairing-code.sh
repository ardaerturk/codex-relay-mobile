#!/usr/bin/env bash
# macOS helper: use an existing SSH config alias; never print the credential.
set -euo pipefail
if [[ $# -ne 1 || "$1" == -* ]]; then
  printf 'Usage: %s your-ssh-host\n' "$0" >&2
  exit 2
fi
if ! command -v pbcopy >/dev/null; then
  printf 'This clipboard helper requires macOS. Read the pairing file directly on your VM instead.\n' >&2
  exit 1
fi
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$1" \
  'cat "$HOME/.local/state/relay/pairing-token"' | pbcopy
printf 'Pairing code copied to the clipboard. Paste it into your private Relay app.\n'
