// Package convert exposes the JSONL → N-Triples conversion as a
// library so it can be tested in-process without spawning a bin.
//
// The CLI bin at the repo root is a thin wrapper that calls DoMain().
package convert

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// Triple is the on-the-wire JSON record shape.
type Triple struct {
	S string          `json:"s"`
	P string          `json:"p"`
	O json.RawMessage `json:"o"`
}

// TypedNode is the RDF/JS-style explicit type form.
type TypedNode struct {
	Type     string `json:"type"`
	Value    string `json:"value"`
	Lang     string `json:"lang,omitempty"`
	Datatype string `json:"datatype,omitempty"`
}

// Node is the canonical typed node after parsing.
type Node struct {
	Kind     string // "uri" | "literal" | "bnode"
	Value    string
	Lang     string
	Datatype string
}

// DoMain reads JSONL from stdin and writes N-Triples to stdout.
// Returns the process exit code (0 = success, 1 = bad input, 2 = IO).
func DoMain() int {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)

	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()

	exitCode := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var t Triple
		if err := json.Unmarshal([]byte(line), &t); err != nil {
			fmt.Fprintf(os.Stderr, "skip bad line: %v\n", err)
			exitCode = 1
			continue
		}
		if t.S == "" || t.P == "" {
			fmt.Fprintf(os.Stderr, "skip line missing s or p\n")
			exitCode = 1
			continue
		}
		if err := EmitObject(w, t.S, t.P, t.O); err != nil {
			fmt.Fprintf(os.Stderr, "emit error on %s/%s: %v\n", t.S, t.P, err)
			exitCode = 1
		}
	}
	if err := scanner.Err(); err != nil && err != io.EOF {
		fmt.Fprintf(os.Stderr, "scanner error: %v\n", err)
		return 2
	}
	return exitCode
}

// EmitObject converts a raw `o` value into one or more N-Triples lines.
func EmitObject(w *bufio.Writer, s, p string, raw json.RawMessage) error {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" {
		return nil
	}

	switch trimmed[0] {
	case '"':
		var str string
		if err := json.Unmarshal(raw, &str); err != nil {
			return err
		}
		return EmitNode(w, s, p, Node{Kind: detectURIKind(str), Value: str})

	case '{':
		var typed TypedNode
		if err := json.Unmarshal(raw, &typed); err == nil && typed.Type != "" {
			return emitTypedNode(w, s, p, typed)
		}
		var vw struct {
			Value    string `json:"value"`
			Lang     string `json:"lang"`
			Datatype string `json:"datatype"`
		}
		if err := json.Unmarshal(raw, &vw); err == nil && vw.Value != "" {
			kind := "literal"
			if vw.Lang == "" && vw.Datatype == "" {
				kind = detectURIKind(vw.Value)
			}
			return EmitNode(w, s, p, Node{
				Kind:     kind,
				Value:    vw.Value,
				Lang:     vw.Lang,
				Datatype: vw.Datatype,
			})
		}
		var generic map[string]json.RawMessage
		if err := json.Unmarshal(raw, &generic); err != nil {
			return err
		}
		for k, v := range generic {
			subP := p + k
			if err := EmitObject(w, s, subP, v); err != nil {
				return err
			}
		}
		return nil

	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil {
			return err
		}
		for _, elem := range arr {
			if err := EmitObject(w, s, p, elem); err != nil {
				return err
			}
		}
		return nil

	case 't', 'f':
		return nil
	case 'n':
		return nil
	}

	if (trimmed[0] >= '0' && trimmed[0] <= '9') || trimmed[0] == '-' {
		return nil
	}

	return fmt.Errorf("unsupported o value: %s", trimmed)
}

func emitTypedNode(w *bufio.Writer, s, p string, t TypedNode) error {
	kind := strings.ToLower(t.Type)
	if kind == "iri" {
		kind = "uri"
	} else if kind == "" {
		kind = "literal"
	}
	return EmitNode(w, s, p, Node{
		Kind:     kind,
		Value:    t.Value,
		Lang:     t.Lang,
		Datatype: t.Datatype,
	})
}

// EmitNode writes a single N-Triples line.
func EmitNode(w *bufio.Writer, s, p string, n Node) error {
	var obj string
	switch n.Kind {
	case "uri":
		v := n.Value
		if !strings.HasPrefix(v, "<") {
			v = "<" + v + ">"
		}
		obj = v
	case "literal":
		obj = `"` + ntriplesEscape(n.Value) + `"`
		if n.Lang != "" {
			obj += "@" + n.Lang
		} else if n.Datatype != "" {
			obj += "^^<" + n.Datatype + ">"
		}
	case "bnode":
		obj = "_:" + ntriplesEscape(n.Value)
	default:
		return fmt.Errorf("unknown node kind: %s", n.Kind)
	}
	_, err := fmt.Fprintf(w, "<%s> <%s> %s .\n",
		ntriplesEscape(s), ntriplesEscape(p), obj)
	return err
}

func detectURIKind(s string) string {
	if strings.HasPrefix(s, "<") && strings.HasSuffix(s, ">") {
		return "uri"
	}
	for _, prefix := range []string{"urn:", "http:", "https:", "file:"} {
		if strings.HasPrefix(s, prefix) {
			return "uri"
		}
	}
	return "literal"
}

// ntriplesEscape escapes per RFC 5147 (Turtle/N-Triples literal escapes).
// Required escapes: \ → \\, " → \"
func ntriplesEscape(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString("\\\\")
		case '"':
			b.WriteString(`\"`)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
