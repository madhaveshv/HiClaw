package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"github.com/alibaba/hiclaw/orchestrator/auth"
	"github.com/alibaba/hiclaw/orchestrator/backend"
	"github.com/alibaba/hiclaw/orchestrator/internal/httputil"
)

// WorkerHandler handles /workers/* HTTP requests.
type WorkerHandler struct {
	registry        *backend.Registry
	keyStore        *auth.KeyStore
	orchestratorURL string
}

// NewWorkerHandler creates a WorkerHandler.
func NewWorkerHandler(registry *backend.Registry, keyStore *auth.KeyStore, orchestratorURL string) *WorkerHandler {
	return &WorkerHandler{registry: registry, keyStore: keyStore, orchestratorURL: orchestratorURL}
}

// Create handles POST /workers.
func (h *WorkerHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req CreateWorkerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httputil.WriteError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if req.Name == "" {
		httputil.WriteError(w, http.StatusBadRequest, "name is required")
		return
	}
	if req.Image == "" {
		httputil.WriteError(w, http.StatusBadRequest, "image is required")
		return
	}

	b, err := h.registry.GetWorkerBackend(r.Context(), req.Backend)
	if err != nil {
		httputil.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	// For SAE backend: generate per-worker API key and inject into env
	var apiKey string
	if b.Name() == "sae" && h.keyStore != nil && h.keyStore.AuthEnabled() {
		apiKey = h.keyStore.GenerateWorkerKey(req.Name)
		if req.Env == nil {
			req.Env = make(map[string]string)
		}
		req.Env["HICLAW_WORKER_API_KEY"] = apiKey
		if h.orchestratorURL != "" {
			req.Env["HICLAW_ORCHESTRATOR_URL"] = h.orchestratorURL
		}
	}

	result, err := b.Create(r.Context(), backend.CreateRequest{
		Name:       req.Name,
		Image:      req.Image,
		Runtime:    req.Runtime,
		Env:        req.Env,
		Network:    req.Network,
		ExtraHosts: req.ExtraHosts,
		WorkingDir: req.WorkingDir,
	})
	if err != nil {
		log.Printf("[ERROR] create worker %s: %v", req.Name, err)
		if apiKey != "" {
			h.keyStore.RemoveWorkerKey(req.Name)
		}
		writeBackendError(w, err)
		return
	}

	resp := toWorkerResponse(result)
	resp.APIKey = apiKey
	httputil.WriteJSON(w, http.StatusCreated, resp)
}

// List handles GET /workers.
func (h *WorkerHandler) List(w http.ResponseWriter, r *http.Request) {
	b, err := h.registry.GetWorkerBackend(r.Context(), "")
	if err != nil {
		httputil.WriteJSON(w, http.StatusOK, WorkerListResponse{Workers: []WorkerResponse{}})
		return
	}

	results, err := b.List(r.Context())
	if err != nil {
		log.Printf("[ERROR] list workers: %v", err)
		writeBackendError(w, err)
		return
	}

	workers := make([]WorkerResponse, 0, len(results))
	for _, r := range results {
		workers = append(workers, toWorkerResponse(&r))
	}
	httputil.WriteJSON(w, http.StatusOK, WorkerListResponse{Workers: workers})
}

// Status handles GET /workers/{name}.
func (h *WorkerHandler) Status(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == "" {
		httputil.WriteError(w, http.StatusBadRequest, "worker name is required")
		return
	}

	b, err := h.registry.GetWorkerBackend(r.Context(), "")
	if err != nil {
		httputil.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	result, err := b.Status(r.Context(), name)
	if err != nil {
		log.Printf("[ERROR] status worker %s: %v", name, err)
		writeBackendError(w, err)
		return
	}

	httputil.WriteJSON(w, http.StatusOK, toWorkerResponse(result))
}

// Start handles POST /workers/{name}/start.
func (h *WorkerHandler) Start(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == "" {
		httputil.WriteError(w, http.StatusBadRequest, "worker name is required")
		return
	}

	b, err := h.registry.GetWorkerBackend(r.Context(), "")
	if err != nil {
		httputil.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	if err := b.Start(r.Context(), name); err != nil {
		log.Printf("[ERROR] start worker %s: %v", name, err)
		writeBackendError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// Stop handles POST /workers/{name}/stop.
func (h *WorkerHandler) Stop(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == "" {
		httputil.WriteError(w, http.StatusBadRequest, "worker name is required")
		return
	}

	b, err := h.registry.GetWorkerBackend(r.Context(), "")
	if err != nil {
		httputil.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	if err := b.Stop(r.Context(), name); err != nil {
		log.Printf("[ERROR] stop worker %s: %v", name, err)
		writeBackendError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// Delete handles DELETE /workers/{name}.
func (h *WorkerHandler) Delete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if name == "" {
		httputil.WriteError(w, http.StatusBadRequest, "worker name is required")
		return
	}

	b, err := h.registry.GetWorkerBackend(r.Context(), "")
	if err != nil {
		httputil.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}

	if err := b.Delete(r.Context(), name); err != nil {
		log.Printf("[ERROR] delete worker %s: %v", name, err)
		writeBackendError(w, err)
		return
	}

	if h.keyStore != nil {
		h.keyStore.RemoveWorkerKey(name)
	}

	w.WriteHeader(http.StatusNoContent)
}

func toWorkerResponse(r *backend.WorkerResult) WorkerResponse {
	return WorkerResponse{
		Name:        r.Name,
		Backend:     r.Backend,
		Status:      r.Status,
		ContainerID: r.ContainerID,
		AppID:       r.AppID,
		RawStatus:   r.RawStatus,
	}
}

func writeBackendError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, backend.ErrConflict):
		httputil.WriteError(w, http.StatusConflict, err.Error())
	case errors.Is(err, backend.ErrNotFound):
		httputil.WriteError(w, http.StatusNotFound, err.Error())
	default:
		httputil.WriteError(w, http.StatusInternalServerError, err.Error())
	}
}
