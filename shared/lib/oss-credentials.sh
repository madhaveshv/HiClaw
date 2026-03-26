#!/bin/bash
# oss-credentials.sh - STS credential management for mc (MinIO Client)
#
# Workers obtain STS temporary credentials from the orchestrator service.
# The orchestrator holds OIDC credentials and issues per-worker scoped tokens.
# STS tokens expire after 1 hour. This library provides lazy-refresh: credentials
# are cached in a file and refreshed only when they are about to expire.
#
# Required env vars (set by orchestrator at worker creation):
#   HICLAW_ORCHESTRATOR_URL   - orchestrator HTTP endpoint (e.g. http://hiclaw-orchestrator:2375)
#   HICLAW_WORKER_API_KEY     - per-worker API key for authentication
#
# Usage:
#   source /opt/hiclaw/scripts/lib/oss-credentials.sh
#   ensure_mc_credentials   # call before any mc command
#   mc mirror ...
#
# In local mode (no HICLAW_ORCHESTRATOR_URL), ensure_mc_credentials is a no-op.

_OSS_CRED_FILE="/tmp/mc-oss-credentials.env"
_OSS_CRED_REFRESH_MARGIN=600  # refresh if less than 10 minutes remaining

# Internal: call orchestrator STS endpoint and write credentials to file
_oss_refresh_sts_via_orchestrator() {
    local resp http_code
    local sts_ak sts_sk sts_token oss_endpoint oss_bucket region

    resp=$(curl -s -w "\n%{http_code}" -X POST "${HICLAW_ORCHESTRATOR_URL}/credentials/sts" \
        -H "Authorization: Bearer ${HICLAW_WORKER_API_KEY}" \
        --connect-timeout 10 --max-time 30 2>&1)

    http_code=$(echo "${resp}" | tail -1)
    resp=$(echo "${resp}" | sed '$d')

    if [ "${http_code}" != "200" ]; then
        echo "[oss-credentials] ERROR: orchestrator STS request failed (HTTP ${http_code})" >&2
        echo "[oss-credentials] Response: ${resp}" >&2
        return 1
    fi

    sts_ak=$(echo "${resp}" | jq -r '.access_key_id')
    sts_sk=$(echo "${resp}" | jq -r '.access_key_secret')
    sts_token=$(echo "${resp}" | jq -r '.security_token')
    oss_endpoint=$(echo "${resp}" | jq -r '.oss_endpoint')
    oss_bucket=$(echo "${resp}" | jq -r '.oss_bucket')

    if [ -z "${sts_ak}" ] || [ "${sts_ak}" = "null" ]; then
        echo "[oss-credentials] ERROR: Failed to parse STS credentials from orchestrator" >&2
        echo "[oss-credentials] Response: ${resp}" >&2
        return 1
    fi

    # expires_at = now + 3600 seconds (STS token lifetime)
    local expires_at
    expires_at=$(( $(date +%s) + 3600 ))

    cat > "${_OSS_CRED_FILE}" <<EOF
MC_HOST_hiclaw="https://${sts_ak}:${sts_sk}:${sts_token}@${oss_endpoint}"
_OSS_CRED_EXPIRES_AT=${expires_at}
EOF
    chmod 600 "${_OSS_CRED_FILE}"

    echo "[oss-credentials] STS credentials refreshed via orchestrator (AK prefix: ${sts_ak:0:8}..., expires: $(date -d @${expires_at} '+%H:%M:%S' 2>/dev/null || date -r ${expires_at} '+%H:%M:%S' 2>/dev/null || echo ${expires_at}))" >&2
}

# Public: ensure MC_HOST_hiclaw is set with valid (non-expired) STS credentials.
# In local mode (no HICLAW_ORCHESTRATOR_URL), this is a no-op.
ensure_mc_credentials() {
    # Skip in local mode — mc alias is configured with static credentials
    if [ -z "${HICLAW_ORCHESTRATOR_URL:-}" ]; then
        return 0
    fi

    local now needs_refresh=false
    now=$(date +%s)

    if [ -f "${_OSS_CRED_FILE}" ]; then
        # Source to get _OSS_CRED_EXPIRES_AT
        . "${_OSS_CRED_FILE}"
        if [ -z "${_OSS_CRED_EXPIRES_AT:-}" ] || [ $(( _OSS_CRED_EXPIRES_AT - now )) -lt ${_OSS_CRED_REFRESH_MARGIN} ]; then
            needs_refresh=true
        fi
    else
        needs_refresh=true
    fi

    if [ "${needs_refresh}" = true ]; then
        _oss_refresh_sts_via_orchestrator || return 1
        . "${_OSS_CRED_FILE}"
    fi

    export MC_HOST_hiclaw
}
