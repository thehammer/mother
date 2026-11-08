package worker

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"strconv"

	"mother-broker/workerproto"
)

type frameMeta struct {
	oseq   int64 // outbox seq of an op frame
	logEnd int64 // end offset of a log chunk
	last   bool  // the lease.release frame
}

// shipState is a lease's outbound position for the current connection. It is rebuilt from the welcome on
// every connection: the coordinator's committed position is the only authority on what was applied, so
// nothing depends on this process remembering an unacked window across a restart.
type shipState struct {
	base     int64 // wire seq of the last frame the coordinator committed; the next frame is base+1
	out      *workerproto.OutStream
	meta     map[int64]frameMeta
	outPos   int64 // byte offset into outbox/<job>.ndjson already consumed
	nextOseq int64 // outbox seq the coordinator expects next
	logOff   int64 // next log byte to ship
	released bool  // lease.release is in the window
}

func (d *Daemon) rebase(jobs []workerproto.WelcomeJob) {
	known := map[string]workerproto.WelcomeJob{}
	for _, j := range jobs {
		known[j.Job] = j
	}
	for _, l := range d.leases {
		l.ship = nil
		if l.loc.State != stateActive {
			continue
		}
		wj, ok := known[l.loc.Job]
		if !ok || wj.Lease != l.loc.LeaseID || wj.Epoch != l.loc.Epoch {
			continue
		}
		l.ship = &shipState{base: wj.WireSeq, out: workerproto.NewOutStream(), meta: map[int64]frameMeta{}, nextOseq: wj.AppliedSeq + 1, logOff: wj.LogOffset}
	}
}

type outboxOp struct {
	Seq  int64           `json:"seq"`
	T    string          `json:"t"`
	Data json.RawMessage `json:"data"`
}

// withOseq adds the additive outbox-seq fields to an op's data object: oseq, and oskip [from,to] when ops
// before it were consumed without being sent.
func withOseq(data json.RawMessage, oseq, skipFrom int64) json.RawMessage {
	d := bytes.TrimSpace(data)
	if len(d) < 2 || d[0] != '{' || d[len(d)-1] != '}' {
		return nil
	}
	extra := `"oseq":` + strconv.FormatInt(oseq, 10)
	if skipFrom > 0 {
		extra += `,"oskip":[` + strconv.FormatInt(skipFrom, 10) + `,` + strconv.FormatInt(oseq-1, 10) + `]`
	}
	body := bytes.TrimSpace(d[1 : len(d)-1])
	if len(body) == 0 {
		return json.RawMessage("{" + extra + "}")
	}
	return json.RawMessage("{" + string(body) + "," + extra + "}")
}

// filterJobSet drops the keys the wire's ownership table refuses (coordinator-derived keys,
// `state: succeeded`, ...): the supervisor writes them into its own mirror, but a job.set carrying any is
// refused whole. It returns nil when nothing is left to send.
func filterJobSet(data json.RawMessage) json.RawMessage {
	var js workerproto.JobSet
	if json.Unmarshal(data, &js) != nil {
		return nil
	}
	bad := map[string]bool{}
	for _, v := range workerproto.CheckJobSet(workerproto.JobState{State: "running"}, js.Set, js.Del) {
		bad[v.Key] = true
	}
	if len(bad) == 0 {
		return data
	}
	out := workerproto.JobSet{Set: map[string]json.RawMessage{}, Del: []string{}}
	for k, v := range js.Set {
		if !bad[k] {
			out.Set[k] = v
		}
	}
	for _, k := range js.Del {
		if !bad[k] {
			out.Del = append(out.Del, k)
		}
	}
	if len(out.Set) == 0 && len(out.Del) == 0 {
		return nil
	}
	b, _ := json.Marshal(out)
	return b
}

// shipLease sends whatever is new for l: outbox ops, then log bytes, then (once the supervisor has
// exited and everything is acked) the release. Caller holds d.mu.
func (d *Daemon) shipLease(s *session, l *lease) {
	sh := l.ship
	exitedBefore := l.exited
	if !d.shipOps(s, l) || !d.shipLog(s, l) {
		return
	}
	if !exitedBefore || sh.released {
		return
	}
	if sh.out.Unacked() > 0 || !d.drained(l) {
		return
	}
	state := d.mirrorState(l.loc.Job)
	if !releasableState(state) {
		if !l.noHB {
			d.logf("%s: supervisor exited with the job in state %q; the coordinator decides on loss", l.loc.Job, state)
			l.noHB = true
		}
		return
	}
	reason := state
	if l.adoptedDead {
		reason = "supervisor_exited"
	}
	data, _ := json.Marshal(workerproto.LeaseRelease{Reason: reason})
	seq := sh.base + sh.out.Last() + 1
	b, err := build(workerproto.TypeLeaseRelease, l, &seq, json.RawMessage(data))
	if err != nil {
		d.logf("release %s: %v", l.loc.Job, err)
		return
	}
	sh.out.Append(workerproto.TypeLeaseRelease, data)
	sh.meta[seq] = frameMeta{last: true}
	sh.released = true
	l.loc.ReleaseSent, l.loc.EndReason = true, reason
	d.persistLease(l)
	_ = s.send(b)
}

// drained: the outbox and log are fully consumed.
func (d *Daemon) drained(l *lease) bool {
	sh := l.ship
	if fi, err := os.Stat(d.p("outbox", l.loc.Job+".ndjson")); err == nil && fi.Size() > sh.outPos {
		return false
	}
	if fi, err := os.Stat(d.p("logs", l.loc.Job+".log")); err == nil && fi.Size() > sh.logOff {
		return false
	}
	return true
}

func (d *Daemon) shipOps(s *session, l *lease) bool {
	sh := l.ship
	f, err := os.Open(d.p("outbox", l.loc.Job+".ndjson"))
	if err != nil {
		return true
	}
	defer f.Close()
	if fi, err := f.Stat(); err == nil && fi.Size() < sh.outPos {
		sh.outPos = 0 // the file was replaced
	}
	if _, err := f.Seek(sh.outPos, io.SeekStart); err != nil {
		return true
	}
	br := bufio.NewReaderSize(f, 256<<10)
	for n := 0; n < 256 && !sh.out.Full(); n++ {
		line, err := br.ReadBytes('\n')
		if err != nil {
			return true // EOF, or a line still being written: not consumed
		}
		sh.outPos += int64(len(line))
		var op outboxOp
		if json.Unmarshal(bytes.TrimSpace(line), &op) != nil || op.Seq < 1 || !workerproto.IsStreamType(op.T) {
			d.logf("%s: skipping an unreadable outbox line", l.loc.Job)
			continue
		}
		if op.Seq < sh.nextOseq {
			continue // already applied by the coordinator
		}
		data := op.Data
		if op.T == workerproto.TypeJobSet {
			data = filterJobSet(data)
		}
		var skipFrom int64
		if op.Seq > sh.nextOseq {
			skipFrom = sh.nextOseq
		}
		var payload json.RawMessage
		if data != nil {
			payload = withOseq(data, op.Seq, skipFrom)
		}
		if payload == nil {
			// Nothing sendable (every key refused, or too large): the next op carries the skip range.
			continue
		}
		seq := sh.base + sh.out.Last() + 1
		b, err := build(op.T, l, &seq, payload)
		if err != nil {
			d.logf("%s: outbox op %d cannot be sent: %v", l.loc.Job, op.Seq, err)
			continue
		}
		sh.out.Append(op.T, payload)
		sh.meta[seq] = frameMeta{oseq: op.Seq}
		sh.nextOseq = op.Seq + 1
		if s.send(b) != nil {
			return false
		}
	}
	return true
}

func (d *Daemon) shipLog(s *session, l *lease) bool {
	sh := l.ship
	f, err := os.Open(d.p("logs", l.loc.Job+".log"))
	if err != nil {
		return true
	}
	defer f.Close()
	for n := 0; n < 8 && !sh.out.Full(); n++ {
		buf := make([]byte, workerproto.MaxChunkBytes)
		m, err := f.ReadAt(buf, sh.logOff)
		if m == 0 {
			return true
		}
		_ = err
		payload, _ := json.Marshal(workerproto.LogAppend{Offset: sh.logOff, B64: base64.StdEncoding.EncodeToString(buf[:m])})
		seq := sh.base + sh.out.Last() + 1
		b, err := build(workerproto.TypeLogAppend, l, &seq, json.RawMessage(payload))
		if err != nil {
			d.logf("%s: log chunk cannot be sent: %v", l.loc.Job, err)
			return true
		}
		sh.out.Append(workerproto.TypeLogAppend, payload)
		sh.meta[seq] = frameMeta{logEnd: sh.logOff + int64(m)}
		sh.logOff += int64(m)
		if s.send(b) != nil {
			return false
		}
	}
	return true
}

// onAck trims the window and records what the coordinator confirmed. A resend_from asks for the frames
// from that seq again. Caller holds d.mu.
func (d *Daemon) onAck(s *session, f workerproto.Frame) {
	var a workerproto.AckData
	_ = json.Unmarshal(f.Data, &a)
	l := d.leases[a.Job]
	if l == nil || l.ship == nil || l.loc.LeaseID != a.Lease || l.loc.Epoch != a.Epoch {
		return
	}
	sh := l.ship
	if a.Seq > sh.base {
		if err := sh.out.Ack(a.Seq - sh.base); err != nil {
			return
		}
		released := false
		for seq, m := range sh.meta {
			if seq > a.Seq {
				continue
			}
			if m.oseq > l.loc.AppliedSeq {
				l.loc.AppliedSeq = m.oseq
			}
			if m.logEnd > l.loc.LogOffset {
				l.loc.LogOffset = m.logEnd
			}
			released = released || m.last
			delete(sh.meta, seq)
		}
		l.loc.AckedSeq = a.Seq
		if released {
			d.markReleased(l, l.loc.EndReason)
			d.logf("lease for %s released", l.loc.Job)
			return
		}
		d.persistLease(l)
	}
	if a.ResendFrom != nil {
		for _, p := range sh.out.ResendFrom(*a.ResendFrom - sh.base) {
			seq := sh.base + p.Seq
			b, err := build(p.Type, l, &seq, p.Data)
			if err != nil {
				continue
			}
			if s.send(b) != nil {
				return
			}
		}
	}
}
