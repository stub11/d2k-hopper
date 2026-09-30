package probe

import "testing"

func TestNetworkForAddr(t *testing.T) {
	cases := []struct{ addr, want string }{
		{"192.0.2.1", "tcp4"},
		{"2001:db8::1", "tcp6"},
		{"example.com", "tcp"},
	}
	for _, tc := range cases {
		if got := networkForAddr(tc.addr); got != tc.want {
			t.Fatalf("networkForAddr(%q)=%q, want %q", tc.addr, got, tc.want)
		}
	}
}
