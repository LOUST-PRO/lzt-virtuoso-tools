#!/usr/bin/env bash
# lzt-virtuoso-doc-ingest.sh — Ingest technology documentation into the
# canonical VPS Virtuoso graph as structured DocumentationPage records.
#
# This is the support script the showcase-app needs: rather than WebFetch
# at runtime, we pre-ingest the Next 16 / React 19 / R3F / drei / mermaid
# / tailwind 4 docs once and query them via SPARQL.
#
# Vocabulary (urn:lzt:vocab:docs#*):
#   Technology          — a tech stack entry (Next.js, React, etc.)
#   Version             — semver'd release of a Technology
#   DocumentationPage   — a single docs page with URL + title + content
#   APISignature        — exported function/class with parameters
#
# Pipeline per tech:
#   1. fetch a JSON manifest of URLs (already-curated, stored in this script)
#   2. for each URL: GET markdown, extract title + section headings
#   3. emit JSONL records: {s,p,o} per (page, technology, version, api)
#   4. hand off to lzt-virtuoso-ingest.sh --from-jsonl
#
# Usage:
#   lzt-virtuoso-doc-ingest.sh <tech> [<tech>...]
#   lzt-virtuoso-doc-ingest.sh --all
#
# Env:
#   LZT_VIRTUOSO_GRAPH  default: urn:lzt:vocab:docs:corpus:2026-08-05

set -euo pipefail

INGEST_BIN="${HOME}/.local/bin/lzt-virtuoso-ingest.sh"
GRAPH="${LZT_VIRTUOSO_GRAPH:-urn:lzt:vocab:docs:corpus:2026-08-05}"
TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# Curated manifest — single source of truth for what gets ingested.
# Format per tech: "version|base_url|page1|page2|..."
declare -A MANIFEST=(
  [nextjs]="16.3|https://nextjs.org/docs|app/api-reference/file-conventions/proxy|app/api-reference/components/link|app/guides/view-transitions|app/getting-started/proxy"
  [react]="19.2|https://react.dev/reference|react/ViewTransition|react/useViewTransitionState"
  [react-three-fiber]="8.17|https://r3f.docs.pmnd.rs|api/objects|api/hooks|api/Canvas"
  [drei]="9.114|https://github.com/pmndrs/drei|README|api/Canvas|api/Float"
  [mermaid]="11.4|https://mermaid.js.org/intro|config/theming|syntax/flowchart"
  [tailwind]="4.0|https://tailwindcss.com/docs|installation|content-configuration|theme"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--all | tech1 tech2 ...]
Available: ${!MANIFEST[*]}
EOF
  exit 64
}

[[ $# -ge 1 ]] || usage

TECHS=()
if [[ "$1" == "--all" ]]; then
  TECHS=("${!MANIFEST[@]}")
else
  TECHS=("$@")
fi

# JSONL records use these shapes:
#   URI subject/predicate/object    → "urn:..."
#   Literal with lang or datatype    → {"value": "...", "lang": "en"}
#                                       {"value": "...", "datatype": "xsd:string"}
#   Plain literal                    → "some text"
# Anything with the prefix "urn:" or "http" is emitted as a URI by the
# converter when wrapped as {"value": "..."}.
# For rdf:type on classes/properties we emit direct URIs (no quotes).

emit_technology_triples() {
  local tech="$1" version="$2" base="$3"
  local tech_iri="urn:lzt:vocab:docs:Technology:${tech}"
  local ver_iri="urn:lzt:vocab:docs:Version:${tech}:${version}"
  # rdf:type triples — URIs not literals
  echo "{\"s\":\"$tech_iri\",\"p\":\"http://www.w3.org/1999/02/22-rdf-syntax-ns#type\",\"o\":\"<urn:lzt:vocab:docs#Technology>\"}"
  echo "{\"s\":\"$tech_iri\",\"p\":\"http://www.w3.org/2000/01/rdf-schema#label\",\"o\":{\"value\":\"$tech\"}}"
  echo "{\"s\":\"$tech_iri\",\"p\":\"https://schema.org/url\",\"o\":{\"value\":\"$base\"}}"
  echo "{\"s\":\"$ver_iri\",\"p\":\"http://www.w3.org/1999/02/22-rdf-syntax-ns#type\",\"o\":\"<urn:lzt:vocab:docs#Version>\"}"
  echo "{\"s\":\"$ver_iri\",\"p\":\"http://www.w3.org/2000/01/rdf-schema#label\",\"o\":{\"value\":\"$version\"}}"
  echo "{\"s\":\"$ver_iri\",\"p\":\"urn:lzt:vocab:docs#versionOf\",\"o\":\"<${tech_iri}>\"}"
}

emit_page_triple() {
  local tech="$1" page_path="$2" base="$3"
  local tech_iri="urn:lzt:vocab:docs:Technology:${tech}"
  local safe_path
  safe_path=$(echo "$page_path" | tr '/' ':' | sed 's/[:.]/-/g')
  local page_iri="urn:lzt:vocab:docs:Page:${tech}:${safe_path}"
  local full_url="$base/$page_path"
  local title
  title=$(curl --silent --fail --max-time 15 "$full_url.md" 2>/dev/null \
    | head -1 \
    | sed 's/^#\+ *//' \
    | head -c 200 \
    || echo "untitled")
  echo "{\"s\":\"$page_iri\",\"p\":\"http://www.w3.org/1999/02/22-rdf-syntax-ns#type\",\"o\":\"<urn:lzt:vocab:docs#DocumentationPage>\"}"
  echo "{\"s\":\"$page_iri\",\"p\":\"http://www.w3.org/2000/01/rdf-schema#label\",\"o\":{\"value\":\"$title\"}}"
  echo "{\"s\":\"$page_iri\",\"p\":\"https://schema.org/url\",\"o\":{\"value\":\"$full_url\"}}"
  echo "{\"s\":\"$page_iri\",\"p\":\"urn:lzt:vocab:docs#documents\",\"o\":\"<${tech_iri}>\"}"
}

ingest_tech() {
  local tech="$1"
  IFS='|' read -r version base pages_csv <<< "${MANIFEST[$tech]}"
  local jsonl="$TMPDIR_RUN/${tech}.jsonl"

  echo "[doc-ingest] $tech @ $version → $pages_csv" >&2

  IFS='|' read -ra pages <<< "$pages_csv"
  {
    emit_technology_triples "$tech" "$version" "$base"
    for page in "${pages[@]}"; do
      emit_page_triple "$tech" "$page" "$base"
    done
  } > "$jsonl"

  echo "[doc-ingest] $tech: $(wc -l < "$jsonl") triples ready" >&2
  "$INGEST_BIN" "$jsonl" "$GRAPH" --from-jsonl
}

for tech in "${TECHS[@]}"; do
  if [[ -z "${MANIFEST[$tech]:-}" ]]; then
    echo "[doc-ingest] unknown tech: $tech — skip" >&2
    continue
  fi
  ingest_tech "$tech"
done

echo "[doc-ingest] done. graph: <$GRAPH>"
