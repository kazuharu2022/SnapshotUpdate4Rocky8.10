#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

load_parser()
{
    local script="$1"
    local parser_file="$2"

    sed -n '/^signature_log_has_failure()/,/^}/p' "${script}" \
        > "${parser_file}"
    source "${parser_file}"
}

assert_clean()
{
    local log_file="$1"
    local label="$2"

    if signature_log_has_failure "${log_file}"; then
        echo "FAIL: 正常ログを署名失敗と判定しました: ${label}" >&2
        return 1
    fi
}

assert_failure()
{
    local log_file="$1"
    local label="$2"

    if ! signature_log_has_failure "${log_file}"; then
        echo "FAIL: 署名失敗を検出できませんでした: ${label}" >&2
        return 1
    fi
}

run_cases()
{
    local script="$1"
    local suite="$2"
    local log_file="${TEST_ROOT}/${suite}.log"

    load_parser "${script}" "${TEST_ROOT}/${suite}-parser.sh"

    printf '%s\n' \
        '/snapshot/rpms/gstreamer1-plugins-bad-free-1.16.1.rpm: digests signatures OK' \
        '/snapshot/rpms/normal-package.rpm: digests signatures OK' \
        > "${log_file}"
    assert_clean "${log_file}" "${suite}: BADを含むRPM名"

    printf '%s\n' \
        '/snapshot/rpms/kernel-core.rpm: digests signatures NOKEY' \
        > "${log_file}"
    assert_failure "${log_file}" "${suite}: NOKEY"

    printf '%s\n' \
        '/snapshot/rpms/kernel-core.rpm: digests signatures NOT OK' \
        > "${log_file}"
    assert_failure "${log_file}" "${suite}: NOT OK"

    printf '%s\n' \
        '/snapshot/rpms/kernel-core.rpm: Header RSA signature: BAD' \
        > "${log_file}"
    assert_failure "${log_file}" "${suite}: BAD"

    printf '%s\n' \
        '/snapshot/rpms/kernel-core.rpm: Header RSA signature: NOTTRUSTED' \
        > "${log_file}"
    assert_failure "${log_file}" "${suite}: NOTTRUSTED"

    echo "PASS: ${suite}"
}

run_cases \
    "${REPO_ROOT}/apply-rocky8.8-to-8.10-snapshot.sh" \
    "apply-rocky"
run_cases \
    "${REPO_ROOT}/apply-rhel8.8-to-8.10-snapshot.sh" \
    "apply-rhel"
run_cases \
    "${REPO_ROOT}/capture-rhel8.8-to-8.10-snapshot.sh" \
    "capture-rhel"
