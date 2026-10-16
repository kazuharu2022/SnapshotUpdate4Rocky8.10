#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/apply-rocky8.8-to-8.10-installroot.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

sed -n '/^validate_preinstalled_drift()/,/^}/p' "${SCRIPT}" \
    > "${TEST_ROOT}/validator.sh"
source "${TEST_ROOT}/validator.sh"

BASELINE="${TEST_ROOT}/baseline.txt"
CURRENT="${TEST_ROOT}/current.txt"
ARCHIVE="${TEST_ROOT}/archive.txt"
ARCHIVE_HEADERS="${TEST_ROOT}/archive-headers.txt"
CURRENT_HEADERS="${TEST_ROOT}/current-headers.txt"

printf '%s\n' \
    $'rocky-release\t0:8.8-1.8.el8\tx86_64' \
    > "${BASELINE}"
printf '%s\n' \
    $'rocky-release\t0:8.10-1.10.el8\tx86_64' \
    > "${CURRENT}"
cp "${CURRENT}" "${ARCHIVE}"
printf '%s\n' \
    $'rocky-release\t0:8.10-1.10.el8\tx86_64\tabc123' \
    > "${ARCHIVE_HEADERS}"
cp "${ARCHIVE_HEADERS}" "${CURRENT_HEADERS}"

if ! validate_preinstalled_drift \
    "${BASELINE}" "${CURRENT}" "${ARCHIVE}" \
    "${ARCHIVE_HEADERS}" "${CURRENT_HEADERS}" "${TEST_ROOT}" archive; then
    echo "FAIL: 保存済みRPMと一致する8.10先行適用分を拒否しました。" >&2
    exit 1
fi

if validate_preinstalled_drift \
    "${BASELINE}" "${CURRENT}" "${ARCHIVE}" \
    "${ARCHIVE_HEADERS}" "${CURRENT_HEADERS}" "${TEST_ROOT}" kernel \
    > /dev/null 2>&1; then
    echo "FAIL: 8.8向けkernel限定条件がrocky-release差分を許可しました。" >&2
    exit 1
fi

printf '%s\n' \
    $'rocky-release\t0:8.10-1.10.el8\tx86_64\tdifferent' \
    > "${CURRENT_HEADERS}"
if validate_preinstalled_drift \
    "${BASELINE}" "${CURRENT}" "${ARCHIVE}" \
    "${ARCHIVE_HEADERS}" "${CURRENT_HEADERS}" "${TEST_ROOT}" archive \
    > /dev/null 2>&1; then
    echo "FAIL: 不変ヘッダーIDが異なる8.10パッケージを許可しました。" >&2
    exit 1
fi

printf '%s\n' \
    $'rocky-release\t0:8.10-1.10.el8\tx86_64' \
    $'unrelated\t0:1.0-1.el8\tx86_64' \
    | LC_ALL=C sort > "${CURRENT}"
printf '%s\n' \
    $'rocky-release\t0:8.10-1.10.el8\tx86_64\tabc123' \
    $'unrelated\t0:1.0-1.el8\tx86_64\tdef456' \
    | LC_ALL=C sort > "${CURRENT_HEADERS}"
if validate_preinstalled_drift \
    "${BASELINE}" "${CURRENT}" "${ARCHIVE}" \
    "${ARCHIVE_HEADERS}" "${CURRENT_HEADERS}" "${TEST_ROOT}" archive \
    > /dev/null 2>&1; then
    echo "FAIL: 保存済みRPMにない追加パッケージを許可しました。" >&2
    exit 1
fi

echo "PASS: installroot drift validator"
