#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/apply-rocky8.8-to-8.10-installroot.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

sed -n '/^os_release_value()/,/^}/p' "${SCRIPT}" \
    > "${TEST_ROOT}/release-functions.sh"
sed -n '/^validate_installroot_release()/,/^}/p' "${SCRIPT}" \
    >> "${TEST_ROOT}/release-functions.sh"
source "${TEST_ROOT}/release-functions.sh"

INSTALLROOT="/mock-installroot"
MOCK_OS_RELEASE=""
MOCK_RPM_VERSION="8.10"
MOCK_CHROOT_FAILURE=0

chroot()
{
    if [[ "${MOCK_CHROOT_FAILURE}" -eq 1 ]]; then
        return 1
    fi
    printf '%s\n' "${MOCK_OS_RELEASE}"
}

rpm()
{
    printf '%s\n' "${MOCK_RPM_VERSION}"
}

MOCK_OS_RELEASE=$'NAME="Rocky Linux"\nVERSION_ID="8.10"'
validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/missing-id.log" 2>&1
grep -Fq 'IDがありません' "${TEST_ROOT}/missing-id.log"
[[ "${INSTALLROOT_EFFECTIVE_VERSION}" == "8.10" ]]

MOCK_OS_RELEASE=$'ID="rocky"\nVERSION_ID="8.10"'
validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/complete.log" 2>&1
[[ ! -s "${TEST_ROOT}/complete.log" ]]

MOCK_CHROOT_FAILURE=1
validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/missing-file.log" 2>&1
grep -Fq 'rocky-releaseで判定します' "${TEST_ROOT}/missing-file.log"
MOCK_CHROOT_FAILURE=0

MOCK_OS_RELEASE=$'ID="rhel"\nVERSION_ID="8.10"'
if validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/wrong-id.log" 2>&1; then
    echo "FAIL: Rocky以外のIDを許可しました。" >&2
    exit 1
fi

MOCK_OS_RELEASE=$'ID="rocky"\nVERSION_ID="8.8"'
if validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/version-mismatch.log" 2>&1; then
    echo "FAIL: os-releaseとrocky-release RPMのバージョン不一致を許可しました。" >&2
    exit 1
fi

MOCK_OS_RELEASE=$'ID="rocky"\nVERSION_ID="8.10"'
MOCK_RPM_VERSION="8.7"
if validate_installroot_release "テスト" "8.8" "8.10" \
    > "${TEST_ROOT}/unsupported-version.log" 2>&1; then
    echo "FAIL: 対象外のrocky-release RPMを許可しました。" >&2
    exit 1
fi

echo "PASS: installroot release detection"
