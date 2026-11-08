package coord

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Applier applies a batch of outbox ops (one JSON object per entry: {"seq","t","ts","data"}) onto the
// canonical tree and reports the last op seq applied. The production implementation execs
// lib/coord_apply.sh; tests inject a fake. A non-nil error with applied > 0 means a prefix landed.
type Applier interface {
	Apply(job string, ops [][]byte) (applied int64, err error)
}

// ExecApplier runs `bash <LibDir>/coord_apply.sh <Root> <job>` with the ops on stdin. Exit 0 (all
// applied) and 3 (done, some op quarantined) are success; any other exit is an error, but stdout is
// still parsed because the script prints the last applied seq on every exit.
type ExecApplier struct {
	Root, LibDir string
	Timeout      time.Duration
}

func (a ExecApplier) Apply(job string, ops [][]byte) (int64, error) {
	timeout := a.Timeout
	if timeout <= 0 {
		timeout = 150 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", a.LibDir+"/coord_apply.sh", a.Root, job)
	cmd.Stdin = bytes.NewReader(append(bytes.Join(ops, []byte("\n")), '\n'))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	applied := lastInt(out.String())
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 3 {
			return applied, nil
		}
		return applied, fmt.Errorf("coord_apply: %v: %s", err, strings.TrimSpace(errb.String()))
	}
	return applied, nil
}

func lastInt(s string) int64 {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if n, err := strconv.ParseInt(strings.TrimSpace(lines[i]), 10, 64); err == nil {
			return n
		}
	}
	return 0
}
