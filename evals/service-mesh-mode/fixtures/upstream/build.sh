#!/usr/bin/env bash
# build.sh <dest> — lay an offline copy of every upstream source the check-upstream-state script
# reads, in the state where every premise of the decision holds. Checks then alter one file to
# exercise a failure path and point the script at it with the documented environment variables:
#   GITHUB_API=file://<dest>/api  ISTIO_MIGRATE_URL=file://<dest>/migrate.html  SPIRE_DOC_BASE=file://<dest>/spire
# GitHub API field names are GitHub's public REST contract (tag_name, published_at, state, merged_at …).
set -eu
dest=$1; here=$(cd "$(dirname "$0")" && pwd)
spire_tag=v1.15.3
mkdir -p "$dest/api/repos/istio/istio/releases" "$dest/api/repos/istio/istio/issues" \
         "$dest/api/repos/istio/ztunnel/pulls" "$dest/api/repos/spiffe/spire/releases" \
         "$dest/spire/$spire_tag/doc"
cat > "$dest/api/repos/istio/istio/releases/latest" <<JSON
{"tag_name":"1.31.1","name":"Istio 1.31.1","published_at":"2026-09-21T00:00:00Z","html_url":"https://github.com/istio/istio/releases/tag/1.31.1"}
JSON
cat > "$dest/api/repos/istio/istio/issues/42339" <<JSON
{"number":42339,"title":"SPIRE integration with Ambient","state":"open","state_reason":null,"created_at":"2022-12-05T00:00:00Z","updated_at":"2026-09-20T00:00:00Z","closed_at":null,"labels":[{"name":"area/ambient"}],"html_url":"https://github.com/istio/istio/issues/42339"}
JSON
pr() { # pr <number> <title> <state> <merged_at|null> <draft> <labels-json>
cat > "$dest/api/repos/istio/ztunnel/pulls/$1" <<JSON
{"number":$1,"title":"$2","state":"$3","merged_at":$4,"merged":$( [ "$4" = null ] && echo false || echo true ),"draft":$5,"labels":$6,"updated_at":"2026-09-22T00:00:00Z","html_url":"https://github.com/istio/ztunnel/pull/$1"}
JSON
}
pr 1676 "Delegated Identity API support" open null false '[]'
pr 1936 "SPIFFE Broker API client" open null true '[{"name":"do-not-merge/hold"}]'
pr 2067 "cert cache: key by workload" closed '"2026-09-22T10:00:00Z"' false '[]'
cat > "$dest/api/repos/spiffe/spire/releases/latest" <<JSON
{"tag_name":"$spire_tag","name":"$spire_tag","published_at":"2026-09-10T00:00:00Z","html_url":"https://github.com/spiffe/spire/releases/tag/$spire_tag"}
JSON
cp "$here/spire_agent-$spire_tag.md" "$dest/spire/$spire_tag/doc/spire_agent.md"
cp "$here/migrate.html" "$dest/migrate.html"
echo "$dest"
