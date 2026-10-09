# Shared helpers for the upstream-state checker checks (sourced, not a check).
CHECKER="$EVAL_ROOT/scripts/mesh-mode/check-upstream-state.sh"
SPIRE_TAG=v1.15.3
DOCROOT="$EVAL_TMP/www"

# Write stand-ins for every source in their "premises hold" shape.
standins_hold() {
  mkdir -p "$DOCROOT/repos/istio/istio/releases" "$DOCROOT/repos/istio/istio/issues" \
    "$DOCROOT/repos/istio/ztunnel/pulls" "$DOCROOT/repos/spiffe/spire/releases" \
    "$DOCROOT/spire/$SPIRE_TAG/doc" "$DOCROOT/istio"
  echo '{"tag_name":"1.31.1","published_at":"2026-09-01T00:00:00Z"}' >"$DOCROOT/repos/istio/istio/releases/latest"
  echo '{"state":"open","title":"Support SPIRE in ambient","updated_at":"2026-09-01T00:00:00Z"}' >"$DOCROOT/repos/istio/istio/issues/42339"
  for n in 1676 1936 2067; do
    echo "{\"state\":\"open\",\"merged_at\":null,\"draft\":false,\"title\":\"PR $n\",\"labels\":[],\"updated_at\":\"2026-09-01T00:00:00Z\"}" >"$DOCROOT/repos/istio/ztunnel/pulls/$n"
  done
  echo "{\"tag_name\":\"$SPIRE_TAG\",\"published_at\":\"2026-09-01T00:00:00Z\"}" >"$DOCROOT/repos/spiffe/spire/releases/latest"
  cat >"$DOCROOT/istio/migrate.html" <<'HTML'
<!doctype html><html><head><title>Istio / Migrate from Sidecar to Ambient</title></head>
<body><h1>Migrate from Sidecar to Ambient</h1><p>Version Istio 1.31</p>
<h2>What is not supported</h2>
<ul><li>SPIRE as the certificate provider. Ambient mode does not support SPIRE integration at this time.</li></ul>
</body></html>
HTML
  spire_doc experimental
}

# spire_doc experimental|stable: the agent reference with the broker key inside or outside the experimental table.
spire_doc() {
  local f="$DOCROOT/spire/$SPIRE_TAG/doc/spire_agent.md"
  {
    echo '# SPIRE Agent Configuration Reference'; echo
    echo 'This document is a configuration reference for SPIRE Agent.'; echo
    echo '## Agent configuration file'; echo
    echo '| Configuration | Description | Default |'
    echo '|:--------------|:------------|:--------|'
    echo '| `data_dir` | A directory the agent can use for its runtime data | $PWD |'
    [ "$1" = stable ] && echo '| `broker` | SPIFFE Broker API configuration | |'
    echo '| `experimental` | The experimental options that are subject to change or removal | |'
    echo
    echo '| experimental | Description | Default |'
    echo '|:-------------|:------------|:--------|'
    echo '| `sync_interval` | Sync interval with SPIRE server | 5s |'
    [ "$1" = experimental ] && echo '| `broker` | SPIFFE Broker API configuration | |'
    echo
    echo '## SPIFFE Broker API'; echo
    if [ "$1" = experimental ]; then echo '> **Status:** experimental'; else echo '> **Status:** stable'; fi
    echo
    echo 'The Broker API lets a trusted broker obtain SVIDs on behalf of workloads.'
  } >"$f"
}

start_standin() {
  python3 "$EVAL_ROOT/evals/service-mesh-mode/_standin.py" "$DOCROOT" "$EVAL_TMP/port" >"$EVAL_TMP/server.log" 2>&1 &
  SERVER_PID=$!
  trap 'kill $SERVER_PID 2>/dev/null' EXIT
  for _ in $(seq 1 100); do [ -s "$EVAL_TMP/port" ] && break; sleep 0.05; done
  [ -s "$EVAL_TMP/port" ] || { echo "stand-in server did not start"; cat "$EVAL_TMP/server.log"; exit 1; }
  PORT=$(cat "$EVAL_TMP/port"); BASE="http://127.0.0.1:$PORT"
}

# run_checker [VAR=value...]: run against the stand-ins with the record in $EVAL_TMP/out-N.
RUN_N=0
run_checker() {
  RUN_N=$((RUN_N + 1)); OUT="$EVAL_TMP/out-$RUN_N"
  # a fake gh that is never logged in, so the GitHub API goes through curl to the stand-in
  mkdir -p "$EVAL_TMP/bin"; printf '#!/bin/sh\nexit 1\n' >"$EVAL_TMP/bin/gh"; chmod +x "$EVAL_TMP/bin/gh"
  env -u CI PATH="$EVAL_TMP/bin:$PATH" HOME="$EVAL_TMP/home" OUT_DIR="$OUT" \
    ISTIO_MIGRATE_URL="$BASE/istio/migrate.html" GITHUB_API="$BASE" SPIRE_DOC_BASE="$BASE/spire" \
    "$@" timeout 120 bash "$CHECKER" >"$EVAL_TMP/stdout-$RUN_N" 2>"$EVAL_TMP/stderr-$RUN_N"
  rc=$?
  RECORD="$OUT/upstream-state.md"
  echo "== run $RUN_N: exit $rc"
  echo "-- stderr:"; cat "$EVAL_TMP/stderr-$RUN_N"
  [ -s "$EVAL_TMP/stdout-$RUN_N" ] && { echo "-- stdout:"; cat "$EVAL_TMP/stdout-$RUN_N"; }
}
record() { cat "$RECORD" 2>/dev/null; }
evidence_untouched_snapshot() { git -C "$EVAL_ROOT" status --porcelain -- docs/evidences/mesh-mode-upstream-state; }
