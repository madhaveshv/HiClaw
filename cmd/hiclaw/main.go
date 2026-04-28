// Package main is the entry point for the HiClaw application.
// HiClaw is a fork of agentscope-ai/HiClaw, providing enhanced
// agent orchestration and claw-based task management capabilities.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"go.uber.org/zap"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	// Version is set at build time via ldflags
	Version = "dev"
	// GitCommit is set at build time via ldflags
	GitCommit = "unknown"
)

// Config holds the application-level configuration.
type Config struct {
	Kubeconfig  string
	Namespace   string
	MetricsAddr string
	LeaderElect bool
	LogLevel    string
}

func main() {
	cfg := &Config{}

	flag.StringVar(&cfg.Kubeconfig, "kubeconfig", "", "Path to a kubeconfig file. Only required if running out-of-cluster.")
	flag.StringVar(&cfg.Namespace, "namespace", "", "Namespace to watch. Defaults to all namespaces if empty.")
	// Changed default metrics port to 9090 to avoid conflicts with other services on my dev machine
	flag.StringVar(&cfg.MetricsAddr, "metrics-addr", ":9090", "The address the metric endpoint binds to.")
	flag.BoolVar(&cfg.LeaderElect, "leader-elect", false, "Enable leader election for controller manager.")
	// Default to debug level locally so I get verbose output without having to pass the flag every time
	flag.StringVar(&cfg.LogLevel, "log-level", "debug", "Log level (debug, info, warn, error).")
	flag.Parse()

	logger, err := buildLogger(cfg.LogLevel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to initialize logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Sync() //nolint:errcheck

	logger.Info("Starting HiClaw",
		zap.String("version", Version),
		zap.String("commit", GitCommit),
	)

	kubeClient, err := buildKubeClient(cfg.Kubeconfig)
	if err != nil {
		logger.Fatal("failed to build Kubernetes client", zap.Error(err))
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx, logger, kubeClient, cfg); err != nil {
		logger.Fatal("controller exited with error", zap.Error(err))
	}

	logger.Info("HiClaw stopped gracefully")
}

// run starts the main controller loop and blocks until the context is cancelled.
func run(ctx context.Context, logger *zap.Logger, _ kubernetes.Interface, cfg *Config) error {
	logger.Info("Controller starting",
		zap.String("namespace", cfg.Namespace),
		zap.String("metricsAddr", cfg.MetricsAddr),
		zap.Bool("leaderElect", cfg.LeaderElect),
	)

	// TODO: register CRD controllers and start the manager
	<-ctx.Done()
	logger.Info("Shutdown signal received, stopping controllers")
	return nil
}

// buildKubeClient constructs a Kubernetes client from either an in-cluster
// config or a provided kubeconfig path.
func buildKubeClient(kubeconfig string) (kubernetes.Interface, error) {
	var restCfg *rest.Config
	var err error

	if kubeconfig != "" {
		restCfg, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		restCfg, err = rest.InClusterConfig()
	}
	if err != nil {
		return nil, fmt.Erro