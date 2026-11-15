#!/bin/zsh
set -eu
cd "${0:A:h}"
open -n "$PWD/dist/$(uname -m)/Codex Accounts.app" --args --demo
