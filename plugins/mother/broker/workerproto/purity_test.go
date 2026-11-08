package workerproto

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The package is pure (bet B1): no file, socket, process or clock access in non-test files.
func TestPackageHasNoIO(t *testing.T) {
	forbidden := map[string]bool{"os": true, "net": true, "os/exec": true, "io/ioutil": true, "net/http": true, "syscall": true}
	files, _ := filepath.Glob("*.go")
	checked := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		checked++
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(src), "time.Now(") {
			t.Errorf("%s calls time.Now(); pass now as a parameter", f)
		}
		af, err := parser.ParseFile(token.NewFileSet(), f, src, parser.ImportsOnly)
		if err != nil {
			t.Fatal(err)
		}
		for _, imp := range af.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if forbidden[p] {
				t.Errorf("%s imports %q", f, p)
			}
		}
		if strings.Contains(string(src), "go func") {
			t.Errorf("%s starts a goroutine", f)
		}
	}
	if checked < 8 {
		t.Fatalf("scan looked at only %d files", checked)
	}
}
