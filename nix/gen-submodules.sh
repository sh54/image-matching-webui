#!/usr/bin/env bash
# Regenerate nix/submodules.nix from the current git submodule state.
# Run after any `git submodule update` that bumps revs.
set -euo pipefail
cd "$(dirname "$0")/.."

{
  echo "# Generated from .gitmodules + git ls-tree HEAD."
  echo "# Run nix/gen-submodules.sh to regenerate after submodule bumps."
  echo "{"
  git config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$' \
    | sed 's/^submodule\.\(.*\)\.path$/\1/' \
    | while read -r name; do
        path=$(git config --file .gitmodules "submodule.$name.path")
        url=$(git config --file .gitmodules "submodule.$name.url")
        rev=$(git ls-tree HEAD "$path" | awk '{print $3}')
        short=${path##*/}
        printf '  %s = { url = "%s"; rev = "%s"; path = "%s"; };\n' \
          "$short" "$url" "$rev" "$path"
      done
  echo "}"
} > nix/submodules.nix
