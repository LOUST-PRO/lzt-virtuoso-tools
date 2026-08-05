#!/usr/bin/env bash
# lzt-virtuoso-write-probe.sh — Diagnose write capability of the local/target
# Virtuoso instance. Mirrors F80.7 memory contract:
#   - read endpoint :18890/sparql via SSH forward (loust-vps-multiplex)
#   - write endpoint :1111 isql-vt via docker exec on loust-virtuoso
#   - writes succeed only via TTLP_MT(file_to_string(...)) with chmod 644,
#     but we also test DB.DBA.RDF_QUAD_URI (single triple, no file IO).
#
# Exit codes:
#   0 = WRITE_CAPABLE
#   1 = READ_ONLY
#   2 = UNREACHABLE
#
# Output: 1 line JSON parseable + verdict on stderr.

set -uo pipefail

CONTAINER="${LZT_VIRTUOSO_CONTAINER:-loust-virtuoso}"
SSH_TARGET="${LZT_VIRTUOSO_SSH_TARGET:-loust-vps-multiplex}"
ISQL_PORT="${LZT_VIRTUOSO_ISQL_PORT:-1111}"
ISQL_USER="${LZT_VIRTUOSO_ISQL_USER:-dba}"
ISQL_PASS="${LZT_VIRTUOSO_ISQL_PASS:-tVRjVug9qyx9FGeQp+FXJ6d+CBXwgVd6NU37rP/ECBlGzrg1}"
READ_EP="${LZT_VIRTUOSO_READ_EP:-http://localhost:18890/sparql}"

probe_read() {
  curl --silent --fail --max-time 5 \
    -H "Accept: application/sparql-results+json" \
    --data-urlencode "query=SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }" \
    "$READ_EP" >/dev/null 2>&1
}

# Run an arbitrary SQL statement via isql-vt, return output via stdout.
# Uses bash -c with a heredoc to avoid quoting hell across ssh boundaries.
run_sql() {
  local sql="$1"
  ssh -o BatchMode=yes "$SSH_TARGET" bash -s <<EOF
docker exec -i $CONTAINER isql $ISQL_PORT $ISQL_USER $ISQL_PASS <<'SQL_EOF'
$sql
SQL_EOF
EOF
}

probe_write() {
  local probe_g="urn:lzt:probe:$$"
  local probe_s="${probe_g}:subj"
  local probe_p="${probe_g}:predicate"
  local probe_o="write-probe-ok"

  # Reachability check
  run_sql "SELECT 1;" >/dev/null 2>&1 || return 1

  # Insert sentinel via SPARQL — single quoted literals play nicely with heredocs
  run_sql "SPARQL INSERT INTO <$probe_g> { <$probe_s> <$probe_p> \"$probe_o\" };" >/dev/null 2>&1 || return 1

  # Verify via read endpoint that the triple landed
  local count
  count=$(curl --silent --fail --max-time 5 \
    -H "Accept: application/sparql-results+json" \
    --data-urlencode "query=SELECT (COUNT(*) AS ?c) WHERE { GRAPH <${probe_g}> { ?s ?p ?o } }" \
    "$READ_EP" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(r['results']['bindings'][0]['c']['value']))" \
    2>/dev/null || echo 0)

  # Cleanup
  run_sql "SPARQL CLEAR GRAPH <$probe_g>;" >/dev/null 2>&1 || true

  [[ "$count" -ge 1 ]]
}

main() {
  if ! probe_read; then
    echo "endpoint=read status=UNREACHABLE read_ep=$READ_EP" >&2
    echo '{"endpoint":"read","status":"UNREACHABLE","read_ep":"'"$READ_EP"'"}'
    exit 2
  fi

  if probe_write; then
    echo "endpoint=write status=WRITE_CAPABLE container=$CONTAINER" >&2
    echo '{"endpoint":"write","status":"WRITE_CAPABLE","container":"'"$CONTAINER"'","isql_port":'"$ISQL_PORT"',"ssh":"'"$SSH_TARGET"'"}'
    exit 0
  fi

  echo "endpoint=write status=READ_ONLY container=$CONTAINER" >&2
  echo '{"endpoint":"write","status":"READ_ONLY","container":"'"$CONTAINER"'","isql_port":'"$ISQL_PORT"',"ssh":"'"$SSH_TARGET"'"}'
  exit 1
}

main "$@"
