#!/usr/bin/env bash
# Provision a throwaway npm cache shared by the diagram-render checks, so mermaid-cli is
# downloaded at most once per run and never into the user's own npm cache.
set -eu
d=$(mktemp -d "${TMPDIR:-/tmp}/opsx-eval-npm.XXXXXX")
echo "EVAL_NPM_CACHE=$d" >> "$EVAL_ENV_FILE"
