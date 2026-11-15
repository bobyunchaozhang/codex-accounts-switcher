#!/bin/zsh
set -eu
cd "${0:A:h}"
open "$PWD/dist/$(uname -m)/Codex Accounts.app"
