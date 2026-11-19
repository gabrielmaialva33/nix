package buffer

import (
	"os"
	"path/filepath"
	"testing"
)

func writeBaseDirYAML(t *testing.T, baseDir string) string {
	t.Helper()
	cfgPath := filepath.Join(t.TempDir(), "relay.yaml")
	body := "storage:\n  base_dir: \"" + baseDir + "\"\n"
	if err := os.WriteFile(cfgPath, []byte(body), 0600); err != nil {
		t.Fatalf("falha ao criar yaml de teste: %v", err)
	}
	return cfgPath
}

// TestLoadYAMLConfigBaseDirHomeExpansion garante que storage.base_dir expande ~ e $HOME
// preservando caminhos absolutos inalterados.
func TestLoadYAMLConfigBaseDirHomeExpansion(t *testing.T) {
	fakeHome := filepath.Join(t.TempDir(), "user-home")
	t.Setenv("HOME", fakeHome)

	cases := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "tilde_prefix",
			raw:  "~/x",
			want: filepath.Join(fakeHome, "x"),
		},
		{
			name: "tilde_bare",
			raw:  "~",
			want: fakeHome,
		},
		{
			name: "dollar_home",
			raw:  "$HOME/x",
			want: filepath.Join(fakeHome, "x"),
		},
		{
			name: "braced_home",
			raw:  "${HOME}/x",
			want: filepath.Join(fakeHome, "x"),
		},
		{
			name: "absolute_unchanged",
			raw:  "/var/lib/nix_relay/data",
			want: "/var/lib/nix_relay/data",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := LoadYAMLConfig(writeBaseDirYAML(t, tc.raw))
			if err != nil {
				t.Fatalf("LoadYAMLConfig(%q) retornou erro inesperado: %v", tc.raw, err)
			}
			if cfg.DataDir != tc.want {
				t.Fatalf("DataDir = %q, esperado %q", cfg.DataDir, tc.want)
			}
		})
	}

	t.Run("shipped_local_config", func(t *testing.T) {
		localCfgPath := filepath.Join("..", "..", "configs", "relay.local.yaml")
		cfg, err := LoadYAMLConfig(localCfgPath)
		if err != nil {
			t.Fatalf("LoadYAMLConfig(relay.local.yaml) falhou: %v", err)
		}
		want := "./data"
		if cfg.DataDir != want {
			t.Fatalf("relay.local.yaml DataDir = %q, esperado %q", cfg.DataDir, want)
		}
	})

	t.Run("missing_home_rejected", func(t *testing.T) {
		t.Setenv("HOME", "")
		_, err := LoadYAMLConfig(writeBaseDirYAML(t, "~/x"))
		if err == nil {
			t.Fatal("esperado erro quando HOME está vazio para caminho com ~/, mas obteve nil")
		}
	})
}
