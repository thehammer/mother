package main

import "testing"

func TestParseRegistrationRequiresARealPid(t *testing.T) {
	id, pid, secret, err := parseRegistration("w1=4242=abc=def\n")
	if err != nil || id != "w1" || pid != 4242 || secret != "abc=def" {
		t.Fatalf("got %q %d %q %v", id, pid, secret, err)
	}
	for _, bad := range []string{"w1=secret-only", "w1=0=s", "w1=-3=s", "w1=x=s", "=5=s", ""} {
		if _, _, _, err := parseRegistration(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}
