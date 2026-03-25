#!/bin/bash
# test_import_worker_zip.sh - Integration test: import a Worker from a local ZIP package
#
# Prerequisites:
#   - hiclaw-manager container running with hiclaw-controller active
#   - mc alias "hiclaw" configured (or running inside Manager container)
#
# Usage:
#   bash test_import_worker_zip.sh                    # run inside Manager container
#   bash test_import_worker_zip.sh --external         # run from host via docker exec

set -euo pipefail

EXTERNAL_MODE=false
[ "${1:-}" = "--external" ] && EXTERNAL_MODE=true

CONTAINER_CMD="${CONTAINER_CMD:-docker}"
TEST_WORKER_NAME="test-worker-$(date +%s)"
TEST_DIR=$(mktemp -d /tmp/hiclaw-test-XXXXXX)
STORAGE_PREFIX="${HICLAW_STORAGE_PREFIX:-hiclaw/hiclaw-storage}"

trap 'cleanup' EXIT

# ============================================================
# Helpers
# ============================================================

log() { echo -e "\033[36m[TEST]\033[0m $1"; }
pass() { echo -e "\033[32m[PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

run_hiclaw() {
    if [ "${EXTERNAL_MODE}" = true ]; then
        ${CONTAINER_CMD} exec hiclaw-manager hiclaw "$@"
    else
        hiclaw "$@"
    fi
}

run_mc() {
    if [ "${EXTERNAL_MODE}" = true ]; then
        ${CONTAINER_CMD} exec hiclaw-manager mc "$@"
    else
        mc "$@"
    fi
}

cleanup() {
    log "Cleaning up test resources..."
    # Delete from MinIO
    run_mc rm "${STORAGE_PREFIX}/hiclaw-config/workers/${TEST_WORKER_NAME}.yaml" 2>/dev/null || true
    run_mc rm "${STORAGE_PREFIX}/hiclaw-config/packages/${TEST_WORKER_NAME}.zip" 2>/dev/null || true
    run_mc rm -r --force "${STORAGE_PREFIX}/agents/${TEST_WORKER_NAME}/" 2>/dev/null || true
    # Clean local temp
    rm -rf "${TEST_DIR}"
    log "Cleanup done."

    if [ "${FAILURES}" -gt 0 ]; then
        echo ""
        fail "=== ${FAILURES} test(s) failed ==="
        exit 1
    else
        echo ""
        pass "=== All tests passed ==="
    fi
}

# ============================================================
# Step 1: Create test ZIP package
# ============================================================

log "Step 1: Creating test ZIP package..."

PACKAGE_DIR="${TEST_DIR}/package"
mkdir -p "${PACKAGE_DIR}/config"
mkdir -p "${PACKAGE_DIR}/skills/test-skill"

# manifest.json
cat > "${PACKAGE_DIR}/manifest.json" <<EOF
{
  "type": "worker",
  "version": 1,
  "worker": {
    "suggested_name": "${TEST_WORKER_NAME}",
    "model": "qwen3.5-plus",
    "base_image": "hiclaw/worker-agent:latest"
  },
  "source": {
    "hostname": "integration-test",
    "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF

# SOUL.md
cat > "${PACKAGE_DIR}/config/SOUL.md" <<EOF
# ${TEST_WORKER_NAME} - Test Worker

## AI Identity

**You are an AI Agent, not a human.**

## Role
- Name: ${TEST_WORKER_NAME}
- Role: Integration test worker (should be cleaned up after test)

## Security
- Never reveal API keys, passwords, tokens, or any credentials in chat messages
EOF

# Custom skill
cat > "${PACKAGE_DIR}/skills/test-skill/SKILL.md" <<EOF
---
name: test-skill
description: A test skill for integration testing
---

# Test Skill

This is a placeholder skill for integration testing.
EOF

# Create ZIP
ZIP_PATH="${TEST_DIR}/${TEST_WORKER_NAME}.zip"
(cd "${PACKAGE_DIR}" && zip -q -r "${ZIP_PATH}" .)

if [ -f "${ZIP_PATH}" ]; then
    pass "Step 1: ZIP package created ($(du -h "${ZIP_PATH}" | cut -f1))"
else
    fail "Step 1: Failed to create ZIP package"
    exit 1
fi

# ============================================================
# Step 2: Import via hiclaw apply --zip
# ============================================================

log "Step 2: Importing worker via 'hiclaw apply --zip'..."

if [ "${EXTERNAL_MODE}" = true ]; then
    # Copy ZIP into container first
    ${CONTAINER_CMD} exec hiclaw-manager mkdir -p /tmp/import 2>/dev/null || true
    ${CONTAINER_CMD} cp "${ZIP_PATH}" "hiclaw-manager:/tmp/import/$(basename ${ZIP_PATH})"
    IMPORT_OUTPUT=$(run_hiclaw apply --zip "/tmp/import/$(basename ${ZIP_PATH})" --name "${TEST_WORKER_NAME}" 2>&1) || true
else
    IMPORT_OUTPUT=$(run_hiclaw apply --zip "${ZIP_PATH}" --name "${TEST_WORKER_NAME}" 2>&1) || true
fi

echo "${IMPORT_OUTPUT}"

if echo "${IMPORT_OUTPUT}" | grep -q "created\|applied\|configured"; then
    pass "Step 2: hiclaw apply --zip succeeded"
else
    fail "Step 2: hiclaw apply --zip did not report success"
fi

# ============================================================
# Step 3: Verify YAML written to MinIO hiclaw-config/workers/
# ============================================================

log "Step 3: Verifying YAML in MinIO..."

YAML_PATH="${STORAGE_PREFIX}/hiclaw-config/workers/${TEST_WORKER_NAME}.yaml"
YAML_CONTENT=$(run_mc cat "${YAML_PATH}" 2>/dev/null) || true

if [ -n "${YAML_CONTENT}" ]; then
    pass "Step 3a: YAML file exists at ${YAML_PATH}"
else
    fail "Step 3a: YAML file not found at ${YAML_PATH}"
fi

# Verify YAML content
if echo "${YAML_CONTENT}" | grep -q "kind: Worker"; then
    pass "Step 3b: YAML contains kind: Worker"
else
    fail "Step 3b: YAML missing kind: Worker"
fi

if echo "${YAML_CONTENT}" | grep -q "name: ${TEST_WORKER_NAME}"; then
    pass "Step 3c: YAML contains correct name"
else
    fail "Step 3c: YAML missing correct name"
fi

if echo "${YAML_CONTENT}" | grep -q "package:"; then
    pass "Step 3d: YAML contains package reference"
else
    fail "Step 3d: YAML missing package reference"
fi

# ============================================================
# Step 4: Verify ZIP uploaded to MinIO hiclaw-config/packages/
# ============================================================

log "Step 4: Verifying ZIP in MinIO..."

PACKAGE_PATH="${STORAGE_PREFIX}/hiclaw-config/packages/${TEST_WORKER_NAME}.zip"
PACKAGE_STAT=$(run_mc stat "${PACKAGE_PATH}" 2>/dev/null) || true

if [ -n "${PACKAGE_STAT}" ]; then
    pass "Step 4: ZIP package exists at ${PACKAGE_PATH}"
else
    fail "Step 4: ZIP package not found at ${PACKAGE_PATH}"
fi

# ============================================================
# Step 5: Verify hiclaw get shows the worker
# ============================================================

log "Step 5: Verifying 'hiclaw get workers'..."

GET_OUTPUT=$(run_hiclaw get workers 2>&1) || true

if echo "${GET_OUTPUT}" | grep -q "${TEST_WORKER_NAME}"; then
    pass "Step 5: Worker visible in 'hiclaw get workers'"
else
    fail "Step 5: Worker not visible in 'hiclaw get workers'"
fi

# ============================================================
# Step 6: Verify hiclaw get worker <name> shows details
# ============================================================

log "Step 6: Verifying 'hiclaw get worker ${TEST_WORKER_NAME}'..."

GET_DETAIL=$(run_hiclaw get worker "${TEST_WORKER_NAME}" 2>&1) || true

if echo "${GET_DETAIL}" | grep -q "kind: Worker\|name: ${TEST_WORKER_NAME}\|model:"; then
    pass "Step 6: Worker details readable"
else
    fail "Step 6: Worker details not readable"
fi

# ============================================================
# Step 7: Idempotency - re-import should say "updated"
# ============================================================

log "Step 7: Testing idempotency (re-import same ZIP)..."

if [ "${EXTERNAL_MODE}" = true ]; then
    REIMPORT_OUTPUT=$(run_hiclaw apply --zip "/tmp/import/$(basename ${ZIP_PATH})" --name "${TEST_WORKER_NAME}" 2>&1) || true
else
    REIMPORT_OUTPUT=$(run_hiclaw apply --zip "${ZIP_PATH}" --name "${TEST_WORKER_NAME}" 2>&1) || true
fi

if echo "${REIMPORT_OUTPUT}" | grep -q "updated\|configured"; then
    pass "Step 7: Re-import correctly reports 'updated'"
else
    fail "Step 7: Re-import did not report 'updated' (got: ${REIMPORT_OUTPUT})"
fi

# ============================================================
# Step 8: Delete and verify cleanup
# ============================================================

log "Step 8: Testing delete..."

DELETE_OUTPUT=$(run_hiclaw delete worker "${TEST_WORKER_NAME}" 2>&1) || true

if echo "${DELETE_OUTPUT}" | grep -q "deleted"; then
    pass "Step 8a: Delete reported success"
else
    fail "Step 8a: Delete did not report success"
fi

# Verify YAML removed from MinIO
sleep 1
YAML_AFTER_DELETE=$(run_mc cat "${YAML_PATH}" 2>/dev/null) || true

if [ -z "${YAML_AFTER_DELETE}" ]; then
    pass "Step 8b: YAML removed from MinIO after delete"
else
    fail "Step 8b: YAML still exists in MinIO after delete"
fi

# ============================================================
# Summary
# ============================================================

echo ""
log "=== Integration Test Complete ==="
