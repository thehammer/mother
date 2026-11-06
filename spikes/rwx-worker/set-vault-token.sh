#!/usr/bin/env bash
# Store a `claude setup-token` token as CLAUDE_CODE_OAUTH_TOKEN in the RWX
# vault `mother-spike`, without the token touching the clipboard history,
# the command line, the shell history or the process list.
#
#   bash spikes/rwx-worker/set-vault-token.sh
#
# It asks for the token at a hidden prompt, refuses anything that does not
# look like an sk-ant-oat token, writes it to a private temp file only long
# enough for `rwx vaults secrets set --file`, and deletes the file.
set -euo pipefail

vault="${VAULT:-mother-spike}"
org="$(rwx whoami 2>/dev/null | sed -n 's/^Organization: //p')"
if [ "$org" != "carefeed" ]; then
  echo "rwx is logged into '${org:-nothing}', not carefeed (the org this spike uses); nothing was set." >&2
  exit 1
fi
read -r -s -p "Paste the sk-ant-oat token, then Enter: " token
echo
token="$(printf '%s' "$token" | tr -d '[:space:]')"
case "$token" in
  sk-ant-oat*) ;;
  *) echo "That is not an sk-ant-oat token; nothing was set." >&2; exit 1 ;;
esac

umask 077
f="$(mktemp)"
trap 'rm -f "$f"' EXIT
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$f"
unset token
rwx vaults secrets set --vault "$vault" --file "$f"
