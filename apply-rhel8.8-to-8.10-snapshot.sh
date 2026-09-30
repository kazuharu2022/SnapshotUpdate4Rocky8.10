#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_VERSION="8.8"
readonly TARGET_VERSION="8.10"
readonly ARCHIVE_PREFIX="rhel8.8-to-8.10-update-"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
    die "rootで実行してください。"
fi

if [[ $# -ne 1 ]]; then
    echo "使用方法:"
    echo "  $0 /path/to/rhel8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-releaseを読み込めません。"
fi

RHEL_ID="$(
    . /etc/os-release
    printf '%s' "${ID:-}"
)"
RHEL_VERSION_ID="$(
    . /etc/os-release
    printf '%s' "${VERSION_ID:-}"
)"

if [[ "${RHEL_ID}" != "rhel" || "${RHEL_VERSION_ID}" != "${SOURCE_VERSION}" ]]; then
    echo "ERROR: 適用元がRed Hat Enterprise Linux ${SOURCE_VERSION}ではありません。" >&2
    cat /etc/redhat-release 2>/dev/null || true
    exit 1
fi

for command_name in \
    awk cat cmp date diff dnf find grep mktemp readlink rm rpm sed sha256sum sort tar tee tr
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        die "必要なコマンドが見つかりません: ${command_name}"
    fi
done

if [[ ! -f "$1" ]]; then
    die "アーカイブが見つかりません: $1"
fi

ARCHIVE="$(readlink -f -- "$1")"
ARCHIVE_NAME="${ARCHIVE##*/}"
CHECKSUM_FILE="${ARCHIVE}.sha256"

if [[ "${ARCHIVE_NAME}" != "${ARCHIVE_PREFIX}"*.tar ]]; then
    die "RHEL 8.8から8.10への専用アーカイブ名ではありません: ${ARCHIVE_NAME}"
fi

if [[ ! -f "${CHECKSUM_FILE}" ]]; then
    die "チェックサムファイルが見つかりません: ${CHECKSUM_FILE}"
fi

mapfile -t CHECKSUM_LINES < <(
    sed '/^[[:space:]]*$/d' "${CHECKSUM_FILE}"
)

if [[ ${#CHECKSUM_LINES[@]} -ne 1 ]]; then
    die "アーカイブのチェックサム記録が1件ではありません。"
fi

read -r EXPECTED_ARCHIVE_SHA CHECKSUM_NAME CHECKSUM_EXTRA \
    <<< "${CHECKSUM_LINES[0]}"
CHECKSUM_NAME="${CHECKSUM_NAME#\*}"

if [[ ! "${EXPECTED_ARCHIVE_SHA}" =~ ^[[:xdigit:]]{64}$ ]] \
    || [[ "${CHECKSUM_NAME}" != "${ARCHIVE_NAME}" ]] \
    || [[ -n "${CHECKSUM_EXTRA:-}" ]]; then
    die "アーカイブのチェックサム記録が不正です。"
fi

ACTUAL_ARCHIVE_SHA="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
if [[ "${EXPECTED_ARCHIVE_SHA,,}" != "${ACTUAL_ARCHIVE_SHA,,}" ]]; then
    die "アーカイブのSHA-256が一致しません。"
fi
echo "アーカイブのSHA-256: OK"

EXPECTED_ROOT="${ARCHIVE_NAME%.tar}"
mapfile -t ARCHIVE_MEMBERS < <(tar -tf "${ARCHIVE}")
mapfile -t ARCHIVE_VERBOSE_ENTRIES < <(LC_ALL=C tar -tvf "${ARCHIVE}")

if [[ ${#ARCHIVE_MEMBERS[@]} -eq 0 ]] \
    || [[ ${#ARCHIVE_MEMBERS[@]} -ne ${#ARCHIVE_VERBOSE_ENTRIES[@]} ]]; then
    die "アーカイブが空か、エントリ一覧が不整合です。"
fi

for verbose_entry in "${ARCHIVE_VERBOSE_ENTRIES[@]}"; do
    case "${verbose_entry:0:1}" in
        -|d)
            ;;
        *)
            die "アーカイブにシンボリックリンク等の許可されないエントリがあります。"
            ;;
    esac
done

for member in "${ARCHIVE_MEMBERS[@]}"; do
    normalized_member="${member#./}"

    if [[ -z "${normalized_member}" ]] \
        || [[ "${normalized_member}" == /* ]] \
        || [[ "${normalized_member}" == ".." ]] \
        || [[ "${normalized_member}" == ../* ]] \
        || [[ "${normalized_member}" == */../* ]] \
        || [[ "${normalized_member}" == */.. ]]; then
        die "アーカイブに危険なパスが含まれています: ${member}"
    fi

    case "${normalized_member}" in
        "${EXPECTED_ROOT}"|"${EXPECTED_ROOT}/"|"${EXPECTED_ROOT}/"*)
            ;;
        *)
            die "アーカイブのトップディレクトリが不正です: ${member}"
            ;;
    esac
done

APPLY_ROOT="$(mktemp -d /var/tmp/rhel8.8-to-8.10-apply.XXXXXX)"
trap 'rm -rf -- "${APPLY_ROOT}"' EXIT

tar --no-same-owner --no-same-permissions \
    -xf "${ARCHIVE}" \
    -C "${APPLY_ROOT}"

SNAPSHOT_DIR="${APPLY_ROOT}/${EXPECTED_ROOT}"
RPM_DIR="${SNAPSHOT_DIR}/rpms"
STATE_DIR="${SNAPSHOT_DIR}/state"

if [[ ! -d "${RPM_DIR}" || ! -d "${STATE_DIR}" ]]; then
    die "アーカイブにrpms/またはstate/がありません。"
fi

UNSAFE_ENTRY="$(
    find "${SNAPSHOT_DIR}" -mindepth 1 ! -type f ! -type d -print -quit
)"
if [[ -n "${UNSAFE_ENTRY}" ]]; then
    die "アーカイブに許可されない種類のエントリがあります: ${UNSAFE_ENTRY}"
fi

REQUIRED_STATE_FILES=(
    "snapshot-contract.txt"
    "SHA256SUMS"
    "rpm-count.txt"
    "rpm-manifest.txt"
    "installed-baseline-for-apply.txt"
    "target-kernel-core-rpms.txt"
    "target-redhat-release-rpms.txt"
)

for state_file in "${REQUIRED_STATE_FILES[@]}"; do
    if [[ ! -s "${STATE_DIR}/${state_file}" ]]; then
        die "必須のstateファイルがないか空です: ${state_file}"
    fi
done

EXPECTED_CONTRACT="$(printf '%s\n' \
    'snapshot_format=1' \
    'distribution=rhel' \
    "source_version=${SOURCE_VERSION}" \
    "target_version=${TARGET_VERSION}")"
ACTUAL_CONTRACT="$(< "${STATE_DIR}/snapshot-contract.txt")"

if [[ "${ACTUAL_CONTRACT}" != "${EXPECTED_CONTRACT}" ]]; then
    die "スナップショット契約がRHEL 8.8→8.10専用形式と一致しません。"
fi

mapfile -t RPM_SUM_LINES < <(
    sed '/^[[:space:]]*$/d' "${STATE_DIR}/SHA256SUMS"
)

if [[ ${#RPM_SUM_LINES[@]} -eq 0 ]]; then
    die "RPMチェックサム一覧が空です。"
fi

for checksum_line in "${RPM_SUM_LINES[@]}"; do
    read -r rpm_sha rpm_relative_path rpm_extra <<< "${checksum_line}"
    rpm_relative_path="${rpm_relative_path#\*}"

    if [[ ! "${rpm_sha}" =~ ^[[:xdigit:]]{64}$ ]] \
        || [[ "${rpm_relative_path}" != ./*.rpm ]] \
        || [[ "${rpm_relative_path#./}" == */* ]] \
        || [[ -n "${rpm_extra:-}" ]] \
        || [[ ! -f "${RPM_DIR}/${rpm_relative_path#./}" ]] \
        || [[ -L "${RPM_DIR}/${rpm_relative_path#./}" ]]; then
        die "RPMチェックサム記録が不正です: ${checksum_line}"
    fi
done

mapfile -d '' -t RPM_FILES < <(
    find "${RPM_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.rpm' -print0 \
        | LC_ALL=C sort -z
)

RECORDED_RPM_COUNT="$(tr -d '[:space:]' < "${STATE_DIR}/rpm-count.txt")"
if [[ ! "${RECORDED_RPM_COUNT}" =~ ^[0-9]+$ ]] \
    || [[ "${RECORDED_RPM_COUNT}" -ne "${#RPM_FILES[@]}" ]] \
    || [[ "${#RPM_FILES[@]}" -ne "${#RPM_SUM_LINES[@]}" ]]; then
    die "RPM数がstate記録、実ファイル、チェックサム一覧で一致しません。"
fi

echo "各RPMのSHA-256を確認します。"
(
    cd "${RPM_DIR}"
    sha256sum -c "${STATE_DIR}/SHA256SUMS"
)

ACTUAL_MANIFEST="${APPLY_ROOT}/rpm-manifest-verified.txt"
LC_ALL=C rpm -qp \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
    "${RPM_FILES[@]}" \
    | LC_ALL=C sort \
    > "${ACTUAL_MANIFEST}"

if ! cmp -s "${STATE_DIR}/rpm-manifest.txt" "${ACTUAL_MANIFEST}"; then
    die "RPMから再取得したNEVRAとstateのマニフェストが一致しません。"
fi

VERIFIED_TARGET_KERNELS="${APPLY_ROOT}/target-kernel-core-rpms-verified.txt"
VERIFIED_TARGET_RELEASE="${APPLY_ROOT}/target-redhat-release-rpms-verified.txt"

awk -F '\t' \
    '$1 == "kernel-core" && $2 ~ /[.]el8_10([.]|$)/ {print}' \
    "${ACTUAL_MANIFEST}" \
    > "${VERIFIED_TARGET_KERNELS}"

awk -F '\t' \
    '$1 == "redhat-release" && $2 ~ /(^|:)8[.]10-/ {print}' \
    "${ACTUAL_MANIFEST}" \
    > "${VERIFIED_TARGET_RELEASE}"

if [[ ! -s "${VERIFIED_TARGET_KERNELS}" ]] \
    || [[ ! -s "${VERIFIED_TARGET_RELEASE}" ]] \
    || ! cmp -s "${STATE_DIR}/target-kernel-core-rpms.txt" "${VERIFIED_TARGET_KERNELS}" \
    || ! cmp -s "${STATE_DIR}/target-redhat-release-rpms.txt" "${VERIFIED_TARGET_RELEASE}"; then
    die "RHEL 8.10用kernel-coreまたはredhat-releaseの検証に失敗しました。"
fi

RUN_ID="$(date +%Y%m%dT%H%M%S)"
SIGNATURE_LOG="/var/log/rhel8.8-to-8.10-rpm-signatures-${RUN_ID}.log"
PREFLIGHT_LOG="/var/log/rhel8.8-to-8.10-preflight-${RUN_ID}.log"
APPLY_LOG="/var/log/rhel8.8-to-8.10-update-${RUN_ID}.log"

echo "RPM署名を確認します。"
if ! LC_ALL=C rpm --checksig "${RPM_FILES[@]}" \
    > "${SIGNATURE_LOG}" 2>&1; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "RPM署名の検証コマンドが失敗しました。"
fi

if grep -Eiq '(^|[^[:alnum:]_])(NOKEY|NOTTRUSTED|NOT OK|BAD)([^[:alnum:]_]|$)' \
    "${SIGNATURE_LOG}"; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "署名を検証できないRPMが含まれています。"
fi

package_list()
{
    rpm -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

CURRENT_STATE="${APPLY_ROOT}/installed-current.txt"
package_list > "${CURRENT_STATE}"

if ! cmp -s "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}"; then
    DIFF_LOG="/var/log/rhel8.8-to-8.10-package-drift-${RUN_ID}.diff"
    diff -u "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}" \
        > "${DIFF_LOG}" || true

    echo "ERROR: スナップショット取得後にパッケージ構成が変化しています。" >&2
    echo "差分: ${DIFF_LOG}" >&2
    sed -n '1,200p' "${DIFF_LOG}"
    exit 3
fi

DNF_ARGS=(
    "--disablerepo=*"
    "--disableexcludes=all"
    "--setopt=localpkg_gpgcheck=True"
    "--best"
)

echo
echo "適用予定RPM数: ${#RPM_FILES[@]}"
echo "外部repoをすべて無効化し、保存済みRPMだけでトランザクションを事前検証します。"

dnf "${DNF_ARGS[@]}" \
    --setopt=tsflags=test \
    -y \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${PREFLIGHT_LOG}"

echo
echo "事前検証はPASSしました。"
echo "次のDNF確認で実際のRHEL 8.8→8.10更新を実行します。"
echo

dnf "${DNF_ARGS[@]}" \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${APPLY_LOG}"

echo
echo "RPMデータベースと依存関係を確認します。"
dnf --disablerepo='*' check 2>&1 | tee -a "${APPLY_LOG}"

POST_RHEL_ID="$(
    . /etc/os-release
    printf '%s' "${ID:-}"
)"
POST_RHEL_VERSION_ID="$(
    . /etc/os-release
    printf '%s' "${VERSION_ID:-}"
)"

if [[ "${POST_RHEL_ID}" != "rhel" || "${POST_RHEL_VERSION_ID}" != "${TARGET_VERSION}" ]] \
    || ! grep -Eq '^Red Hat Enterprise Linux( Server)? release 8[.]10([[:space:]]|$)' \
        /etc/redhat-release; then
    die "適用後のOS情報がRed Hat Enterprise Linux ${TARGET_VERSION}ではありません。"
fi

INSTALLED_AFTER="${APPLY_ROOT}/installed-after.txt"
package_list > "${INSTALLED_AFTER}"

while IFS= read -r target_package; do
    if ! grep -Fqx -- "${target_package}" "${INSTALLED_AFTER}"; then
        die "適用後に必須RPMが導入されていません: ${target_package}"
    fi
done < "${VERIFIED_TARGET_KERNELS}"

while IFS= read -r target_package; do
    if ! grep -Fqx -- "${target_package}" "${INSTALLED_AFTER}"; then
        die "適用後に必須RPMが導入されていません: ${target_package}"
    fi
done < "${VERIFIED_TARGET_RELEASE}"

echo
echo "適用後のリリース:"
cat /etc/redhat-release

echo
echo "インストール済みkernel-core:"
rpm -q kernel-core --last

if command -v grubby >/dev/null 2>&1; then
    DEFAULT_KERNEL="$(grubby --default-kernel 2>/dev/null || true)"
    echo
    echo "次回起動のデフォルトカーネル: ${DEFAULT_KERNEL:-取得失敗}"
    if [[ -n "${DEFAULT_KERNEL}" && "${DEFAULT_KERNEL}" != *el8_10* ]]; then
        echo "WARNING: デフォルトカーネルがel8_10ではありません。再起動前にbootloader設定を確認してください。" >&2
    fi
fi

echo
if command -v subscription-manager >/dev/null 2>&1; then
    echo "現在のsubscription-manager release設定:"
    subscription-manager release --show 2>&1 || true
fi
echo "WARNING: RHSM/RHUI/Satelliteの永続repo設定は変更していません。" >&2
echo "WARNING: 次回のオンラインDNF実行前に、管理方式に従ってRHEL 8.10向けrepoへ整合させてください。" >&2

echo
echo "RHEL 8.8から8.10へのRPM適用は完了しました。"
echo "署名ログ: ${SIGNATURE_LOG}"
echo "事前検証ログ: ${PREFLIGHT_LOG}"
echo "適用ログ: ${APPLY_LOG}"
echo "現在稼働中のカーネルは再起動まで変わりません。"
echo "確認後に再起動してください。"
