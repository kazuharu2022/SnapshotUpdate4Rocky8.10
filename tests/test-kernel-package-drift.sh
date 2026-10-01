#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

OLD_KERNEL=$'kernel-core\t0:4.18.0-477.el8_8.1\tx86_64'
NEW_KERNEL=$'kernel-core\t0:4.18.0-553.el8_10.1\tx86_64'
NEW_KERNEL_MODULES=$'kernel-modules\t0:4.18.0-553.el8_10.1\tx86_64'
OTHER_KERNEL=$'kernel-core\t0:4.18.0-999.el8_10.1\tx86_64'
BASE_PACKAGE=$'bash\t0:4.4.20-4.el8\tx86_64'
NEW_BASE_PACKAGE=$'bash\t0:4.4.20-5.el8\tx86_64'
KERNEL_HEADER="1111111111111111111111111111111111111111"
WRONG_HEADER="2222222222222222222222222222222222222222"

write_sorted()
{
    local output="$1"
    shift
    printf '%s\n' "$@" | LC_ALL=C sort > "${output}"
}

load_guard()
{
    local script="$1"
    local guard_file="$2"
    # 本体の純粋な差分判定関数だけを読み込み、OSやroot状態に依存せず試験する。
    sed -n '/^validate_preinstalled_kernel_drift()/,/^}/p' "${script}" \
        > "${guard_file}"
    source "${guard_file}"
}

prepare_case()
{
    local case_dir="$1"
    mkdir -p "${case_dir}"
    write_sorted "${case_dir}/baseline" "${OLD_KERNEL}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/archive-manifest" \
        "${NEW_KERNEL}" "${NEW_KERNEL_MODULES}" "${NEW_BASE_PACKAGE}"
    write_sorted "${case_dir}/archive-headers" \
        "${NEW_KERNEL}"$'\t'"${KERNEL_HEADER}" \
        "${NEW_KERNEL_MODULES}"$'\t'"${KERNEL_HEADER}" \
        "${NEW_BASE_PACKAGE}"$'\t'"${KERNEL_HEADER}"
}

guard_accepts()
{
    local case_dir="$1"
    validate_preinstalled_kernel_drift \
        "${case_dir}/baseline" \
        "${case_dir}/current" \
        "${case_dir}/archive-manifest" \
        "${case_dir}/archive-headers" \
        "${case_dir}/current-headers" \
        "${case_dir}"
}

run_cases()
{
    local script="$1"
    local suite="$2"
    local case_dir

    load_guard "${script}" "${TEST_ROOT}/${suite}-guard.sh"

    case_dir="${TEST_ROOT}/${suite}-add-exact"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${OLD_KERNEL}" "${NEW_KERNEL}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" "${NEW_KERNEL}"$'\t'"${KERNEL_HEADER}"
    guard_accepts "${case_dir}"

    case_dir="${TEST_ROOT}/${suite}-add-kernel-set"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" \
        "${OLD_KERNEL}" "${NEW_KERNEL}" "${NEW_KERNEL_MODULES}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" \
        "${NEW_KERNEL}"$'\t'"${KERNEL_HEADER}" \
        "${NEW_KERNEL_MODULES}"$'\t'"${KERNEL_HEADER}"
    guard_accepts "${case_dir}"

    case_dir="${TEST_ROOT}/${suite}-replace-exact"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${NEW_KERNEL}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" "${NEW_KERNEL}"$'\t'"${KERNEL_HEADER}"
    guard_accepts "${case_dir}"

    case_dir="${TEST_ROOT}/${suite}-wrong-header"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${OLD_KERNEL}" "${NEW_KERNEL}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" "${NEW_KERNEL}"$'\t'"${WRONG_HEADER}"
    if guard_accepts "${case_dir}" 2>/dev/null; then
        echo "FAIL: 不変ヘッダーID不一致を許可しました: ${suite}" >&2
        return 1
    fi

    case_dir="${TEST_ROOT}/${suite}-not-saved"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${OLD_KERNEL}" "${OTHER_KERNEL}" "${BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" "${OTHER_KERNEL}"$'\t'"${KERNEL_HEADER}"
    if guard_accepts "${case_dir}" 2>/dev/null; then
        echo "FAIL: 保存されていないkernelを許可しました: ${suite}" >&2
        return 1
    fi

    case_dir="${TEST_ROOT}/${suite}-non-kernel"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${OLD_KERNEL}" "${NEW_BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" "${NEW_BASE_PACKAGE}"$'\t'"${KERNEL_HEADER}"
    if guard_accepts "${case_dir}" 2>/dev/null; then
        echo "FAIL: kernel以外の更新を許可しました: ${suite}" >&2
        return 1
    fi

    case_dir="${TEST_ROOT}/${suite}-mixed-drift"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" \
        "${OLD_KERNEL}" "${NEW_KERNEL}" "${NEW_BASE_PACKAGE}"
    write_sorted "${case_dir}/current-headers" \
        "${NEW_KERNEL}"$'\t'"${KERNEL_HEADER}" \
        "${NEW_BASE_PACKAGE}"$'\t'"${KERNEL_HEADER}"
    if guard_accepts "${case_dir}" 2>/dev/null; then
        echo "FAIL: kernelとkernel以外の混在差分を許可しました: ${suite}" >&2
        return 1
    fi

    case_dir="${TEST_ROOT}/${suite}-removal-only"
    prepare_case "${case_dir}"
    write_sorted "${case_dir}/current" "${BASE_PACKAGE}"
    : > "${case_dir}/current-headers"
    if guard_accepts "${case_dir}" 2>/dev/null; then
        echo "FAIL: kernelの削除だけを許可しました: ${suite}" >&2
        return 1
    fi

    echo "PASS: ${suite}"
}

run_cases \
    "${REPO_ROOT}/apply-rocky8.8-to-8.10-snapshot.sh" \
    "rocky"
run_cases \
    "${REPO_ROOT}/apply-rhel8.8-to-8.10-snapshot.sh" \
    "rhel"
