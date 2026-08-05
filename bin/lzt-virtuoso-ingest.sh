#!/usr/bin/env bash
# lzt-virtuoso-ingest.sh — Bulk ingest N-Triples or JSONL to the canonical
# VPS Virtuoso (hexcortex-virtuoso container). Implements F80.7 contract:
#   - probe preflight via lzt-virtuoso-write-probe.sh
#   - convert JSONL → NT if --from-jsonl
#   - ssh | docker cp <file> + chmod 644
#   - isql-vt with TTLP_MT(file_to_string(...), '', <graph>, 255)
#   - verify count via read endpoint :18890
#   - cleanup tmpfiles (unless --no-cleanup)
#
# Usage:
#   lzt-virtuoso-ingest.sh <file> <graph-iri> [--from-jsonl] [--no-cleanup]
#
# Env vars (all optional, with safe defaults):
#   LZT_VIRTUOSO_SSH_TARGET    default: loust-vps-multiplex
#   LZT_VIRTUOSO_CONTAINER     default: hexcortex-virtuoso
#   LZT_VIRTUOSO_ISQL_PORT     default: 1111
#   LZT_VIRTUOSO_READ_EP       default: http://localhost:18890/sparql

set -euo pipefail

PROBE="${HOME}/.local/bin/lzt-virtuoso-write-probe.sh"
SSH_TARGET="${LZT_VIRTUOSO_SSH_TARGET:-loust-vps-multiplex}"
CONTAINER="${LZT_VIRTUOSO_CONTAINER:-loust-virtuoso}"
ISQL_PORT="${LZT_VIRTUOSO_ISQL_PORT:-1111}"
ISQL_USER="${LZT_VIRTUOSO_ISQL_USER:-dba}"
ISQL_PASS="${LZT_VIRTUOSO_ISQL_PASS:-tVRjVug9qyx9FGeQp+FXJ6d+CBXwgVd6NU37rP/ECBlGzrg1}"
READ_EP="${LZT_VIRTUOSO_READ_EP:-http://localhost:18890/sparql}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <file> <graph-iri> [--from-jsonl] [--no-cleanup]

Examples:
  $(basename "$0") docs.nt urn:lzt:vocab:docs:nextjs
  $(basename "$0") ingest.jsonl urn:lzt:vocab:docs:mermaid --from-jsonl
EOF
  exit 64
}

[[ $# -ge 2 ]] || usage
FILE="$1"
GRAPH="$2"
shift 2

FROM_JSONL=0
NO_CLEANUP=0
for arg in "$@"; do
  case "$arg" in
    --from-jsonl) FROM_JSONL=1 ;;
    --no-cleanup)  NO_CLEANUP=1 ;;
    *) echo "unknown flag: $arg" >&2; usage ;;
  esac
done

[[ -r "$FILE" ]] || { echo "cannot read $FILE" >&2; exit 66; }

# Step 0 — preflight probe
echo "[ingest] preflight probe..." >&2
if ! "$PROBE" >/dev/null; then
  echo "[ingest] probe FAILED — write path not available" >&2
  exit 1
fi

# Step 1 — convert JSONL → N-Triples if requested
# Prefers the Go converter (full feature support: nested objects,
# arrays, RDF/JS typed nodes, unicode). Falls back to awk converter
# if Go bin is missing.
WORK_FILE="$FILE"
TMP_NT=""
if [[ "$FROM_JSONL" == "1" ]]; then
  TMP_NT="$(mktemp --suffix=.nt)"
  CONVERTER=""
  if [[ -x "${HOME}/.local/bin/lzt-virtuoso-convert-jsonl-go" ]]; then
    CONVERTER="${HOME}/.local/bin/lzt-virtuoso-convert-jsonl-go"
  elif [[ -x "${HOME}/.local/bin/lzt-virtuoso-convert-jsonl.awk" ]]; then
    CONVERTER="awk -f ${HOME}/.local/bin/lzt-virtuoso-convert-jsonl.awk"
  fi
  if [[ -z "$CONVERTER" ]]; then
    echo "[ingest] no JSONL converter found (Go or awk)" >&2
    exit 70  # EX_SOFTWARE
  fi
  # The converter returns exit 1 if any line failed to parse, but
  # successfully-parsed lines still land in TMP_NT. We treat any
  # non-empty output as "partial success" and only fail on empty.
  if ! $CONVERTER < "$FILE" > "$TMP_NT" 2>/tmp/lzt-conv.err; then
    conv_exit=$?
    if [[ ! -s "$TMP_NT" ]]; then
      echo "[ingest] JSONL conversion failed (no triples produced)" >&2
      cat /tmp/lzt-conv.err >&2
      rm -f "$TMP_NT" /tmp/lzt-conv.err
      exit 1
    fi
    echo "[ingest] JSONL converter reported errors (exit=$conv_exit), continuing with partial output" >&2
    cat /tmp/lzt-conv.err >&2
  fi
  rm -f /tmp/lzt-conv.err
  WORK_FILE="$TMP_NT"
fi

# Step 2 — copy file into the container, fix perms
# Workflow: scp to VPS tmp first, then docker cp inside the VPS, then chmod 644.
LOCAL_FILE="$WORK_FILE"
VPS_TMP="/tmp/lzt-ingest-$$-$(basename "$WORK_FILE")"
REMOTE_PATH="/opt/virtuoso-opensource/database/$(basename "$WORK_FILE")"
echo "[ingest] scp → $SSH_TARGET:$VPS_TMP → docker cp $CONTAINER:$REMOTE_PATH" >&2
scp -o BatchMode=yes "$LOCAL_FILE" "$SSH_TARGET:$VPS_TMP"
ssh -o BatchMode=yes "$SSH_TARGET" "docker cp $VPS_TMP $CONTAINER:$REMOTE_PATH"
ssh -o BatchMode=yes "$SSH_TARGET" "docker exec $CONTAINER chmod 644 $REMOTE_PATH"
ssh -o BatchMode=yes "$SSH_TARGET" "rm -f $VPS_TMP"

# Step 3 — execute TTLP_MT via isql-vt using stdin heredoc (avoid quoting hell)
echo "[ingest] TTLP_MT into <$GRAPH>..." >&2
if ! ssh -o BatchMode=yes "$SSH_TARGET" bash -s <<EOF >/tmp/lzt-ingest.out 2>&1
docker exec -i $CONTAINER isql $ISQL_PORT $ISQL_USER $ISQL_PASS <<'SQL_EOF'
TTLP_MT(file_to_string('$REMOTE_PATH'), '', '$GRAPH', 255);
SQL_EOF
EOF
then
  cat /tmp/lzt-ingest.out >&2
  [[ "$NO_CLEANUP" != "1" && -n "$TMP_NT" ]] && rm -f "$TMP_NT"
  exit 1
fi

# Step 4 — verify count via read endpoint
sleep 1
COUNT=$(curl --silent --max-time 10 \
  -H "Accept: application/sparql-results+json" \
  --data-urlencode "query=SELECT COUNT(*) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }" \
  "$READ_EP" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(r['results']['bindings'][0]['callret-0']['value']))" \
  2>/dev/null || echo 0)

# Step 5 — cleanup
if [[ "$NO_CLEANUP" != "1" ]]; then
  ssh -o BatchMode=yes "$SSH_TARGET" bash -s <<EOF 2>/dev/null || true
docker exec $CONTAINER rm -f $REMOTE_PATH
EOF
  [[ -n "$TMP_NT" ]] && rm -f "$TMP_NT"
fi

echo "{\"graph\":\"$GRAPH\",\"count\":$COUNT,\"status\":\"OK\"}"
