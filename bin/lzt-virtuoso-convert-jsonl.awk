#!/usr/bin/awk -f
# lzt-virtuoso-convert-jsonl.awk — Convert JSONL triples to N-Triples.
#
# Input: JSONL, one record per line. Each record:
#   {"s": "<URI>", "p": "<URI>", "o": <string|object>}
#   o as object: {"value": "...", "lang": "..."} or {"value": "...", "datatype": "<URI>"}
#   o as string: direct URI (<...>) or plain literal
#
# Output: N-Triples, one triple per line. URIs get < > brackets;
#         literals get " " quotes. JSON string escapes (\\, \") are
#         converted to N-Triples escapes.
#
# Usage:
#   awk -f lzt-virtuoso-convert-jsonl.awk input.jsonl > output.nt
#
# Note: uses sprintf("%c", 34) for double-quote to stay portable across
#       awk locales (gawk, mawk, BWK).

function dq() { return sprintf("%c", 34) }

# Extract a JSON string starting at position `start` in `haystack`
# (1-indexed). Returns the unescaped string content (without quotes).
# Sets `endpos` to the position after the closing quote.
function extract_json_string(haystack, start,    endpos,    i, c, n, out) {
  n = length(haystack)
  if (substr(haystack, start, 1) != dq()) return ""
  i = start + 1
  out = ""
  while (i <= n) {
    c = substr(haystack, i, 1)
    if (c == "\\") {
      if (i + 1 > n) break
      i++
      c = substr(haystack, i, 1)
      if (c == "n")      out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c == dq()) out = out dq()
      else if (c == "\\") out = out "\\"
      else if (c == "/") out = out "/"
      else               out = out c
    } else if (c == dq()) {
      endpos = i + 1
      return out
    } else {
      out = out c
    }
    i++
  }
  endpos = n + 1
  return out
}

# Find the start position (1-indexed) of a JSON key of the form "key"
# where the character before the opening quote is `{` or `,`. Returns 0
# if not found. The "key" argument should NOT include the quotes.
function find_key(haystack, key,    n, q, k) {
  n = length(haystack)
  q = 1
  while (q <= n) {
    q = index(substr(haystack, q), dq() key dq())
    if (q == 0) return 0
    # q is the position of the opening quote of the matched key
    if (q == 1) return 1
    k = substr(haystack, q - 1, 1)
    if (k == "{" || k == ",") return q
    q++
  }
  return 0
}

# Position of the colon after a key returned by find_key.
# Walks from the quote through the optional whitespace to the colon.
function find_colon_after(haystack, key_pos,    i, n, c) {
  n = length(haystack)
  # key_pos points to the opening quote of "key"
  # Skip the quotes + key + closing quote
  i = key_pos + 1
  while (i <= n && substr(haystack, i, 1) != dq()) i++  # find closing quote
  if (i > n) return 0
  i++  # past closing quote
  while (i <= n) {
    c = substr(haystack, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else if (c == ":") return i
    else return 0
  }
  return 0
}

# Skip whitespace at position `pos`, return new position.
function skip_ws(s, pos,    n, c) {
  n = length(s)
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
    else break
  }
  return pos
}

# Get a string-typed value for a top-level key. Returns 1 on success.
function get_string_value(s, key,    kpos, colon, start, endpos) {
  kpos = find_key(s, key)
  if (kpos == 0) return 0
  colon = find_colon_after(s, kpos)
  if (colon == 0) return 0
  start = skip_ws(s, colon + 1)
  if (substr(s, start, 1) != dq()) return 0
  value = extract_json_string(s, start, endpos)
  return 1
}

# Look at what follows the colon after a key.
function peek_value_kind(s, key,    kpos, colon, start, c) {
  kpos = find_key(s, key)
  if (kpos == 0) return "missing"
  colon = find_colon_after(s, kpos)
  if (colon == 0) return "missing"
  start = skip_ws(s, colon + 1)
  c = substr(s, start, 1)
  if (c == dq()) return "string"
  if (c == "{") return "object"
  return "other"
}

# Get a string-typed sub-key from an object value (value is { ... }).
# Walks into the braces and finds the sub-key relative to the inner braces.
function get_substring_value(s, key, subkey,    kpos, colon, brace, end_brace, start, inner, sub_q, endpos) {
  kpos = find_key(s, key)
  if (kpos == 0) return 0
  colon = find_colon_after(s, kpos)
  if (colon == 0) return 0
  brace = skip_ws(s, colon + 1)
  if (substr(s, brace, 1) != "{") return 0
  # Find matching closing brace (assume no nested objects in our spec)
  end_brace = index(substr(s, brace + 1), "}")
  if (end_brace == 0) return 0
  end_brace = brace + end_brace
  inner = substr(s, brace, end_brace - brace + 1)
  sub_q = find_key(inner, subkey)
  if (sub_q == 0) return 0
  start = skip_ws(inner, sub_q + 2 + length(subkey) + 1)  # past "subkey"
  # Actually find the colon after the subkey in `inner`
  start = find_colon_after(inner, sub_q)
  if (start == 0) return 0
  start = skip_ws(inner, start + 1)
  if (substr(inner, start, 1) != dq()) return 0
  value = extract_json_string(inner, start, endpos)
  return 1
}

function emit_literal(val) {
  # After JSON unescape, N-Triples requires additional escaping of literal
  # backslashes and double-quotes.
  return dq() ntriples_escape(val) dq()
}

function ntriples_escape(s,    t, i, c, n) {
  t = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\")      t = t "\\\\"
    else if (c == dq()) t = t "\\" dq()
    else                t = t c
  }
  return t
}

function emit_uri(val) {
  if (substr(val, 1, 1) == "<" && substr(val, length(val), 1) == ">") return val
  return "<" val ">"
}

{
  line = $0
  gsub(/[\r\n]/, "", line)

  if (!get_string_value(line, "s")) next
  s_val = value
  if (!get_string_value(line, "p")) next
  p_val = value

  kind = peek_value_kind(line, "o")
  if (kind == "missing") next

  o_str = ""
  if (kind == "string") {
    if (!get_string_value(line, "o")) next
    val = value
    if (val ~ /^(urn:|http:|https:|file:)/) {
      o_str = emit_uri(val)
    } else if (substr(val, 1, 1) == "<" && substr(val, length(val), 1) == ">") {
      o_str = val
    } else {
      o_str = emit_literal(val)
    }
  } else if (kind == "object") {
    if (!get_substring_value(line, "o", "value")) next
    v_val = value
    lang = ""
    if (get_substring_value(line, "o", "lang")) lang = value
    dt = ""
    if (get_substring_value(line, "o", "datatype")) dt = value

    lit = emit_literal(v_val)
    if (lang != "") {
      o_str = lit "@" lang
    } else if (dt != "") {
      o_str = lit "^^<" dt ">"
    } else {
      o_str = lit
    }
  } else {
    next
  }

  print "<" s_val "> <" p_val "> " o_str " ."
}
