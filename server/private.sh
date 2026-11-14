#!/usr/bin/env bash
# Copyright (C) 2026 teofilcelzmecher. All rights reserved. See LICENSE.
#
# (1.7.5) Budgie's server code comes from a private repository on GitHub, no longer from the public website. Run this
# once on the laptop:
#
#   sudo nook private
#
# 1. It makes a key for this laptop (only root can read it) and shows its public half.
# 2. You add that on GitHub, to the private repository, as a read-only "deploy key".
# 3. It fetches the server from there into /opt/budgie-server, moves the service onto it and checks that it answers.
#    The database stays where it is (/var/lib/nook). If the server doesn't answer, it goes back to how it was.
#
# From then on, `nook update` gets updates from the private repository. Safe to run again.
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "Run me with sudo:  sudo nook private"
  exit 1
fi

SOURCE="${1:-teofilcelzmecher/budgie-server}"
BRANCH="${2:-main}"
OLD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW=/opt/budgie-server
KEYS=/etc/nook
KEY=$KEYS/deploy-key
HOSTS=$KEYS/known_hosts

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "This laptop's key for the private repository"
command -v ssh-keygen >/dev/null || pacman -S --needed --noconfirm openssh
install -d -m 700 "$KEYS"
# GitHub's own key (as GitHub publishes it, docs.github.com: "GitHub's SSH key fingerprints",
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU): the laptop talks to GitHub, and nobody else
cat > "$HOSTS" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
[ssh.github.com]:443 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
EOF
chmod 600 "$HOSTS"
[[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "budgie-laptop" -f "$KEY"
chmod 600 "$KEY"
SSH="ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOSTS -o StrictHostKeyChecking=yes -o ConnectTimeout=15"

# GitHub answers on SSH's own port, and on 443 for networks that block that
URLS=("git@github.com:$SOURCE.git" "ssh://git@ssh.github.com:443/$SOURCE.git")
reach() {
  for u in "${URLS[@]}"; do
    if GIT_SSH_COMMAND="$SSH" git ls-remote --exit-code "$u" "refs/heads/$BRANCH" >/dev/null 2>&1; then
      URL=$u
      return 0
    fi
  done
  return 1
}

URL=""
until reach; do
  cat <<EOF

The laptop can't read github.com/$SOURCE yet. Add its key there, once:

  1. Open  https://github.com/$SOURCE/settings/keys/new
  2. Title: Budgie laptop
  3. Key: copy this whole line in:

$(cat "$KEY.pub")

  4. Leave "Allow write access" OFF, and press "Add key".

EOF
  read -r -p "Press Enter once it's added (or Ctrl+C to stop here) "
done
echo "The laptop can read $SOURCE."

step "Fetching the server into $NEW"
rm -rf "$NEW.new"
GIT_SSH_COMMAND="$SSH" git clone --quiet --depth 1 --branch "$BRANCH" "$URL" "$NEW.new"
git -C "$NEW.new" config core.sshCommand "$SSH"
[[ -f $NEW.new/server/server.js ]] || { echo "There's no server/server.js in $SOURCE ($BRANCH)."; rm -rf "$NEW.new"; exit 1; }
if [[ -d $NEW ]]; then
  rm -rf "$NEW.old"
  mv "$NEW" "$NEW.old"
fi
mv "$NEW.new" "$NEW"

step "Moving Budgie's service onto it"
if bash "$NEW/server/install.sh" --update; then
  rm -rf "$NEW.old"
  cat <<EOF

Done. Budgie's server now comes from the private repository $SOURCE.
'sudo nook update' gets its updates from there; the database is where it was.
EOF
  if [[ "$OLD" != "$NEW" ]]; then
    echo
    echo "The old copy in $OLD isn't used any more. Once Budgie has been running fine for a while, delete it:"
    echo "  sudo rm -rf $OLD"
  fi
else
  echo
  echo "The server didn't start from the new copy, so Budgie goes back to how it was."
  if [[ -d $NEW.old ]]; then
    # run again: the copy it had before
    rm -rf "$NEW"
    mv "$NEW.old" "$NEW"
    bash "$NEW/server/install.sh" --update || true
  elif [[ "$OLD" != "$NEW" ]]; then
    bash "$OLD/server/install.sh" --update || true
  fi
  exit 1
fi
