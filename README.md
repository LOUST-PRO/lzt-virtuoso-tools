# lzt-virtuoso-tools

CLI tooling for ingesting structured triples into a Virtuoso OpenSource
instance via `TTLP_MT`. Built for the LZT (Local Zero-friction Trust)
workflow where documentation, benchmarks, and runtime facts are SPARQL-
queryable rather than runtime-fetched.

## What you get

- 5 bash scripts for end-to-end ingest (probe → vocab → docs → verify)
- 1 Go binary (`lzt-virtuoso-convert-jsonl-go`) — fast JSONL→N-Triples
  with full feature support: nested objects, arrays, RDF/JS typed nodes,
  unicode, blank nodes
- 1 awk fallback (`lzt-virtuoso-convert-jsonl.awk`) — for systems
  without Go
- 1 starter vocabulary (`docs-vocabulary.ttl`) — 4 classes + 4
  properties for technology documentation

## Why this exists

Per the LZT `pre-fetch-graph-first` rule, runtime `WebFetch` is banned
when content can be SPARQL'd. This toolkit pre-ingests structured
triples once and lets the rest of the LZT stack query via SPARQL.

## Quickstart

```bash
# 1. Set credentials (one-time, chmod 600)
cat > env.local <<EOF
export LZT_VIRTUOSO_SSH_TARGET=loust-vps-multiplex
export LZT_VIRTUOSO_CONTAINER=loust-virtuoso
export LZT_VIRTUOSO_ISQL_USER=dba
export LZT_VIRTUOSO_ISQL_PASS='your-rotated-password'
export LZT_VIRTUOSO_READ_EP=http://localhost:18890/sparql
EOF
chmod 600 env.local
source env.local

# 2. Verify write capability
make probe
# → endpoint=write status=WRITE_CAPABLE container=loust-virtuoso

# 3. Ingest vocabulary (idempotent)
make ingest VOCAB=docs-vocabulary.ttl

# 4. Ingest Next.js docs
make doc-ingest TECH=nextjs

# 5. Query via SPARQL
curl -sG http://localhost:18890/sparql \
  --data-urlencode 'query=SELECT ?tech WHERE { ?tech a <urn:lzt:vocab:docs#Technology> }' \
  -H 'Accept: application/sparql-results+json' | jq .
```

## Endpoints

| Layer | Endpoint | Notes |
|---|---|---|
| Read | `http://localhost:18890/sparql` | SSH forward to VPS `:8890` |
| Write | SSH → `docker exec loust-virtuoso isql 1111` | TTLP_MT with chmod 644 |

`loust-virtuoso` is the canonical VPS container (Virtuoso
OpenSource 7.2.17-r24). `hexcortex-virtuoso` on the laptop is a
separate Tier 1 authoring DB — **not** what this tool writes to.

## Pipeline

```
JSONL triples
   │
   ▼
lzt-virtuoso-convert-jsonl-go    (or awk fallback)
   │ N-Triples
   ▼
lzt-virtuoso-ingest.sh
   │ probe → jsonl→nt → scp → docker cp → chmod 644
   ▼
TTLP_MT(file_to_string(...), '', <graph>, 255)
   │
   ▼
SPARQL count verification on :18890
```

## Building from source

Requires Go 1.20+ (uses `go -C` flag).

```bash
make build    # compile Go bin + check bash syntax
make test     # run 17 unit tests
make install  # copy scripts to ~/.local/bin/
```

## Repo layout

```
bin/                              scripts + compiled Go bin
  lzt-virtuoso-write-probe.sh     diagnose read/write capability
  lzt-virtuoso-ingest.sh          bulk ingest N-Triples or JSONL
  lzt-virtuoso-doc-ingest.sh      ingest tech docs from curated manifest
  lzt-virtuoso-convert-jsonl.awk  portable fallback (URI + literal + lang)
  lzt-virtuoso-convert-jsonl-go   full-feature JSONL→N-Triples (3 MB)
src/                              Go module
  main.go                         CLI wrapper
  internal/convert/
    main.go                       library (DoMain, EmitObject, EmitNode)
    main_test.go                  16 unit tests
docs-vocabulary.ttl               starter vocabulary (Technology, Version,
                                  DocumentationPage, APISignature)
Makefile                          build / test / install / probe / ingest
LICENSE                           MIT
```

## Security notes

- `env.local` is gitignored and chmod 600.
- `TTLP_MT` requires `chmod 644` after `docker cp` (default is 600).
- Bash heredocs use `<<'SQL_EOF'` to avoid quoting hell across SSH.
- The Go binary is statically linked (zero runtime deps, ~3 MB).

## License

MIT — see [LICENSE](LICENSE).
