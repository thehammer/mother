package worker

import "os/exec"

func startSleep() (*exec.Cmd, error) {
	c := exec.Command("sleep", "60")
	return c, c.Start()
}
