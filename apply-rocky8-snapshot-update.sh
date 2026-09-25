#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: rootで実行してください。"
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "使用方法:"
    echo "  $0 /path/to/rocky8.10-update-YYYYMMDDTHHMMSS+0900.tar"
    exit 1
fi

if [[ ! -f "$1" ]]; then
    echo "ERROR: アーカイブが見つかりません: $1"
    exit 1
fi

ARCHIVE="$(readlink -f -- "$1")"
ARCHIVE_DIR="$(dirname "${ARCHIVE}")"
ARCHIVE_NAME="$(basename "${ARCHIVE}")"
CHECKSUM_FILE="${ARCHIVE}.sha256"

if [[ ! -f "${CHECKSUM_FILE}" ]]; then
    echo "ERROR: チェックサムファイルが見つかりません。"
    echo "${CHECKSUM_FILE}"
    exit 1
fi

echo "アーカイブのSHA-256を確認します。"

(
    cd "${ARCHIVE_DIR}"
    sha256sum -c "${ARCHIVE_NAME}.sha256"
)

APPLY_ROOT="$(mktemp -d /var/tmp/rocky8-snapshot-apply.XXXXXX)"
trap 'rm -rf -- "${APPLY_ROOT}"' EXIT

tar -xf "${ARCHIVE}" -C "${APPLY_ROOT}"

mapfile -t SNAPSHOT_DIRS < <(
    find "${APPLY_ROOT}" -mindepth 1 -maxdepth 1 -type d
)

if [[ ${#SNAPSHOT_DIRS[@]} -ne 1 ]]; then
    echo "ERROR: アーカイブのディレクトリ構成が不正です。"
    exit 1
fi

SNAPSHOT_DIR="${SNAPSHOT_DIRS[0]}"
RPM_DIR="${SNAPSHOT_DIR}/rpms"
STATE_DIR="${SNAPSHOT_DIR}/state"

echo "各RPMのSHA-256を確認します。"

(
    cd "${RPM_DIR}"
    sha256sum -c "${STATE_DIR}/SHA256SUMS"
)

package_list()
{
    rpm -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

CURRENT_STATE="${APPLY_ROOT}/installed-current.txt"
package_list > "${CURRENT_STATE}"

EXPECTED_STATE="${STATE_DIR}/installed-baseline-for-apply.txt"

if ! cmp -s "${EXPECTED_STATE}" "${CURRENT_STATE}"; then
    DIFF_LOG="/var/log/rocky8-snapshot-package-drift-$(date +%Y%m%dT%H%M%S).diff"

    diff -u "${EXPECTED_STATE}" "${CURRENT_STATE}" \
        > "${DIFF_LOG}" || true

    echo
    echo "ERROR: スナップショット取得後にパッケージ構成が変化しています。"
    echo "安全のためアップデートを中止しました。"
    echo "差分: ${DIFF_LOG}"
    echo
    sed -n '1,200p' "${DIFF_LOG}"
    exit 3
fi

mapfile -d '' -t RPM_FILES < <(
    find "${RPM_DIR}" -type f -name '*.rpm' -print0 \
        | LC_ALL=C sort -z
)

if [[ ${#RPM_FILES[@]} -eq 0 ]]; then
    echo "このスナップショットには更新RPMがありません。"
    exit 0
fi

echo
echo "適用するRPM数: ${#RPM_FILES[@]}"
echo "外部リポジトリをすべて無効化して、保存済みRPMだけを適用します。"
echo

LOG_FILE="/var/log/rocky8-snapshot-update-$(date +%Y%m%dT%H%M%S).log"

dnf \
    --disablerepo='*' \
    --disableexcludes=all \
    --best \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${LOG_FILE}"

echo
echo "RPMデータベースと依存関係を確認します。"

dnf --disablerepo='*' check

echo
echo "インストール済みkernel-core:"
rpm -q kernel-core --last 2>/dev/null || true

echo
echo "適用ログ: ${LOG_FILE}"
echo "カーネルを反映するため、確認後に再起動してください。"
