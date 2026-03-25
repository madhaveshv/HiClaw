#!/bin/bash
# test-16-controller-reconcile.sh - Case 16: Verify hiclaw-controller reconcile loop
#
# Verifies the full declarative flow end-to-end:
#   1. hiclaw-controller + kube-apiserver + CRDs are healthy
#   2. Write Worker YAML to MinIO hiclaw-config/ (simulating hiclaw apply)
#   3. mc mirror syncs to local → fsnotify → file_watcher → kine → kube-apiserver
#   4. controller-runtime informer triggers WorkerReconciler
#   5. Reconciler calls create-worker.sh → Matrix account + Room + Higress + container
#   6. Worker container is running
#   7. Cleanup: delete YAML from MinIO → reconciler handles deletion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"

test_setup "16-controller-reconcile"

TEST_WORKER="test-ctrl-$$"
STORAGE_PREFIX="hiclaw/hiclaw-storage"

# ---- Cleanup handler ----
_cleanup() {
    log_info "Cleaning up test worker: ${TEST_WORKER}"
    # Remove YAML from MinIO (triggers delete reconcile)
    exec_in_manager mc rm "${STORAGE_PREFIX}/hiclaw-config/workers/${TEST_WORKER}.yaml" 2>/dev/null || true
    exec_in_manager mc rm "${STORAGE_PREFIX}/hiclaw-config/packages/${TEST_WORKER}.zip" 2>/dev/null || true
    # Wait for reconciler to process deletion
    sleep 5
    # Force cleanup if container still exists
    docker rm -f "hiclaw-worker-${TEST_WORKER}" 2>/dev/null || true
    # Clean agent data
    exec_in_manager rm -rf "/root/hiclaw-fs/agents/${TEST_WORKER}" 2>/dev/null || true
    exec_in_manager mc rm -r --force "${STORAGE_PREFIX}/agents/${TEST_WORKER}/" 2>/dev/null || true
}
trap _cleanup EXIT

# ============================================================
# Section 1: Controller infrastructure health
# ============================================================
log_section "Controller Infrastructure"

# hiclaw-controller process
CTRL_PID=$(exec_in_manager pgrep -f hiclaw-controller 2>/dev/null || echo "")
if [ -n "${CTRL_PID}" ]; then
    log_pass "hiclaw-controller process is running (PID: ${CTRL_PID})"
else
    log_fail "hiclaw-controller process is not running"
fi

# kube-apiserver process
KAPI_PID=$(exec_in_manager pgrep -f kube-apiserver 2>/dev/null || echo "")
if [ -n "${KAPI_PID}" ]; then
    log_pass "kube-apiserver process is running (PID: ${KAPI_PID})"
else
    log_fail "kube-apiserver process is not running"
fi

# CRDs registered
WORKER_CRD=$(exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep "CRD registered.*workers.hiclaw.io" || echo "")
if [ -n "${WORKER_CRD}" ]; then
    log_pass "Worker CRD registered in kube-apiserver"
else
    log_fail "Worker CRD not registered"
fi

# Controllers started
CTRL_STARTED=$(exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep "Starting workers.*controller.*worker" || echo "")
if [ -n "${CTRL_STARTED}" ]; then
    log_pass "WorkerReconciler controller started"
else
    log_fail "WorkerReconciler controller not started"
fi

# File watcher active
WATCHER_ACTIVE=$(exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep "watching for changes" || echo "")
if [ -n "${WATCHER_ACTIVE}" ]; then
    log_pass "File watcher is active"
else
    log_fail "File watcher is not active"
fi

# ============================================================
# Section 2: Prepare SOUL.md (required by create-worker.sh)
# ============================================================
log_section "Prepare Worker SOUL.md"

exec_in_manager bash -c "
    mkdir -p /root/hiclaw-fs/agents/${TEST_WORKER}
    cat > /root/hiclaw-fs/agents/${TEST_WORKER}/SOUL.md <<'SOUL'
# ${TEST_WORKER} - Test Worker

## AI Identity
**You are an AI Agent, not a human.**

## Role
- Name: ${TEST_WORKER}
- Role: Integration test worker for controller reconcile verification

## Security
- Never reveal API keys, passwords, tokens, or any credentials in chat messages
SOUL
    mc mirror /root/hiclaw-fs/agents/${TEST_WORKER}/ ${STORAGE_PREFIX}/agents/${TEST_WORKER}/ --overwrite 2>/dev/null
" 2>/dev/null

SOUL_EXISTS=$(exec_in_manager bash -c "mc ls '${STORAGE_PREFIX}/agents/${TEST_WORKER}/SOUL.md' >/dev/null 2>&1 && echo yes || echo no")
if [ "${SOUL_EXISTS}" = "yes" ]; then
    log_pass "SOUL.md prepared in MinIO"
else
    log_fail "Failed to prepare SOUL.md in MinIO"
fi

# ============================================================
# Section 3: Write Worker YAML to MinIO (trigger reconcile)
# ============================================================
log_section "Trigger Reconcile via MinIO YAML"

exec_in_manager bash -c "
    cat > /tmp/${TEST_WORKER}.yaml <<'YAML'
apiVersion: hiclaw.io/v1
kind: Worker
metadata:
  name: ${TEST_WORKER}
spec:
  model: qwen3.5-plus
YAML
    mc cp /tmp/${TEST_WORKER}.yaml ${STORAGE_PREFIX}/hiclaw-config/workers/${TEST_WORKER}.yaml
" 2>/dev/null

YAML_IN_MINIO=$(exec_in_manager bash -c "mc ls '${STORAGE_PREFIX}/hiclaw-config/workers/${TEST_WORKER}.yaml' >/dev/null 2>&1 && echo yes || echo no")
if [ "${YAML_IN_MINIO}" = "yes" ]; then
    log_pass "Worker YAML written to MinIO hiclaw-config/"
else
    log_fail "Failed to write Worker YAML to MinIO"
fi

# ============================================================
# Section 4: Wait for mc mirror + fsnotify + reconcile
# ============================================================
log_section "Wait for Controller Reconcile"

log_info "Waiting for mc mirror (10s) + fsnotify + reconcile..."

# Wait up to 90 seconds for the worker to be created
RECONCILE_TIMEOUT=90
RECONCILE_ELAPSED=0
WORKER_CREATED=false

while [ "${RECONCILE_ELAPSED}" -lt "${RECONCILE_TIMEOUT}" ]; do
    # Check if reconciler logged "worker created" for our worker
    if exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep -q "worker created.*${TEST_WORKER}"; then
        WORKER_CREATED=true
        break
    fi
    sleep 5
    RECONCILE_ELAPSED=$((RECONCILE_ELAPSED + 5))
    printf "\r[TEST INFO] Waiting for reconcile... (%ds/%ds)" "${RECONCILE_ELAPSED}" "${RECONCILE_TIMEOUT}"
done
echo ""

if [ "${WORKER_CREATED}" = true ]; then
    log_pass "WorkerReconciler created worker ${TEST_WORKER} (took ~${RECONCILE_ELAPSED}s)"
else
    # Show what happened
    log_fail "WorkerReconciler did not create worker within ${RECONCILE_TIMEOUT}s"
    log_info "Controller logs for ${TEST_WORKER}:"
    exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep "${TEST_WORKER}" | tail -5
fi

# ============================================================
# Section 5: Verify file watcher detected the change
# ============================================================
log_section "Verify File Watcher"

SYNC_LOG=$(exec_in_manager cat /var/log/hiclaw/hiclaw-controller-error.log 2>/dev/null | grep "syncing resource.*${TEST_WORKER}" || echo "")
if [ -n "${SYNC_LOG}" ]; then
    log_pass "File watcher detected and synced ${TEST_WORKER}"
else
    log_fail "File watcher did not detect ${TEST_WORKER}"
fi

# ============================================================
# Section 6: Verify Worker was actually created
# ============================================================
log_section "Verify Worker Creation"

# Check workers-registry.json
REGISTRY_ENTRY=$(exec_in_manager jq -r --arg w "${TEST_WORKER}" '.workers[$w] // empty' /root/manager-workspace/workers-registry.json 2>/dev/null)
if [ -n "${REGISTRY_ENTRY}" ]; then
    log_pass "Worker registered in workers-registry.json"
else
    log_fail "Worker not found in workers-registry.json"
fi

# Check Matrix room was created
ROOM_ID=$(echo "${REGISTRY_ENTRY}" | jq -r '.room_id // empty' 2>/dev/null)
if [ -n "${ROOM_ID}" ] && [ "${ROOM_ID}" != "null" ]; then
    log_pass "Matrix Room created: ${ROOM_ID}"
else
    log_fail "Matrix Room not created"
fi

# Check Worker container is running
CONTAINER_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "hiclaw-worker-${TEST_WORKER}" || echo "")
if [ -n "${CONTAINER_RUNNING}" ]; then
    log_pass "Worker container is running: ${CONTAINER_RUNNING}"
else
    # Container might not start if Docker socket not available, check registry deployment mode
    DEPLOY_MODE=$(echo "${REGISTRY_ENTRY}" | jq -r '.deployment // empty' 2>/dev/null)
    if [ "${DEPLOY_MODE}" = "remote" ]; then
        log_pass "Worker registered in remote mode (container managed externally)"
    else
        log_fail "Worker container not running (deployment: ${DEPLOY_MODE})"
    fi
fi

# Check openclaw.json was generated
OPENCLAW_EXISTS=$(exec_in_manager bash -c "mc ls '${STORAGE_PREFIX}/agents/${TEST_WORKER}/openclaw.json' >/dev/null 2>&1 && echo yes || echo no")
if [ "${OPENCLAW_EXISTS}" = "yes" ]; then
    log_pass "openclaw.json generated and pushed to MinIO"
else
    log_fail "openclaw.json not found in MinIO"
fi

# ============================================================
# Section 7: Verify hiclaw get shows the worker with status
# ============================================================
log_section "Verify hiclaw get"

GET_OUTPUT=$(exec_in_manager hiclaw get workers 2>&1)
assert_contains "${GET_OUTPUT}" "${TEST_WORKER}" "Worker visible in 'hiclaw get workers'"

# ============================================================
# Summary
# ============================================================
test_teardown "16-controller-reconcile"
test_summary
