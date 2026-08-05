// lzt-virtuoso-convert-jsonl-go CLI wrapper — calls internal package DoMain().
package main

import (
	"os"

	"lzt-virtuoso-tools/internal/convert"
)

func main() {
	os.Exit(convert.DoMain())
}
