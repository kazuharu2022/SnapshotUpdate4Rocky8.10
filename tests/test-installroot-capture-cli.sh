#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/capture-rocky8.10-installroot-snapshot.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

assert_status()
{
    local expected_status="$1"
    local output_file="$2"
    shift 2
    local actual_status

    set +e
    "$@" > "${output_file}" 2>&1
    actual_status=$?
    set -e

    if [[ "${actual_status}" -ne "${expected_status}" ]]; then
        echo "FAIL: 終了コードが不正です。expected=${expected_status} actual=${actual_status}" >&2
        sed -n '1,120p' "${output_file}" >&2
        return 1
    fi
}

bash -n "${SCRIPT}"

assert_status 0 "${TEST_ROOT}/help.log" "${SCRIPT}" --help
grep -Fq -- '--installroot PATH' "${TEST_ROOT}/help.log"
grep -Fq -- '--disablerepo REPOID' "${TEST_ROOT}/help.log"

assert_status 2 "${TEST_ROOT}/missing-root.log" "${SCRIPT}"
grep -Fq '使用方法:' "${TEST_ROOT}/missing-root.log"

assert_status 2 "${TEST_ROOT}/missing-value.log" "${SCRIPT}" --installroot
grep -Fq '絶対パスが必要' "${TEST_ROOT}/missing-value.log"

assert_status 2 "${TEST_ROOT}/duplicate.log" \
    "${SCRIPT}" \
    --installroot /srv/pxe/root-a \
    --installroot /srv/pxe/root-b
grep -Fq '1回だけ指定' "${TEST_ROOT}/duplicate.log"

assert_status 2 "${TEST_ROOT}/missing-repo.log" \
    "${SCRIPT}" --installroot /srv/pxe/root --disablerepo
grep -Fq 'リポジトリIDが必要' "${TEST_ROOT}/missing-repo.log"

assert_status 2 "${TEST_ROOT}/empty-repo.log" \
    "${SCRIPT}" --installroot /srv/pxe/root --disablerepo=
grep -Fq 'リポジトリIDが必要' "${TEST_ROOT}/empty-repo.log"

assert_status 2 "${TEST_ROOT}/unknown.log" "${SCRIPT}" --unknown
grep -Fq '不明な引数' "${TEST_ROOT}/unknown.log"

grep -Fq -- '"--installroot=${INSTALLROOT}"' "${SCRIPT}"
grep -Fq -- '"--releasever=${TARGET_VERSION}"' "${SCRIPT}"
grep -Fq -- '"--setopt=reposdir=${REPO_DIR}"' "${SCRIPT}"
grep -Fq -- 'DNF_ARGS+=("--disablerepo=${disabled_repository}")' "${SCRIPT}"
grep -Fq -- 'installed-baseline-for-apply.txt' "${SCRIPT}"
grep -Fq -- 'rpm --dbpath "${SIGNATURE_DB}" --checksig' "${SCRIPT}"
grep -Fq -- "'snapshot_format=2'" "${SCRIPT}"
grep -Fq -- "'snapshot_kind=rocky-installroot-update'" "${SCRIPT}"

echo "PASS: installroot capture CLI and static contract"
