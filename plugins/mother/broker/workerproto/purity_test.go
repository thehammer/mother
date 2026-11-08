package workerproto

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The package is pure (bet B1): no file, socket, process, clock, randomness or concurrency in non-test
// files. The check walks the AST, so aliased imports, dot imports and `go` statements are all caught.

var forbiddenImports = map[string]bool{
	"os": true, "net": true, "os/exec": true, "os/signal": true, "io/fs": true, "io/ioutil": true,
	"net/http": true, "syscall": true, "log": true, "log/slog": true, "math/rand": true,
	"math/rand/v2": true, "crypto/rand": true, "sync": true, "sync/atomic": true, "unsafe": true,
}

// allowedImports lists forbidden imports a file may keep anyway, each with the reason. Empty: nothing
// in this package needs one. Adding an entry is a deliberate, reviewed act.
var allowedImports = map[string]string{}

var forbiddenTime = map[string]bool{
	"Now": true, "Since": true, "Until": true, "Sleep": true, "After": true, "Tick": true,
	"NewTimer": true, "NewTicker": true, "AfterFunc": true,
}

// purityViolations reports every purity violation in one Go source file.
func purityViolations(name string, src []byte) []string {
	af, err := parser.ParseFile(token.NewFileSet(), name, src, 0)
	if err != nil {
		return []string{"parse: " + err.Error()}
	}
	var out []string
	timeNames := map[string]bool{}
	for _, imp := range af.Imports {
		p, _ := strconv.Unquote(imp.Path.Value)
		local := p[strings.LastIndex(p, "/")+1:]
		if imp.Name != nil {
			local = imp.Name.Name
		}
		if p == "time" {
			if local == "." {
				out = append(out, "dot-imports time (hides time.Now)")
			}
			timeNames[local] = true
		}
		if forbiddenImports[p] {
			if _, ok := allowedImports[p]; !ok {
				out = append(out, "imports "+strconv.Quote(p))
			}
		}
	}
	ast.Inspect(af, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.GoStmt:
			out = append(out, "starts a goroutine")
		case *ast.SelectorExpr:
			if id, ok := x.X.(*ast.Ident); ok && timeNames[id.Name] && forbiddenTime[x.Sel.Name] {
				out = append(out, "calls time."+x.Sel.Name+"; pass now as a parameter")
			}
		}
		return true
	})
	return out
}

func TestPackageIsPure(t *testing.T) {
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
		for _, v := range purityViolations(f, src) {
			t.Errorf("%s: %s", f, v)
		}
	}
	if checked < 9 {
		t.Fatalf("scan looked at only %d files", checked)
	}
}

func TestPurityCheckerCatchesViolations(t *testing.T) {
	cases := map[string]string{
		"os":             `package p; import "os"; var _ = os.Args`,
		"net":            `package p; import "net"; var _ net.Conn`,
		"exec":           `package p; import "os/exec"; var _ = exec.Command`,
		"signal":         `package p; import "os/signal"; var _ = signal.Notify`,
		"io/fs":          `package p; import "io/fs"; var _ fs.FS`,
		"log":            `package p; import "log"; var _ = log.Println`,
		"math/rand":      `package p; import "math/rand"; var _ = rand.Int`,
		"crypto/rand":    `package p; import "crypto/rand"; var _ = rand.Read`,
		"sync":           `package p; import "sync"; var _ sync.Mutex`,
		"aliased os":     `package p; import o "os"; var _ = o.Args`,
		"go stmt":        `package p; func f() { go func() {}() }`,
		"time.Now":       `package p; import "time"; var _ = time.Now`,
		"aliased time":   `package p; import tm "time"; var _ = tm.Now()`,
		"time.Since":     `package p; import "time"; var _ = time.Since`,
		"time.Sleep":     `package p; import "time"; func f() { time.Sleep(1) }`,
		"time.After":     `package p; import "time"; var _ = time.After`,
		"time.Tick":      `package p; import "time"; var _ = time.Tick`,
		"time.NewTimer":  `package p; import "time"; var _ = time.NewTimer`,
		"time.AfterFunc": `package p; import "time"; var _ = time.AfterFunc`,
		"time.Until":     `package p; import "time"; var _ = time.Until`,
		"dot time":       `package p; import . "time"; var _ = Now()`,
	}
	for name, src := range cases {
		if len(purityViolations(name+".go", []byte(src))) == 0 {
			t.Errorf("%s: not detected", name)
		}
	}
	clean := `package p; import ("time"; "strings"); var _ = time.Date; var _ = strings.ToLower; type t struct{ d time.Duration }`
	if v := purityViolations("clean.go", []byte(clean)); len(v) != 0 {
		t.Errorf("false positive: %v", v)
	}
	// A substring in a string or comment is not a violation (the old scan flagged these).
	if v := purityViolations("c.go", []byte("package p\n// time.Now() go func\nvar s = \"time.Now( go func\"")); len(v) != 0 {
		t.Errorf("false positive: %v", v)
	}
}
