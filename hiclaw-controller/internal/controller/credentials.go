package controller

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// WorkerCredentials holds persisted credentials for a worker.
// These are generated once on first creation and reused across retries.
type WorkerCredentials struct {
	MatrixPassword string
	MinIOPassword  string
	GatewayKey     string
	RoomID         string // persisted for idempotent room reuse
}

// CredentialStore manages worker credential persistence.
type CredentialStore interface {
	Load(ctx context.Context, workerName string) (*WorkerCredentials, error)
	Save(ctx context.Context, workerName string, creds *WorkerCredentials) error
	Delete(ctx context.Context, workerName string) error
}

// FileCredentialStore persists credentials as env files (embedded mode).
// Compatible with the existing /data/worker-creds/{name}.env format.
type FileCredentialStore struct {
	Dir string // e.g. /data/worker-creds
}

func (s *FileCredentialStore) Load(_ context.Context, workerName string) (*WorkerCredentials, error) {
	path := filepath.Join(s.Dir, workerName+".env")
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("open credentials file: %w", err)
	}
	defer f.Close()

	creds := &WorkerCredentials{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v := parseEnvLine(line)
		switch k {
		case "WORKER_PASSWORD":
			creds.MatrixPassword = v
		case "WORKER_MINIO_PASSWORD":
			creds.MinIOPassword = v
		case "WORKER_GATEWAY_KEY":
			creds.GatewayKey = v
		case "WORKER_ROOM_ID":
			creds.RoomID = v
		}
	}
	return creds, scanner.Err()
}

func (s *FileCredentialStore) Save(_ context.Context, workerName string, creds *WorkerCredentials) error {
	if err := os.MkdirAll(s.Dir, 0755); err != nil {
		return fmt.Errorf("create credentials dir: %w", err)
	}
	path := filepath.Join(s.Dir, workerName+".env")
	content := fmt.Sprintf(
		"WORKER_PASSWORD=%q\nWORKER_MINIO_PASSWORD=%q\nWORKER_GATEWAY_KEY=%q\nWORKER_ROOM_ID=%q\n",
		creds.MatrixPassword, creds.MinIOPassword, creds.GatewayKey, creds.RoomID,
	)
	return os.WriteFile(path, []byte(content), 0600)
}

func (s *FileCredentialStore) Delete(_ context.Context, workerName string) error {
	path := filepath.Join(s.Dir, workerName+".env")
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func parseEnvLine(line string) (string, string) {
	idx := strings.IndexByte(line, '=')
	if idx < 0 {
		return line, ""
	}
	k := line[:idx]
	v := line[idx+1:]
	v = strings.Trim(v, `"'`)
	return k, v
}

// GenerateCredentials creates a fresh set of worker credentials.
func GenerateCredentials() (*WorkerCredentials, error) {
	matrixPw, err := generateRandomHex(16)
	if err != nil {
		return nil, fmt.Errorf("generate matrix password: %w", err)
	}
	minioPw, err := generateRandomHex(24)
	if err != nil {
		return nil, fmt.Errorf("generate minio password: %w", err)
	}
	gwKey, err := generateRandomHex(32)
	if err != nil {
		return nil, fmt.Errorf("generate gateway key: %w", err)
	}
	return &WorkerCredentials{
		MatrixPassword: matrixPw,
		MinIOPassword:  minioPw,
		GatewayKey:     gwKey,
	}, nil
}

// generateRandomHex returns n random bytes encoded as 2*n hex characters.
func generateRandomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
