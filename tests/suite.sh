#!/bin/bash
# foamy-monitor's own tests; tests/validate.sh runs this after the linters.
#   --ci    no Quickshell, no Omarchy host: the node tests and the helper's
#           black-box suites (fake hyprctl, systemctl and FluxCast on PATH)
#   --fast  skip the offscreen Quickshell runtime tests
# The other architecture's helper runs too when this machine can execute it
# (qemu-user binfmt on x86_64).
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }

run node tests/model.test.js
run node tests/i18n.test.cjs
run python3 -I tests/test_display_transaction.py
run python3 -I tests/test_fluxcast_bridge.py

other=aarch64
[[ $(uname -m) == aarch64 ]] && other=x86_64
helper="$PWD/bin/$other/foamy-monitor-helper"
# No arguments: the usage text and exit 2, when this machine can run it at all.
"$helper" >/dev/null 2>&1
if (($? == 2)); then
  FOAMY_HELPER="[\"$helper\"]" run python3 -I tests/test_display_transaction.py
  FOAMY_HELPER="[\"$helper\"]" run python3 -I tests/test_fluxcast_bridge.py
else
  skip "the $other helper: this machine can't run it (no qemu-user binfmt)"
fi

if ((ci || fast)); then
  skip "tests/runtime.py, tests/runtime-idle.py, the kit's i18n_runtime.py: offscreen Quickshell"
else
  run python3 tests/runtime.py
  run python3 tests/runtime-idle.py
  if [[ -n ${FOAMY_KIT:-} ]]; then
    run python3 "$FOAMY_KIT/preview/i18n_runtime.py" .
  else
    skip "the kit's i18n_runtime.py: FOAMY_KIT is not set"
  fi
fi
exit $status
