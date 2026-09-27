# Sourced by the diagram-render checks. Runs the render command recorded in the first line of
# the diagram source inside a scratch copy under $EVAL_TMP and compares the result with the
# committed SVG.
# Mermaid output geometry depends on the fonts installed on the rendering machine, so the
# comparison normalises away every number and all whitespace: structure, ids, classes and text
# must be identical; coordinates and sizes may differ.
set -u
MMD_REL=docs/diagrams/03-trust-boundaries.mmd
SVG_REL=docs/diagrams/03-trust-boundaries.svg
first=$(head -n1 "$EVAL_ROOT/$MMD_REL")
echo "first line of source: $first"
case "$first" in
  %%*) ;;
  *) echo "FAIL: the source does not begin with a %% comment"; exit 1 ;;
esac
cmd=$(printf '%s' "$first" | sed -E 's/^%%[[:space:]]*([Rr]ender[^:]*:)?[[:space:]]*//')
echo "render command: $cmd"
case "$cmd" in
  *mmdc*) ;;
  *) echo "FAIL: the leading comment gives no mermaid-cli (mmdc) command"; exit 1 ;;
esac
printf '%s' "$cmd" | grep -q -- "-i $MMD_REL" || { echo "FAIL: command does not read $MMD_REL"; exit 1; }
printf '%s' "$cmd" | grep -q -- "-o $SVG_REL" || { echo "FAIL: command does not write $SVG_REL"; exit 1; }

render() {  # $1 = scratch repo dir
  ( cd "$1" && export npm_config_cache="${EVAL_NPM_CACHE:-$EVAL_TMP/npm}" npm_config_update_notifier=false
    if ! bash -c "$cmd" >render.log 2>&1; then
      if grep -q 'No usable sandbox' render.log; then
        # Environment accommodation only: this host forbids Chromium's sandbox.
        echo '{"args":["--no-sandbox"]}' > "$EVAL_TMP/pp.json"
        echo "note: host has no usable Chromium sandbox; re-running with -p (puppeteer --no-sandbox)"
        bash -c "$cmd -p $EVAL_TMP/pp.json" >render.log 2>&1 || { tail -5 render.log; return 77; }
      else
        tail -5 render.log; return 77
      fi
    fi )
}
normsvg() { sed -E 's/></>\n</g' "$1" | sed -E 's/data-points="[^"]*"//g; s/-?[0-9]+(\.[0-9]+)?(e-?[0-9]+)?//g; s/[[:space:]]+/ /g'; }
command -v npx >/dev/null || { echo "UNVERIFIABLE: npx not available to run the render command"; exit 77; }
