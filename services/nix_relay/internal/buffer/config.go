package buffer

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config centraliza os parâmetros operacionais do Nix Relay.
type Config struct {
	ServerHost               string
	ServerPort               int
	OnionServiceHost         string
	DataDir                  string
	PostgresDSN              string
	MaxAttachmentSizeBytes   int64
	MaxInFlightPerQuotaToken int64
	BaseTTLSeconds           int64
	CheckIntervalSeconds     int
	LightThresholdPercent    int
	SevereThresholdPercent   int
	CriticalThresholdPercent int
	MetricsEnabled           bool
	MetricsListenAddr        string
	ZeroIdentifyingLabels    bool
}

// ValidateAdminListenAddr assegura isolamento estrito em loopback para endpoints administrativos e métricas (REL04).
func ValidateAdminListenAddr(addr string) error {
	host, _, err := net.SplitHostPort(strings.TrimSpace(addr))
	if err != nil {
		return errors.New("metrics.listen_addr inválido (esperado host:port)")
	}
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("metrics.listen_addr deve vincular exclusivamente em endereço loopback (127.0.0.1/::1/localhost)")
	}
	return nil
}

// DefaultConfig retorna parâmetros seguros padrão (TTL de 7 dias e histerese 75/85/92).
func DefaultConfig() Config {
	return Config{
		ServerHost:               "127.0.0.1",
		ServerPort:               8080,
		OnionServiceHost:         "",
		DataDir:                  "/var/lib/nix_relay/data",
		MaxAttachmentSizeBytes:   52428800,  // 50 MB
		MaxInFlightPerQuotaToken: 524288000, // 500 MB
		BaseTTLSeconds:           604800,    // 7 dias
		CheckIntervalSeconds:     60,
		LightThresholdPercent:    75,
		SevereThresholdPercent:   85,
		CriticalThresholdPercent: 92,
		MetricsEnabled:           true,
		MetricsListenAddr:        "127.0.0.1:9090",
		ZeroIdentifyingLabels:    true,
	}
}

// LoadYAMLConfig carrega configurações simples em seções YAML sem dependências externas.
func LoadYAMLConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	f, err := os.Open(path)
	if err != nil {
		return cfg, err
	}
	defer f.Close()

	var section string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if idx := strings.Index(line, "#"); idx >= 0 {
			line = line[:idx]
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasSuffix(trimmed, ":") && !strings.Contains(trimmed, " ") {
			section = strings.TrimSuffix(trimmed, ":")
			continue
		}
		colonIdx := strings.Index(trimmed, ":")
		if colonIdx <= 0 {
			continue
		}
		key := strings.TrimSpace(trimmed[:colonIdx])
		val := strings.TrimSpace(trimmed[colonIdx+1:])
		val = strings.Trim(val, `"'`)

		switch section + "." + key {
		case "server.host":
			if val != "" {
				cfg.ServerHost = val
			}
		case "server.port":
			if p, err := strconv.Atoi(val); err == nil && p > 0 {
				cfg.ServerPort = p
			}
		case "server.onion_service_host":
			cfg.OnionServiceHost = val
		case "storage.base_dir":
			if val != "" {
				expanded, err := expandBaseDir(val)
				if err != nil {
					return cfg, err
				}
				cfg.DataDir = expanded
			}
		case "storage.postgres_dsn":
			if val != "" {
				cfg.PostgresDSN = val
			}
		case "storage.max_attachment_size_bytes":
			if n, err := strconv.ParseInt(val, 10, 64); err == nil && n > 0 {
				cfg.MaxAttachmentSizeBytes = n
			}
		case "storage.max_in_flight_per_quota_token":
			if n, err := strconv.ParseInt(val, 10, 64); err == nil && n > 0 {
				cfg.MaxInFlightPerQuotaToken = n
			}
		case "storage.base_ttl_seconds":
			if n, err := strconv.ParseInt(val, 10, 64); err == nil && n > 0 {
				cfg.BaseTTLSeconds = n
			}
		case "pruning.check_interval_seconds":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				cfg.CheckIntervalSeconds = n
			}
		case "pruning.light_threshold_percent":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				cfg.LightThresholdPercent = n
			}
		case "pruning.severe_threshold_percent":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				cfg.SevereThresholdPercent = n
			}
		case "pruning.critical_threshold_percent":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				cfg.CriticalThresholdPercent = n
			}
		case "metrics.enabled":
			cfg.MetricsEnabled = strings.EqualFold(val, "true")
		case "metrics.listen_addr":
			if val != "" {
				cfg.MetricsListenAddr = val
			}
		case "metrics.zero_identifying_labels":
			cfg.ZeroIdentifyingLabels = strings.EqualFold(val, "true")
		}
	}
	if envDSN := strings.TrimSpace(os.Getenv("NIX_RELAY_PG_DSN")); envDSN != "" {
		cfg.PostgresDSN = envDSN
	}
	return cfg, scanner.Err()
}

func expandBaseDir(raw string) (string, error) {
	switch {
	case raw == "~":
		return resolveHomeDir("")
	case strings.HasPrefix(raw, "~/"):
		return resolveHomeDir(raw[2:])
	case raw == "$HOME", raw == "${HOME}":
		return resolveHomeDir("")
	case strings.HasPrefix(raw, "$HOME/"):
		return resolveHomeDir(strings.TrimPrefix(raw, "$HOME/"))
	case strings.HasPrefix(raw, "${HOME}/"):
		return resolveHomeDir(strings.TrimPrefix(raw, "${HOME}/"))
	default:
		return raw, nil
	}
}

func resolveHomeDir(rel string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		if err != nil {
			return "", fmt.Errorf("storage.base_dir requer HOME válido: %w", err)
		}
		return "", fmt.Errorf("storage.base_dir requer HOME válido")
	}
	if rel == "" {
		return home, nil
	}
	return filepath.Join(home, rel), nil
}
