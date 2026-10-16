#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_VERSION="8.8"
readonly TARGET_VERSION="8.10"
readonly ARCHIVE_PREFIX="rocky8.8-to-8.10-update-"

usage()
{
    cat <<'USAGE_EOF'
使用方法:
  sudo ./apply-rocky8.8-to-8.10-installroot.sh \
    --installroot /absolute/path/to/rocky8-rootfs \
    /path/to/rocky8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar

オプション:
      --installroot PATH   更新対象のRocky Linux 8.8 rootfs
      --installroot=PATH   同上
  -h, --help               このヘルプを表示する

注意:
  PATHは/etc、RPM DB、/bootを含む完全なrootfsである必要があります。
  空のTFTPディレクトリやホストの / は指定できません。
USAGE_EOF
}

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

os_release_value()
{
    local key="$1"

    awk -v key="${key}" '
        index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            sub(/\r$/, "", value)

            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                value = substr(value, 2, length(value) - 2)
            }

            print value
            exit
        }
    '
}

validate_installroot_release()
{
    local validation_phase="$1"
    shift
    local expected_version expected_versions="" version_matches=0

    if ! INSTALLROOT_OS_RELEASE_CONTENT="$(
        chroot "${INSTALLROOT}" /bin/cat /etc/os-release 2>/dev/null
    )"; then
        die "${validation_phase}のinstallroot内で/etc/os-releaseを読み込めません。完全なrootfsを指定してください。"
    fi

    INSTALLROOT_OS_ID="$(
        printf '%s\n' "${INSTALLROOT_OS_RELEASE_CONTENT}" | os_release_value ID
    )"
    INSTALLROOT_OS_VERSION="$(
        printf '%s\n' "${INSTALLROOT_OS_RELEASE_CONTENT}" | os_release_value VERSION_ID
    )"

    for expected_version in "$@"; do
        if [[ -n "${expected_versions}" ]]; then
            expected_versions+="または"
        fi
        expected_versions+="${expected_version}"

        if [[ "${INSTALLROOT_OS_VERSION}" == "${expected_version}" ]]; then
            version_matches=1
        fi
    done

    if [[ "${INSTALLROOT_OS_ID}" != "rocky" ]] \
        || [[ "${version_matches}" -ne 1 ]]; then
        echo "ERROR: ${validation_phase}のinstallrootがRocky Linux ${expected_versions}ではありません。" >&2
        echo "chroot内/etc/os-release: ID=${INSTALLROOT_OS_ID:-未設定} VERSION_ID=${INSTALLROOT_OS_VERSION:-未設定}" >&2
        printf '%s\n' "${INSTALLROOT_OS_RELEASE_CONTENT}" >&2
        return 1
    fi
}

signature_log_has_failure()
{
    local signature_log="$1"

    awk '
        {
            separator = index($0, ": ")
            if (separator == 0) {
                next
            }

            status = toupper(substr($0, separator + 2))
            if (status ~ /(^|[^[:alnum:]_])(NOKEY|NOTTRUSTED|NOT OK|BAD)([^[:alnum:]_]|$)/) {
                failure = 1
            }
        }
        END {exit failure ? 0 : 1}
    ' "${signature_log}"
}

validate_preinstalled_drift()
{
    local expected_state="$1"
    local current_state="$2"
    local archive_manifest="$3"
    local archive_header_manifest="$4"
    local current_header_manifest="$5"
    local work_dir="$6"
    local allowed_scope="$7"
    local added_packages="${work_dir}/package-drift-added.txt"
    local removed_packages="${work_dir}/package-drift-removed.txt"
    local package_line package_name package_arch archive_identity current_identity

    case "${allowed_scope}" in
        kernel|archive)
            ;;
        *)
            echo "不明なパッケージ差分許可範囲です: ${allowed_scope}" >&2
            return 1
            ;;
    esac

    if ! LC_ALL=C comm -13 "${expected_state}" "${current_state}" > "${added_packages}" \
        || ! LC_ALL=C comm -23 "${expected_state}" "${current_state}" > "${removed_packages}"; then
        echo "パッケージ差分の集合を作成できませんでした。" >&2
        return 1
    fi

    if [[ ! -s "${added_packages}" ]]; then
        echo "保存済みRPMに一致する追加パッケージがありません。" >&2
        return 1
    fi

    while IFS= read -r package_line; do
        package_name="${package_line%%$'\t'*}"

        if [[ "${allowed_scope}" == "kernel" ]]; then
            case "${package_name}" in
                kernel|kernel-*)
                    ;;
                *)
                    echo "kernel関連以外の追加パッケージです: ${package_line}" >&2
                    return 1
                    ;;
            esac
        fi

        if ! grep -Fqx -- "${package_line}" "${archive_manifest}"; then
            echo "保存済みRPMに存在しない追加パッケージです: ${package_line}" >&2
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

        if [[ "${allowed_scope}" == "kernel" ]]; then
            case "${package_name}" in
                kernel|kernel-*)
                    ;;
                *)
                    echo "kernel関連以外の削除・更新パッケージです: ${package_line}" >&2
                    return 1
                    ;;
            esac
        fi

        if ! awk -F '\t' -v name="${package_name}" -v arch="${package_arch}" \
            '$1 == name && $3 == arch {found = 1} END {exit !found}' \
            "${added_packages}"; then
            echo "同名・同一archの保存済みRPMへの置換ではありません: ${package_line}" >&2
            return 1
        fi
    done < "${removed_packages}"

    return 0
}

INSTALLROOT_INPUT=""
ARCHIVE_INPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installroot)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: --installroot には絶対パスが必要です。" >&2
                exit 2
            fi
            if [[ -n "${INSTALLROOT_INPUT}" ]]; then
                echo "ERROR: --installrootは1回だけ指定してください。" >&2
                exit 2
            fi
            INSTALLROOT_INPUT="$2"
            shift 2
            ;;
        --installroot=*)
            if [[ -n "${INSTALLROOT_INPUT}" ]]; then
                echo "ERROR: --installrootは1回だけ指定してください。" >&2
                exit 2
            fi
            INSTALLROOT_INPUT="${1#--installroot=}"
            if [[ -z "${INSTALLROOT_INPUT}" ]]; then
                echo "ERROR: --installroot には絶対パスが必要です。" >&2
                exit 2
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [[ $# -gt 1 ]]; then
                echo "ERROR: アーカイブは1つだけ指定してください。" >&2
                exit 2
            fi
            if [[ $# -eq 1 ]]; then
                ARCHIVE_INPUT="$1"
                shift
            fi
            ;;
        -*)
            echo "ERROR: 不明な引数です: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "${ARCHIVE_INPUT}" ]]; then
                echo "ERROR: アーカイブは1つだけ指定してください。" >&2
                exit 2
            fi
            ARCHIVE_INPUT="$1"
            shift
            ;;
    esac
done

if [[ -z "${INSTALLROOT_INPUT}" || -z "${ARCHIVE_INPUT}" ]]; then
    usage >&2
    exit 2
fi

if [[ "${INSTALLROOT_INPUT}" != /* ]]; then
    die "--installrootには絶対パスを指定してください: ${INSTALLROOT_INPUT}"
fi

if [[ "${INSTALLROOT_INPUT}" == *$'\n'* || "${INSTALLROOT_INPUT}" == *$'\r'* ]]; then
    die "--installrootのパスに改行は使用できません。"
fi

if [[ "${EUID}" -ne 0 ]]; then
    die "rootで実行してください。"
fi

for command_name in \
    awk cat chroot cmp comm date diff dnf find grep mkdir mktemp readlink rm rpm sed sha256sum sort tar tee tr
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        die "必要なコマンドが見つかりません: ${command_name}"
    fi
done

if [[ ! -d "${INSTALLROOT_INPUT}" ]]; then
    die "installrootディレクトリが見つかりません: ${INSTALLROOT_INPUT}"
fi

INSTALLROOT="$(readlink -f -- "${INSTALLROOT_INPUT}")"
if [[ -z "${INSTALLROOT}" || "${INSTALLROOT}" == "/" ]]; then
    die "ホストの / はinstallrootとして指定できません。"
fi

INSTALLROOT_OS_RELEASE_CONTENT=""
INSTALLROOT_OS_ID=""
INSTALLROOT_OS_VERSION=""
validate_installroot_release "更新前" "${SOURCE_VERSION}" "${TARGET_VERSION}"
INSTALLROOT_INITIAL_VERSION="${INSTALLROOT_OS_VERSION}"

if ! rpm --root "${INSTALLROOT}" -q rocky-release >/dev/null 2>&1; then
    die "installrootのRPM DBでrocky-releaseを確認できません。完全なrootfsを指定してください。"
fi

INSTALLROOT_ROCKY_VERSION="$(
    rpm --root "${INSTALLROOT}" -q rocky-release \
        --qf '%{VERSION}\n' 2>/dev/null \
        | LC_ALL=C sort -u
)"
if [[ "${INSTALLROOT_ROCKY_VERSION}" != "${INSTALLROOT_INITIAL_VERSION}" ]]; then
    die "installroot内の/etc/os-releaseとrocky-release RPMのバージョンが一致しません: os-release=${INSTALLROOT_INITIAL_VERSION} RPM=${INSTALLROOT_ROCKY_VERSION}"
fi

if ! LC_ALL=C rpm --querytags | grep -Fqx 'SHA1HEADER'; then
    die "RPMの不変ヘッダーID（SHA1HEADER）を取得できません。"
fi

if [[ ! -f "${ARCHIVE_INPUT}" ]]; then
    die "アーカイブが見つかりません: ${ARCHIVE_INPUT}"
fi

ARCHIVE="$(readlink -f -- "${ARCHIVE_INPUT}")"
ARCHIVE_NAME="${ARCHIVE##*/}"
CHECKSUM_FILE="${ARCHIVE}.sha256"

if [[ "${ARCHIVE_NAME}" != "${ARCHIVE_PREFIX}"*.tar ]]; then
    die "Rocky Linux 8.8から8.10への専用アーカイブ名ではありません: ${ARCHIVE_NAME}"
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

APPLY_ROOT="$(mktemp -d /var/tmp/rocky8.8-to-8.10-installroot.XXXXXX)"
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
    die "スナップショット契約がRocky Linux 8.8→8.10専用形式と一致しません。"
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
    '$1 == "kernel-core" && $2 ~ /[.]el8_10([.]|$)/ {print}' \
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
    die "Rocky Linux 8.10用kernel-coreまたはrocky-releaseの検証に失敗しました。"
fi

RUN_ID="$(date +%Y%m%dT%H%M%S)"

if [[ -L "${INSTALLROOT}/var" || -L "${INSTALLROOT}/var/log" ]]; then
    die "installrootの/varまたは/var/logがシンボリックリンクのため、安全にログを保存できません。"
fi
mkdir -p "${INSTALLROOT}/var/log"

LOG_PREFIX="${INSTALLROOT}/var/log/rocky8.8-to-8.10-installroot-${RUN_ID}"
SIGNATURE_LOG="${LOG_PREFIX}-rpm-signatures.log"
PREFLIGHT_LOG="${LOG_PREFIX}-preflight.log"
APPLY_LOG="${LOG_PREFIX}-update.log"
DIFF_LOG="${LOG_PREFIX}-package-drift.diff"
BOOT_LOG="${LOG_PREFIX}-boot-artifacts.log"

echo "RPM署名を確認します。"
if ! LC_ALL=C rpm --checksig "${RPM_FILES[@]}" \
    > "${SIGNATURE_LOG}" 2>&1; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "RPM署名の検証コマンドが失敗しました。"
fi

if signature_log_has_failure "${SIGNATURE_LOG}"; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "署名を検証できないRPMが含まれています。"
fi

package_list()
{
    rpm --root "${INSTALLROOT}" -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

CURRENT_HEADER_MANIFEST="${APPLY_ROOT}/installed-current-with-header.txt"
LC_ALL=C rpm --root "${INSTALLROOT}" -qa \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SHA1HEADER}\n' \
    | awk -F '\t' 'BEGIN {OFS = "\t"} {$4 = tolower($4); print}' \
    | LC_ALL=C sort \
    > "${CURRENT_HEADER_MANIFEST}"

CURRENT_STATE="${APPLY_ROOT}/installed-current.txt"
awk -F '\t' 'BEGIN {OFS = "\t"} {print $1, $2, $3}' \
    "${CURRENT_HEADER_MANIFEST}" \
    > "${CURRENT_STATE}"

if ! cmp -s "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}"; then
    diff -u "${STATE_DIR}/installed-baseline-for-apply.txt" "${CURRENT_STATE}" \
        > "${DIFF_LOG}" || true

    if [[ "${INSTALLROOT_INITIAL_VERSION}" == "${TARGET_VERSION}" ]]; then
        ALLOWED_DRIFT_SCOPE="archive"
    else
        ALLOWED_DRIFT_SCOPE="kernel"
    fi

    if validate_preinstalled_drift \
        "${STATE_DIR}/installed-baseline-for-apply.txt" \
        "${CURRENT_STATE}" \
        "${ACTUAL_MANIFEST}" \
        "${ARCHIVE_HEADER_MANIFEST}" \
        "${CURRENT_HEADER_MANIFEST}" \
        "${APPLY_ROOT}" \
        "${ALLOWED_DRIFT_SCOPE}"; then
        if [[ "${ALLOWED_DRIFT_SCOPE}" == "archive" ]]; then
            echo "WARNING: installrootは既にRocky Linux ${TARGET_VERSION}です。" >&2
            echo "WARNING: 基準との差分は、不変ヘッダーIDまで保存済みRPMと一致する先行適用分だけです。" >&2
        else
            echo "WARNING: 保存済みRPMと一致するkernel関連パッケージだけがinstallrootへ先行導入されています。" >&2
        fi
        echo "WARNING: 限定的な許可条件を満たしたため、オフライン事前検証へ進みます。" >&2
        echo "差分: ${DIFF_LOG}" >&2
        sed -n '1,200p' "${DIFF_LOG}"
    else
        echo "ERROR: installrootに許可されないパッケージ構成の差分があります。" >&2
        echo "差分: ${DIFF_LOG}" >&2
        sed -n '1,200p' "${DIFF_LOG}"
        exit 3
    fi
fi

DNF_ARGS=(
    "--installroot=${INSTALLROOT}"
    "--releasever=${TARGET_VERSION}"
    "--setopt=module_platform_id=platform:el8"
    "--noplugins"
    "--disablerepo=*"
    "--disableexcludes=all"
    "--setopt=localpkg_gpgcheck=True"
    "--best"
)

echo
echo "更新対象installroot: ${INSTALLROOT}"
echo "適用予定RPM数: ${#RPM_FILES[@]}"
echo "外部repoをすべて無効化し、保存済みRPMだけでinstallrootトランザクションを事前検証します。"

if command -v mountpoint >/dev/null 2>&1; then
    for pseudo_filesystem in dev proc sys; do
        if ! mountpoint -q "${INSTALLROOT}/${pseudo_filesystem}"; then
            echo "WARNING: ${INSTALLROOT}/${pseudo_filesystem} はマウントポイントではありません。" >&2
            echo "WARNING: kernel/dracutのscriptletが失敗する場合は、適用前に適切にbind mountしてください。" >&2
        fi
    done
fi

dnf "${DNF_ARGS[@]}" \
    --setopt=tsflags=test \
    -y \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${PREFLIGHT_LOG}"

echo
echo "事前検証はPASSしました。"
echo "次のDNF確認でinstallrootへ実際の8.8→8.10更新を実行します。"
echo

dnf "${DNF_ARGS[@]}" \
    install "${RPM_FILES[@]}" 2>&1 \
    | tee "${APPLY_LOG}"

echo
echo "installrootのRPMデータベースと依存関係を確認します。"
dnf \
    --installroot="${INSTALLROOT}" \
    --releasever="${TARGET_VERSION}" \
    --setopt=module_platform_id=platform:el8 \
    --noplugins \
    --disablerepo='*' \
    check 2>&1 | tee -a "${APPLY_LOG}"

validate_installroot_release "適用後" "${TARGET_VERSION}"

INSTALLED_AFTER="${APPLY_ROOT}/installed-after.txt"
package_list > "${INSTALLED_AFTER}"

while IFS= read -r target_package; do
    if ! grep -Fqx -- "${target_package}" "${INSTALLED_AFTER}"; then
        die "適用後のinstallrootに必須RPMが導入されていません: ${target_package}"
    fi
done < "${VERIFIED_TARGET_KERNELS}"

while IFS= read -r target_package; do
    if ! grep -Fqx -- "${target_package}" "${INSTALLED_AFTER}"; then
        die "適用後のinstallrootに必須RPMが導入されていません: ${target_package}"
    fi
done < "${VERIFIED_TARGET_RELEASE}"

: > "${BOOT_LOG}"
BOOT_ARTIFACT_MISSING=0

while IFS=$'\t' read -r package_name package_evr package_arch; do
    kernel_version_release="${package_evr#*:}"
    kernel_path="${INSTALLROOT}/boot/vmlinuz-${kernel_version_release}.${package_arch}"
    initramfs_path="${INSTALLROOT}/boot/initramfs-${kernel_version_release}.${package_arch}.img"

    printf 'package=%s\nkernel=%s\ninitramfs=%s\n' \
        "${package_name}" "${kernel_path}" "${initramfs_path}" \
        >> "${BOOT_LOG}"

    if [[ ! -s "${kernel_path}" ]]; then
        echo "ERROR: PXE用カーネルが生成されていません: ${kernel_path}" >&2
        BOOT_ARTIFACT_MISSING=1
    fi

    if [[ ! -s "${initramfs_path}" ]]; then
        echo "ERROR: PXE用initramfsが生成されていません: ${initramfs_path}" >&2
        BOOT_ARTIFACT_MISSING=1
    fi
done < "${VERIFIED_TARGET_KERNELS}"

if [[ "${BOOT_ARTIFACT_MISSING}" -ne 0 ]]; then
    die "installrootの更新は完了しましたが、PXEブート成果物が不足しています。dracut/kernel-installのログとrootfs構成を確認してください。"
fi

echo
echo "installrootのリリース:"
printf '%s\n' "${INSTALLROOT_OS_RELEASE_CONTENT}"

echo
echo "installrootのkernel-core:"
rpm --root "${INSTALLROOT}" -q kernel-core --last

echo
echo "Rocky Linux 8.8から8.10へのinstallroot適用が完了しました。"
echo "installroot: ${INSTALLROOT}"
echo "署名ログ: ${SIGNATURE_LOG}"
echo "事前検証ログ: ${PREFLIGHT_LOG}"
echo "適用ログ: ${APPLY_LOG}"
echo "PXE成果物ログ: ${BOOT_LOG}"
echo "ホストOSのRPM DBとカーネルは更新していません。"
