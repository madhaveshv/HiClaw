package backend

import "testing"

func TestResolveRuntime(t *testing.T) {
	cases := []struct {
		name           string
		reqRuntime     string
		backendDefault string
		want           string
	}{
		{"explicit_request_wins", RuntimeCopaw, RuntimeHermes, RuntimeCopaw},
		{"empty_request_uses_backend_default_hermes", "", RuntimeHermes, RuntimeHermes},
		{"empty_request_uses_backend_default_copaw", "", RuntimeCopaw, RuntimeCopaw},
		{"empty_request_no_default_falls_back_to_openclaw", "", "", RuntimeOpenClaw},
		{"explicit_openclaw_preserved", RuntimeOpenClaw, RuntimeHermes, RuntimeOpenClaw},
		{"explicit_hermes_preserved", RuntimeHermes, RuntimeCopaw, RuntimeHermes},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveRuntime(tc.reqRuntime, tc.backendDefault)
			if got != tc.want {
				t.Fatalf("ResolveRuntime(%q, %q) = %q, want %q", tc.reqRuntime, tc.backendDefault, got, tc.want)
			}
		})
	}
}
