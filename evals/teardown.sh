#!/usr/bin/env bash
# Remove the npm cache provisioned by setup.sh.
set -u
d=$(sed -n 's/^EVAL_NPM_CACHE=//p' "${EVAL_ENV_FILE:-/dev/null}" | tail -1)
case "$d" in
  "${TMPDIR:-/tmp}"/opsx-eval-npm.*) rm -rf -- "$d" ;;
esac
exit 0
