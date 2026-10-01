#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_VERSION="8.8"
readonly TARGET_VERSION="8.10"
readonly ARCHIVE_PREFIX="rocky8.8-to-8.10-update-"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

validate_preinstalled_kernel_drift()
{
    local expected_state="$1"
    local current_state="$2"
    local archive_manifest="$3"
    local archive_header_manifest="$4"
    local current_header_manifest="$5"
    local work_dir="$6"
    local added_packages="${work_dir}/package-drift-added.txt"
    local removed_packages="${work_dir}/package-drift-removed.txt"
    local package_line package_name package_arch archive_identity current_identity

    if ! LC_ALL=C comm -13 "${expected_state}" "${current_state}" > "${added_packages}" \
        || ! LC_ALL=C comm -23 "${expected_state}" "${current_state}" > "${removed_packages}"; then
        echo "パッケージ差分の集合を作成できませんでした。" >&2
        return 1
    fi

    if [[ ! -s "${added_packages}" ]]; then
        echo "保存済みkernel RPMに一致する追加パッケージがありません。" >&2
        return 1
    fi

    while IFS= read -r package_line; do
        package_name="${package_line%%$'\t'*}"

        case "${package_name}" in
            kernel|kernel-*)
                ;;
            *)
                echo "kernel関連以外の追加パッケージです: ${package_line}" >&2
                return 1
                ;;
        esac

        if ! grep -Fqx -- "${package_line}" "${archive_manifest}"; then
            echo "保存済みRPMに存在しないkernel関連パッケージです: ${package_line}" >&2
            return 1
        fi

        archive_identity="$(
            awk -F '\t' -v wanted="${package_line}" \
                'BEGIN {OFS = "\t"} $1 OFS $2 OFS $3 == wanted {print}' \
                "${archive_header_manifest}"
        )"
        current_identity="$(
            awk -F '\t' -v wanted="${package_line}" \
                'BEGIN {OFS = "\t"} $1 OFS $2 OFS $3 == wanted {print}' \
                "${current_header_manifest}"
        )"

        if [[ -z "${archive_identity}" || "${archive_identity}" != "${current_identity}" ]]; then
            echo "保存済みRPMと不変ヘッダーIDが一致しません: ${package_line}" >&2
            return 1
        fi
    done < "${added_packages}"

    while IFS= read -r package_line; do
        package_name="${package_line%%$'\t'*}"
        package_arch="${package_line##*$'\t'}"

        case "${package_name}" in
            kernel|kernel-*)
                ;;
            *)
                echo "kernel関連以外の削除・更新パッケージです: ${package_line}" >&2
                return 1
                ;;
        esac

        if ! awk -F '\t' -v name="${package_name}" -v arch="${package_arch}" \
            '$1 == name && $3 == arch {found = 1} END {exit !found}' \
            "${added_packages}"; then
            echo "同名・同一archの保存済みkernel RPMへの置換ではありません: ${package_line}" >&2
            return 1
        fi
    done < "${removed_packages}"

    return 0
}

if [[ "${EUID}" -ne 0 ]]; then
    die "rootで実行してください。"
fi

if [[ $# -ne 1 ]]; then
    echo "使用方法:"
    echo "  $0 /path/to/rocky8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar"
    exit 1
fi

if ! grep -Eq '^Rocky Linux release 8\.8([[:space:]]|$)' /etc/rocky-release; then
    echo "ERROR: 適用元がRocky Linux ${SOURCE_VERSION}ではありません。" >&2
    cat /etc/rocky-release 2>/dev/null || true
    exit 1
fi

for command_name in \
    awk cat cmp comm date diff dnf find grep mktemp readlink rm rpm sed sha256sum sort tar tee tr
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        die "必要なコマンドが見つかりません: ${command_name}"
    fi
done

if ! LC_ALL=C rpm --querytags | grep -Fqx 'SHA1HEADER'; then
    die "RPMの不変ヘッダーID（SHA1HEADER）を取得できません。"
fi

if [[ ! -f "$1" ]]; then
    die "アーカイブが見つかりません: $1"
fi

ARCHIVE="$(readlink -f -- "$1")"
ARCHIVE_NAME="${ARCHIVE##*/}"
CHECKSUM_FILE="${ARCHIVE}.sha256"

if [[ "${ARCHIVE_NAME}" != "${ARCHIVE_PREFIX}"*.tar ]]; then
    die "8.8から8.10への専用アーカイブ名ではありません: ${ARCHIVE_NAME}"
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

APPLY_ROOT="$(mktemp -d /var/tmp/rocky8.8-to-8.10-apply.XXXXXX)"
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
    "target-rocky-release-rpms.txt"
)

for state_file in "${REQUIRED_STATE_FILES[@]}"; do
    if [[ ! -s "${STATE_DIR}/${state_file}" ]]; then
        die "必須のstateファイルがないか空です: ${state_file}"
    fi
done

EXPECTED_CONTRACT="$(printf '%s\n' \
    'snapshot_format=1' \
    "source_version=${SOURCE_VERSION}" \
    "target_version=${TARGET_VERSION}")"
ACTUAL_CONTRACT="$(< "${STATE_DIR}/snapshot-contract.txt")"

if [[ "${ACTUAL_CONTRACT}" != "${EXPECTED_CONTRACT}" ]]; then
    die "スナップショット契約が8.8→8.10専用形式と一致しません。"
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

ARCHIVE_HEADER_MANIFEST="${APPLY_ROOT}/rpm-header-manifest-verified.txt"
LC_ALL=C rpm -qp \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SHA1HEADER}\n' \
    "${RPM_FILES[@]}" \
    | awk -F '\t' 'BEGIN {OFS = "\t"} {$4 = tolower($4); print}' \
    | LC_ALL=C sort \
    > "${ARCHIVE_HEADER_MANIFEST}"

if ! awk -F '\t' \
    'NF != 4 || length($4) != 40 || $4 !~ /^[[:xdigit:]]+$/ {invalid = 1} END {exit invalid}' \
    "${ARCHIVE_HEADER_MANIFEST}"; then
    die "保存済みRPMの不変ヘッダーIDを検証できません。"
fi

VERIFIED_TARGET_KERNELS="${APPLY_ROOT}/target-kernel-core-rpms-verified.txt"
VERIFIED_TARGET_RELEASE="${APPLY_ROOT}/target-rocky-release-rpms-verified.txt"

awk -F '\t' \
    '$1 == "kernel-core" && $2 ~ /\.el8_10([.]|$)/ {print}' \
    "${ACTUAL_MANIFEST}" \
    > "${VERIFIED_TARGET_KERNELS}"

awk -F '\t' \
    '$1 == "rocky-release" && $2 ~ /(^|:)8[.]10-/ {print}' \
    "${ACTUAL_MANIFEST}" \
    > "${VERIFIED_TARGET_RELEASE}"

if [[ ! -s "${VERIFIED_TARGET_KERNELS}" ]] \
    || [[ ! -s "${VERIFIED_TARGET_RELEASE}" ]] \
    || ! cmp -s "${STATE_DIR}/target-kernel-core-rpms.txt" "${VERIFIED_TARGET_KERNELS}" \
    || ! cmp -s "${STATE_DIR}/target-rocky-release-rpms.txt" "${VERIFIED_TARGET_RELEASE}"; then
    die "8.10用kernel-coreまたはrocky-releaseの検証に失敗しました。"
fi

RUN_ID="$(date +%Y%m%dT%H%M%S)"
SIGNATURE_LOG="/var/log/rocky8.8-to-8.10-rpm-signatures-${RUN_ID}.log"
PREFLIGHT_LOG="/var/log/rocky8.8-to-8.10-preflight-${RUN_ID}.log"
APPLY_LOG="/var/log/rocky8.8-to-8.10-update-${RUN_ID}.log"

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

CURRENT_HEADER_MANIFEST="${APPLY_ROOT}/installed-current-with-header.txt"
LC_ALL=C rpm -qa \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SHA1HEADER}\n' \
    | awk -F '\t' 'BEGIN {OFS = "\t"} {$4 = tolower($4); print}' \
    | LC_ALL=C sort \
    > "${CURRENT_HEADER_MANIFEST}"

CURRENT_STATE="${APPLY_ROOT}/installed-current.txt"
awk -F '\t' 'BEGIN {OFS = "\t"} {print $1, $2, $3}' \
    "${CURRENT_HEADER_MANIFEST}" \
    > "${CURRENT_STATE}"

if ! cmp -s "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}"; then
    DIFF_LOG="/var/log/rocky8.8-to-8.10-package-drift-${RUN_ID}.diff"
    diff -u "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}" \
        > "${DIFF_LOG}" || true

    if validate_preinstalled_kernel_drift \
        "${STATE_DIR}/installed-baseline-for-apply.txt" \
        "${CURRENT_STATE}" \
        "${ACTUAL_MANIFEST}" \
        "${ARCHIVE_HEADER_MANIFEST}" \
        "${CURRENT_HEADER_MANIFEST}" \
        "${APPLY_ROOT}"; then
        echo "WARNING: 保存済みRPMと一致するkernel関連パッケージだけが先行導入されています。" >&2
        echo "WARNING: 限定的な許可条件を満たしたため、オフライン事前検証へ進みます。" >&2
        echo "差分: ${DIFF_LOG}" >&2
        sed -n '1,200p' "${DIFF_LOG}"
    else
        echo "ERROR: スナップショット取得後に許可されないパッケージ構成の変化があります。" >&2
        echo "差分: ${DIFF_LOG}" >&2
        sed -n '1,200p' "${DIFF_LOG}"
        exit 3
    fi
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
echo "次のDNF確認で実際の8.8→8.10更新を実行します。"
echo

dnf "${DNF_ARGS[@]}" \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${APPLY_LOG}"

echo
echo "RPMデータベースと依存関係を確認します。"
dnf --disablerepo='*' check 2>&1 | tee -a "${APPLY_LOG}"

if ! grep -Eq '^Rocky Linux release 8\.10([[:space:]]|$)' /etc/rocky-release; then
    die "適用後の/etc/rocky-releaseがRocky Linux ${TARGET_VERSION}ではありません。"
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
cat /etc/rocky-release

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
echo "8.8から8.10へのRPM適用は完了しました。"
echo "署名ログ: ${SIGNATURE_LOG}"
echo "事前検証ログ: ${PREFLIGHT_LOG}"
echo "適用ログ: ${APPLY_LOG}"
echo "現在稼働中のカーネルは再起動まで変わりません。"
echo "確認後に再起動してください。"
