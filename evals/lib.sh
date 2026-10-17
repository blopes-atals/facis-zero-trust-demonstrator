# Shared helpers for the openbao-own-release checks (sourced, not run).
set -u
: "${EVAL_ROOT:?}" "${EVAL_TMP:?}"
KCTX=${KUBE_CONTEXT:-kind-ztd}
[ "$KCTX" = kind-ztd ] || { echo "refusing context $KCTX (only kind-ztd)"; exit 1; }
INSTALL=$EVAL_ROOT/scripts/install-zone/install.sh
KIND_ZONE=$EVAL_ROOT/deployment/helm/ztd/ci/values.yaml
ZONES=$EVAL_ROOT/deployment/helm/ztd/zones
MGMT=ztd-mgmt

# cache: a private chart cache in EVAL_TMP, seeded with symlinks to the operator's cache when there
# is one (read only), so the checks do not touch $HOME and need no network when it is warm.
cache() {
  local src=${EVAL_CACHE_SRC:-$HOME/.cache/ztd-install-zone}
  mkdir -p "$EVAL_TMP/cache"
  [ -d "$src" ] && cp -rs "$src"/. "$EVAL_TMP/cache"/ 2>/dev/null
  export INSTALL_ZONE_CACHE=$EVAL_TMP/cache
}

# render <zone-file> <release...>: render into $EVAL_TMP/out (RENDER_DIR); sets RC and OUT.
render() {
  local zone=$1; shift
  rm -rf "$EVAL_TMP/out"; mkdir -p "$EVAL_TMP/out"
  cache
  OUT=$(ZONE_VALUES=$zone RENDER_DIR=$EVAL_TMP/out "$INSTALL" render "$@" 2>&1); RC=$?
}

# zone_with <name> <python-expr on d>: write a modified copy of the kind zone file.
zone_with() {
  python3 - "$KIND_ZONE" "$EVAL_TMP/$1.yaml" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
exec(sys.argv[3])
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
}

k() { kubectl --context "$KCTX" "$@"; }

need_cluster() {
  [ -f "${EVAL_INSTALLED:-/nonexistent}" ] && return 0
  k get ns "$MGMT" >/dev/null 2>&1 && k -n "$MGMT" get sts ztd-openbao >/dev/null 2>&1 && return 0
  echo "the zone is not installed on $KCTX (setup failed or skipped)"; exit 77
}

# setup_file <name>: a file the setup left in SETUP_DIR, or UNVERIFIABLE when setup did not run.
setup_file() {
  [ -n "${SETUP_DIR:-}" ] && [ -f "$SETUP_DIR/$1" ] || { echo "setup left no $1 (no cluster, or setup skipped)"; exit 77; }
  echo "$SETUP_DIR/$1"
}

# pods_not_ready <ns...>: pods that are neither Succeeded nor Ready (finished job pods excluded).
pods_not_ready() {
  for ns in "$@"; do
    k -n "$ns" get pods -o json | jq -r --arg ns "$ns" '.items[]
      | select(.status.phase != "Succeeded")
      | select(([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length) == 0)
      | "\($ns)/\(.metadata.name)"'
  done
}

# chart_copy: a copy of ztd-openbao with its built dependency, in $EVAL_TMP/chart.
chart_copy() {
  rm -rf "$EVAL_TMP/chart"; cp -r "$EVAL_ROOT/deployment/helm/ztd-openbao" "$EVAL_TMP/chart"
  mkdir -p "$EVAL_TMP/chart/charts"
  local tgz
  tgz=$(ls "$EVAL_ROOT"/deployment/helm/ztd-openbao/charts/openbao-*.tgz "$HOME"/.cache/ztd-install-zone/ztd-openbao-deps-*/chart/charts/openbao-*.tgz 2>/dev/null | head -1)
  [ -n "$tgz" ] || { echo "no built openbao dependency to upgrade with"; exit 77; }
  cp "$tgz" "$EVAL_TMP/chart/charts/"
}

# job_copy <kind-name-prefix> <new-name>: apply a copy of a rendered Job of ztd-openbao (the
# bootstrap or the verification hook) under a new name, without hook annotations, so it runs once
# now against the live server. The rendering is the installer's own (kind zone).
job_copy() {
  local prefix=$1 new=$2
  render "$KIND_ZONE" ztd-openbao
  [ $RC -eq 0 ] || { echo "render failed: $OUT"; exit 1; }
  python3 - "$EVAL_TMP/out/ztd-openbao.yaml" "$prefix" "$new" > "$EVAL_TMP/jobcopy.json" <<'PY'
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
jobs = [d for d in docs if d["kind"] == "Job" and d["metadata"]["name"].startswith(sys.argv[2])]
assert len(jobs) == 1, "expected one Job %s*, got %d" % (sys.argv[2], len(jobs))
j = jobs[0]
j["metadata"]["name"] = sys.argv[3]
ann = j["metadata"].get("annotations") or {}
j["metadata"]["annotations"] = {k: v for k, v in ann.items() if not k.startswith("helm.sh/")}
j["metadata"]["labels"] = {k: v for k, v in (j["metadata"].get("labels") or {}).items() if k != "app.kubernetes.io/managed-by"}
json.dump(j, sys.stdout)
PY
  [ -s "$EVAL_TMP/jobcopy.json" ] || { echo "no Job $prefix* in the rendering"; exit 1; }
  k apply -f "$EVAL_TMP/jobcopy.json" >/dev/null || { echo "could not apply the job copy"; exit 1; }
}

# wait_job <name> <complete|failed> <seconds>
wait_job() {
  local end=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    st=$(k -n "$MGMT" get job "$1" -o json 2>/dev/null | jq -r '[.status.conditions[]? | select(.status=="True") | .type] | join(",")')
    case ",$st," in *,Complete,*) [ "$2" = complete ] && return 0; return 1 ;; *,Failed,*) [ "$2" = failed ] && return 0; return 1 ;; esac
    sleep 3
  done
  return 2
}

job_log() { k -n "$MGMT" logs "job/$1" -c "${2:-bootstrap}" 2>&1; }

# wipe_store: delete the server's volume and pod so that it starts empty (not initialised, sealed).
wipe_store() {
  k -n "$MGMT" scale sts/ztd-openbao --replicas=0 >/dev/null
  k -n "$MGMT" wait --for=delete pod/ztd-openbao-0 --timeout=120s >/dev/null 2>&1
  k -n "$MGMT" delete pvc data-ztd-openbao-0 --wait=true --timeout=120s >/dev/null
  k -n "$MGMT" scale sts/ztd-openbao --replicas=1 >/dev/null
  local end=$(( $(date +%s) + 180 ))
  until [ "$(k -n "$MGMT" get pod ztd-openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] ; do
    [ "$(date +%s)" -lt "$end" ] || { echo "server pod did not start"; return 1; }; sleep 3
  done
  sleep 5
}

# restore_store: bring the live store back to initialised, unsealed and configured, whatever state
# the check left it in: no Secret, an empty volume, then the copy of the bootstrap Job.
restore_store() {
  k -n "$MGMT" delete secret ztd-openbao-bootstrap --ignore-not-found >/dev/null
  wipe_store || return 1
  job_copy ztd-openbao-bootstrap- "ztd-openbao-bootstrap-restore$RANDOM"
  local n; n=$(jq -r .metadata.name "$EVAL_TMP/jobcopy.json")
  wait_job "$n" complete 240 || { echo "restore bootstrap did not complete"; job_log "$n" | tail -5; return 1; }
  # the verification hook's token and fixture are the new ones; re-run the hook copy against it
  job_copy ztd-verify-openbao "ztd-verify-openbao-restore$RANDOM"
  n=$(jq -r .metadata.name "$EVAL_TMP/jobcopy.json")
  wait_job "$n" complete 120 || { echo "restore verification failed"; job_log "$n" verify | tail -5; return 1; }
}

# rm_copies: delete the Job copies the checks applied (the live release's own Jobs stay).
rm_copies() {
  k -n "$MGMT" get jobs -o name 2>/dev/null | grep -E 'bootstrap-(lost|restore)|verify-openbao-(sealed|restore)' | xargs -r kubectl --context "$KCTX" -n "$MGMT" delete --wait=false >/dev/null 2>&1
}
