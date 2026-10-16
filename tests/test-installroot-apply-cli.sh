#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/apply-rocky8.8-to-8.10-installroot.sh"
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

assert_status 2 "${TEST_ROOT}/missing-all.log" "${SCRIPT}"
grep -Fq '使用方法:' "${TEST_ROOT}/missing-all.log"

assert_status 2 "${TEST_ROOT}/missing-value.log" "${SCRIPT}" --installroot
grep -Fq '絶対パスが必要' "${TEST_ROOT}/missing-value.log"

assert_status 2 "${TEST_ROOT}/empty-value.log" "${SCRIPT}" --installroot=
grep -Fq '絶対パスが必要' "${TEST_ROOT}/empty-value.log"

assert_status 2 "${TEST_ROOT}/duplicate.log" \
    "${SCRIPT}" \
    --installroot /srv/pxe/root-a \
    --installroot /srv/pxe/root-b \
    snapshot.tar
grep -Fq '1回だけ指定' "${TEST_ROOT}/duplicate.log"

assert_status 2 "${TEST_ROOT}/multiple-archives.log" \
    "${SCRIPT}" \
    --installroot /srv/pxe/root \
    first.tar second.tar
grep -Fq 'アーカイブは1つだけ' "${TEST_ROOT}/multiple-archives.log"

assert_status 2 "${TEST_ROOT}/unknown.log" "${SCRIPT}" --unknown
grep -Fq '不明な引数' "${TEST_ROOT}/unknown.log"

grep -Fq -- '"--installroot=${INSTALLROOT}"' "${SCRIPT}"
grep -Fq -- '"--releasever=${TARGET_VERSION}"' "${SCRIPT}"
grep -Fq -- '"--noplugins"' "${SCRIPT}"
grep -Fq -- 'install "${RPM_FILES[@]}"' "${SCRIPT}"
grep -Fq -- '"${INSTALLROOT}/boot/vmlinuz-' "${SCRIPT}"
grep -Fq -- '"${INSTALLROOT}/boot/initramfs-' "${SCRIPT}"
grep -Fq -- 'chroot "${INSTALLROOT}" /bin/cat /etc/os-release' "${SCRIPT}"
grep -Fq -- 'validate_installroot_release "更新前" "${SOURCE_VERSION}" "${TARGET_VERSION}"' "${SCRIPT}"
grep -Fq -- 'validate_installroot_release "適用後" "${TARGET_VERSION}"' "${SCRIPT}"
grep -Fq -- 'ALLOWED_DRIFT_SCOPE="archive"' "${SCRIPT}"

if grep -Fq -- 'grep -Eq' "${SCRIPT}" \
    && grep -Fq -- '"${INSTALLROOT}/etc/rocky-release"' "${SCRIPT}"; then
    echo "FAIL: installrootのOS判定がchroot外のrocky-releaseを参照しています。" >&2
    exit 1
fi

echo "PASS: installroot apply CLI and static contract"
