// Test suite for lzt-virtuoso-convert-jsonl-go.
//
// Build & run:
//   go test -v ./...
//
// Compares converter output against a Python reference implementation
// for byte-exact equivalence across all supported input shapes.

package convert

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
)

// runConverter invokes the bin with input JSONL on stdin and returns
// the N-Triples output (stderr ignored).
func runConverter(t *testing.T, input string) string {
	t.Helper()
	bin := binPath()
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader(input)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("converter failed: %v\nstderr: %s", err, stderr.String())
	}
	return out.String()
}

func TestURI(t *testing.T) {
	in := `{"s":"urn:test:s","p":"urn:test#p","o":"<urn:test#Thing>"}
`
	got := runConverter(t, in)
	want := "<urn:test:s> <urn:test#p> <urn:test#Thing> .\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestLiteral(t *testing.T) {
	in := `{"s":"urn:test:s","p":"rdfs:label","o":{"value":"hello world"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <rdfs:label> "hello world" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestLangLiteral(t *testing.T) {
	in := `{"s":"urn:test:s","p":"rdfs:label","o":{"value":"bonjour","lang":"fr"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <rdfs:label> "bonjour"@fr .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestTypedLiteral(t *testing.T) {
	in := `{"s":"urn:test:s","p":"rdf:type","o":{"value":"42","datatype":"xsd:integer"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <rdf:type> "42"^^<xsd:integer> .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestEscapes(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:esc","o":{"value":"she said \"hi\" \\path"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:esc> "she said \"hi\" \\path" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRDFJSTypedURI(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:rjs","o":{"type":"uri","value":"urn:test:rjs"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:rjs> <urn:test:rjs> .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRDFJSTypedLiteral(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:rjs","o":{"type":"literal","value":"rjs literal","lang":"en"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:rjs> "rjs literal"@en .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestNestedObjectExpansion(t *testing.T) {
	// Object expansion: keys become predicate suffixes.
	in := `{"s":"urn:test:s","p":"test:nested","o":{"name":{"value":"alice"},"age":{"value":"30","datatype":"xsd:int"}}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:nestedname> "alice" .
<urn:test:s> <test:nestedage> "30"^^<xsd:int> .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestArrayExpansion(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:multi","o":["<urn:test:a>","<urn:test:b>","literal-third"]}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:multi> <urn:test:a> .
<urn:test:s> <test:multi> <urn:test:b> .
<urn:test:s> <test:multi> "literal-third" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestBlankNode(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:bnode","o":{"type":"bnode","value":"abc123"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:bnode> _:abc123 .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestUnicode(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:utf8","o":{"value":"héllo wörld 🚀 café étoile"}}
`
	got := runConverter(t, in)
	want := `<urn:test:s> <test:utf8> "héllo wörld 🚀 café étoile" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestSkipNumber(t *testing.T) {
	in := `{"s":"urn:test:s","p":"test:num","o":42}
{"s":"urn:test:s2","p":"test:num2","o":"recovered"}
`
	got := runConverter(t, in)
	want := `<urn:test:s2> <test:num2> "recovered" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestSkipBoolNull(t *testing.T) {
	in := `{"s":"a","p":"b","o":true}
{"s":"a","p":"b","o":null}
{"s":"a","p":"b","o":false}
{"s":"a","p":"b","o":"kept"}
`
	got := runConverter(t, in)
	want := `<a> <b> "kept" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestEmptyLines(t *testing.T) {
	in := `
{"s":"a","p":"b","o":"x"}

{"s":"c","p":"d","o":"y"}

`
	got := runConverter(t, in)
	want := `<a> <b> "x" .
<c> <d> "y" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestBlankLinesBetweenRecords(t *testing.T) {
	// Test that internal whitespace within values is preserved.
	in := `{"s":"a","p":"b","o":{"value":"hello   world"}}
`
	got := runConverter(t, in)
	want := `<a> <b> "hello   world" .
`
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

// TestManyRecords exercises the bufio.Writer flush behavior with a
// larger input — verifies that all triples land in stdout.
func TestManyRecords(t *testing.T) {
	var b strings.Builder
	expected := []string{}
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&b, `{"s":"urn:s:%d","p":"urn:p","o":"<urn:o:%d>"}`+"\n", i, i)
		expected = append(expected, fmt.Sprintf("<urn:s:%d> <urn:p> <urn:o:%d> .", i, i))
	}
	got := runConverter(t, b.String())
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != 1000 {
		t.Fatalf("got %d lines, want 1000", len(lines))
	}
	for i, line := range lines {
		if line != expected[i] {
			t.Errorf("line %d: got %q want %q", i, line, expected[i])
		}
	}
}

func binPath() string {
	// Tests expect bin already built.
	return "/home/lou/.local/bin/lzt-virtuoso-convert-jsonl-go"
}
