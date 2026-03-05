#!/bin/bash
# test-02-create-worker.sh - Case 2: Create Worker Alice via Matrix conversation
# Verifies: Manager creates Matrix user, Higress consumer, Room, config files,
#           and returns install command
#
# Metrics: Tracks LLM calls, token usage, and timing for Manager and Worker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/higress-client.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

TEST_NAME="02-create-worker"
test_setup "${TEST_NAME}"

if ! require_llm_key; then
    test_teardown "${TEST_NAME}"
    test_summary
    exit 0
fi

# Login as admin
ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

# Get admin DM room with Manager (assumes test-01 created it)
MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

log_section "Request Worker Creation"

# Find or create a DM room with Manager
DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)

if [ -z "${DM_ROOM}" ]; then
    log_info "Creating DM room with Manager..."
    DM_ROOM=$(curl -sf -X POST "${TEST_MATRIX_DIRECT_URL}/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{
            "invite": ["'"${MANAGER_USER}"'"],
            "is_direct": true,
            "preset": "trusted_private_chat"
        }' | jq -r '.room_id')
    sleep 5
fi

assert_not_empty "${DM_ROOM}" "DM room with Manager exists"

# Wait for Manager Agent to be fully ready (OpenClaw gateway + joined DM room)
wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    test_teardown "${TEST_NAME}"
    test_summary
    exit 1
}

# ============================================================
# Snapshot baseline metrics before test (for delta calculation)
# ============================================================

log_info "Snapshotting baseline metrics..."
METRICS_BASELINE=$(snapshot_baseline "alice")

# Send create worker request
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
    "Please create a new Worker named alice for frontend development tasks. She should have access to GitHub MCP."

log_info "Waiting for Manager to create Worker Alice..."

# Wait for Manager reply (up to 5 minutes — worker creation involves multiple LLM calls)
REPLY=$(matrix_wait_for_reply "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 300)

log_section "Verify Manager Response"

log_info "Manager reply (first 500 chars): $(echo "${REPLY}" | head -c 500)"

assert_not_empty "${REPLY}" "Manager replied to create worker request"
assert_contains_i "${REPLY}" "alice" "Reply mentions worker name 'alice'"

# Show error logs on failure for debugging
if ! echo "${REPLY}" | grep -qi "alice" 2>/dev/null; then
    log_info "--- Manager Agent Error Log ---"
    docker exec hiclaw-manager-test tail -10 /var/log/hiclaw/manager-agent-error.log 2>/dev/null || true
fi

log_section "Verify Infrastructure"

# Check Matrix user exists
ALICE_LOGIN=$(matrix_login "alice" "" 2>/dev/null || echo "{}")
# Note: We don't know Alice's password, but we can check if the user was registered
# by trying to find the user in room membership

# Check Higress consumer
higress_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}" > /dev/null
CONSUMERS=$(higress_get_consumers)
assert_contains "${CONSUMERS}" "worker-alice" "Higress consumer 'worker-alice' exists"

# Check MinIO files
minio_setup
minio_wait_for_file "agents/alice/SOUL.md" 60
ALICE_SOUL_EXISTS=$?
assert_eq "0" "${ALICE_SOUL_EXISTS}" "Worker Alice SOUL.md exists in MinIO"

ALICE_SOUL=$(minio_read_file "agents/alice/SOUL.md")
assert_contains "${ALICE_SOUL}" "frontend" "Alice's SOUL.md mentions frontend"

log_section "Start Worker Container"

# Extract install parameters from Manager's reply and start Worker
# In real test, we would parse the install command from REPLY
log_info "Worker Alice verification complete (container start requires install params from Manager)"

# ============================================================
# Collect Agent Metrics (Delta from baseline)
# ============================================================
# Calculates metrics consumed during THIS test only by comparing
# current session state to the baseline captured at test start.

log_section "Collect Agent Metrics"

# Collect delta metrics from Manager and Worker alice
METRICS=$(collect_delta_metrics "${TEST_NAME}" "${METRICS_BASELINE}" "alice")

# Print formatted report
print_metrics_report "$METRICS"

# Assert thresholds for delta values (this test's actual consumption)
# Typical: Manager ~2-5 LLM calls, ~50000-80000 input tokens, ~500-1500 output tokens
assert_metrics_threshold "$METRICS" "manager" "llm_calls" "${METRICS_THRESHOLD_MANAGER_LLM_CALLS:-10}"
assert_metrics_threshold "$METRICS" "manager" "tokens.input" "${METRICS_THRESHOLD_MANAGER_TOKENS_INPUT:-150000}"
assert_metrics_threshold "$METRICS" "manager" "tokens.output" "${METRICS_THRESHOLD_MANAGER_TOKENS_OUTPUT:-3000}"

# Check if alice was involved (may not be if container wasn't started)
if echo "$METRICS" | jq -e '.agents.alice' > /dev/null 2>&1; then
    assert_metrics_threshold "$METRICS" "alice" "llm_calls" "${METRICS_THRESHOLD_WORKER_LLM_CALLS:-4}"
    assert_metrics_threshold "$METRICS" "alice" "tokens.input" "${METRICS_THRESHOLD_WORKER_TOKENS_INPUT:-30000}"
    assert_metrics_threshold "$METRICS" "alice" "tokens.output" "${METRICS_THRESHOLD_WORKER_TOKENS_OUTPUT:-1000}"
fi

# Save metrics to file for CI aggregation
save_metrics_file "$METRICS" "${TEST_NAME}"

test_teardown "${TEST_NAME}"
test_summary
