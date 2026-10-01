#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_VERSION="8.8"
readonly TARGET_VERSION="8.10"
readonly BASE_DIR="/var/lib/rhel-update-snapshots"

usage()
{
    cat <<'USAGE_EOF'
使用方法:
  sudo ./capture-rhel8.8-to-8.10-snapshot.sh [OPTIONS]

オプション:
  -x, --exclude PATTERN     DNF/YUMの更新対象からPATTERNを除外する
      --exclude=PATTERN     同上
      --enablerepo REPOID   構成済みのREPOIDを一時的に有効化する
      --enablerepo=REPOID   同上
      --disablerepo REPOID  REPOIDを一時的に無効化する
      --disablerepo=REPOID  同上
  -h, --help                このヘルプを表示する

各オプションは複数指定できます。リポジトリIDはカンマ区切りにも対応します。
ワイルドカードは引用符で囲んでください。

例:
  sudo ./capture-rhel8.8-to-8.10-snapshot.sh \
    --exclude 'podman*' \
    --disablerepo '*-eus-*' \
    --enablerepo 'rhel-8-for-x86_64-baseos-rpms' \
    --enablerepo 'rhel-8-for-x86_64-appstream-rpms'

注意:
  現在構成済みのRHSM、RHUIまたはSatelliteリポジトリを使用します。
  subscription-managerやrepoの永続設定は変更しません。
USAGE_EOF
}

die()
{
    echo "ERROR: $*" >&2
    exit 1
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

EXCLUDE_PATTERNS=()
ENABLED_REPOSITORIES=()
DISABLED_REPOSITORIES=()
REPOSITORY_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--exclude)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: $1 には空でない除外パターンが必要です。" >&2
                exit 2
            fi
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        --exclude=*)
            exclude_pattern="${1#--exclude=}"
            if [[ -z "${exclude_pattern}" ]]; then
                echo "ERROR: --exclude には空でない除外パターンが必要です。" >&2
                exit 2
            fi
            EXCLUDE_PATTERNS+=("${exclude_pattern}")
            shift
            ;;
        --enablerepo)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: --enablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            ENABLED_REPOSITORIES+=("$2")
            REPOSITORY_ARGS+=("--enablerepo=$2")
            shift 2
            ;;
        --enablerepo=*)
            enabled_repository="${1#--enablerepo=}"
            if [[ -z "${enabled_repository}" ]]; then
                echo "ERROR: --enablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            ENABLED_REPOSITORIES+=("${enabled_repository}")
            REPOSITORY_ARGS+=("--enablerepo=${enabled_repository}")
            shift
            ;;
        --disablerepo)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES+=("$2")
            REPOSITORY_ARGS+=("--disablerepo=$2")
            shift 2
            ;;
        --disablerepo=*)
            disabled_repository="${1#--disablerepo=}"
            if [[ -z "${disabled_repository}" ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES+=("${disabled_repository}")
            REPOSITORY_ARGS+=("--disablerepo=${disabled_repository}")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [[ $# -ne 0 ]]; then
                echo "ERROR: 位置引数は受け付けません: $*" >&2
                exit 2
            fi
            ;;
        *)
            echo "ERROR: 不明な引数です: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    for exclude_pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "${exclude_pattern}" == *$'\n'* || "${exclude_pattern}" == *$'\r'* ]]; then
            echo "ERROR: 除外パターンに改行は使用できません。" >&2
            exit 2
        fi
    done
fi

if [[ ${#ENABLED_REPOSITORIES[@]} -gt 0 ]]; then
    for enabled_repository in "${ENABLED_REPOSITORIES[@]}"; do
        if [[ "${enabled_repository}" == *$'\n'* || "${enabled_repository}" == *$'\r'* ]]; then
            echo "ERROR: リポジトリIDに改行は使用できません。" >&2
            exit 2
        fi
    done
fi

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    for disabled_repository in "${DISABLED_REPOSITORIES[@]}"; do
        if [[ "${disabled_repository}" == *$'\n'* || "${disabled_repository}" == *$'\r'* ]]; then
            echo "ERROR: リポジトリIDに改行は使用できません。" >&2
            exit 2
        fi
    done
fi

if [[ "${EUID}" -ne 0 ]]; then
    die "rootで実行してください。"
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
    echo "ERROR: 更新元がRed Hat Enterprise Linux ${SOURCE_VERSION}ではありません。" >&2
    cat /etc/redhat-release 2>/dev/null || true
    exit 1
fi

for command_name in \
    awk cat cp date dnf find grep mktemp mv rm rpm sed sha256sum sort tar tee tr uname wc xargs
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        die "必要なコマンドが見つかりません: ${command_name}"
    fi
done

if ! rpm -q redhat-release >/dev/null 2>&1; then
    die "redhat-releaseパッケージがインストールされていません。"
fi

mkdir -p "${BASE_DIR}"

TIMESTAMP="$(TZ=Asia/Tokyo date +%Y%m%dT%H%M%S%z)"
SNAPSHOT_NAME="rhel${SOURCE_VERSION}-to-${TARGET_VERSION}-update-${TIMESTAMP}"
WORK_DIR="$(mktemp -d "${BASE_DIR}/.${SNAPSHOT_NAME}.work.XXXXXX")"
FINAL_DIR="${BASE_DIR}/${SNAPSHOT_NAME}"
ARCHIVE="${BASE_DIR}/${SNAPSHOT_NAME}.tar"
DNF_CACHE_DIR="${WORK_DIR}/dnf-cache"

cleanup()
{
    local exit_status=$?

    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf -- "${WORK_DIR}"
    fi

    if [[ ${exit_status} -ne 0 && -n "${FINAL_DIR:-}" && -d "${FINAL_DIR}" ]]; then
        rm -rf -- "${FINAL_DIR}"
    fi

    exit "${exit_status}"
}
trap cleanup EXIT

mkdir -p \
    "${WORK_DIR}/rpms" \
    "${WORK_DIR}/state" \
    "${DNF_CACHE_DIR}"

printf '%s\n' \
    'snapshot_format=1' \
    'distribution=rhel' \
    "source_version=${SOURCE_VERSION}" \
    "target_version=${TARGET_VERSION}" \
    > "${WORK_DIR}/state/snapshot-contract.txt"

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    printf '%s\n' "${EXCLUDE_PATTERNS[@]}" \
        > "${WORK_DIR}/state/requested-excludes.txt"
else
    : > "${WORK_DIR}/state/requested-excludes.txt"
fi

if [[ ${#ENABLED_REPOSITORIES[@]} -gt 0 ]]; then
    printf '%s\n' "${ENABLED_REPOSITORIES[@]}" \
        > "${WORK_DIR}/state/requested-enabled-repositories.txt"
else
    : > "${WORK_DIR}/state/requested-enabled-repositories.txt"
fi

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    printf '%s\n' "${DISABLED_REPOSITORIES[@]}" \
        > "${WORK_DIR}/state/requested-disabled-repositories.txt"
else
    : > "${WORK_DIR}/state/requested-disabled-repositories.txt"
fi

if [[ ${#REPOSITORY_ARGS[@]} -gt 0 ]]; then
    printf '%s\n' "${REPOSITORY_ARGS[@]}" \
        > "${WORK_DIR}/state/requested-repository-options.txt"
else
    : > "${WORK_DIR}/state/requested-repository-options.txt"
fi

DNF_ARGS=(
    "--releasever=${TARGET_VERSION}"
    "--setopt=cachedir=${DNF_CACHE_DIR}"
    "--setopt=timeout=300"
    "--setopt=minrate=1"
    "--setopt=retries=20"
    "--setopt=max_parallel_downloads=1"
)

if [[ ${#REPOSITORY_ARGS[@]} -gt 0 ]]; then
    DNF_ARGS+=("${REPOSITORY_ARGS[@]}")
fi

rhel_dnf()
{
    dnf "${DNF_ARGS[@]}" "$@"
}

package_list()
{
    rpm -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

echo "システム情報と現在の有効repoを記録します。"

cp -p /etc/os-release "${WORK_DIR}/state/os-release.txt"
cat /etc/redhat-release > "${WORK_DIR}/state/redhat-release.txt"
uname -a > "${WORK_DIR}/state/uname-before.txt"
dnf --version > "${WORK_DIR}/state/dnf-version.txt" 2>&1
rpm -q redhat-release redhat-release-eula \
    > "${WORK_DIR}/state/redhat-release-packages.txt" 2>&1 || true
dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-repositories-before.txt" 2>&1 || true

if command -v subscription-manager >/dev/null 2>&1; then
    subscription-manager release --show \
        > "${WORK_DIR}/state/subscription-manager-release.txt" 2>&1 || true
else
    printf '%s\n' 'subscription-manager: not installed (RHUIまたは別管理の可能性)' \
        > "${WORK_DIR}/state/subscription-manager-release.txt"
fi

printf '%s\n' \
    "releasever=${TARGET_VERSION}" \
    "cachedir=${DNF_CACHE_DIR}" \
    'timeout=300' \
    'minrate=1' \
    'retries=20' \
    'max_parallel_downloads=1' \
    > "${WORK_DIR}/state/dnf-runtime-options.txt"

if [[ ${#REPOSITORY_ARGS[@]} -gt 0 ]]; then
    printf '%s\n' "${REPOSITORY_ARGS[@]}" \
        >> "${WORK_DIR}/state/dnf-runtime-options.txt"
fi

echo "構成済みrepoからRed Hat Enterprise Linux ${TARGET_VERSION}のメタデータを取得します。"
echo "subscription-managerやrepoの永続設定は変更しません。"

if [[ ${#ENABLED_REPOSITORIES[@]} -gt 0 ]]; then
    echo "引数で有効化するrepo:"
    printf '  %s\n' "${ENABLED_REPOSITORIES[@]}"
else
    echo "引数で有効化するrepo: なし"
fi

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    echo "引数で無効化するrepo:"
    printf '  %s\n' "${DISABLED_REPOSITORIES[@]}"
else
    echo "引数で無効化するrepo: なし"
fi

rhel_dnf -y --refresh makecache 2>&1 \
    | tee "${WORK_DIR}/state/dnf-rhel-makecache.log"

rhel_dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-target-repositories.txt" 2>&1
rhel_dnf -q module list --enabled \
    > "${WORK_DIR}/state/enabled-modules.txt" 2>&1 || true
rhel_dnf -q versionlock list \
    > "${WORK_DIR}/state/versionlocks.txt" 2>&1 || true
rhel_dnf -q list --available redhat-release kernel-core \
    > "${WORK_DIR}/state/available-target-packages.txt" 2>&1 || true

grep -RhsE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=' \
    /etc/dnf/dnf.conf /etc/yum.repos.d 2>/dev/null \
    > "${WORK_DIR}/state/dnf-excludes.txt" || true
rpm -q kernel kernel-core kernel-modules kernel-modules-extra \
    > "${WORK_DIR}/state/kernels-before.txt" 2>&1 || true
package_list > "${WORK_DIR}/state/installed-before-download.txt"

echo "RHEL ${SOURCE_VERSION}から${TARGET_VERSION}までの更新RPMをダウンロードします。"
echo "この処理ではパッケージの更新は実行されません。"

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    echo "引数で指定されたパッケージ除外パターン:"
    printf '  %s\n' "${EXCLUDE_PATTERNS[@]}"
else
    echo "引数で指定されたパッケージ除外パターン: なし"
fi

DNF_UPGRADE_ARGS=(
    "${DNF_ARGS[@]}"
    "-y"
    "--refresh"
    "--best"
    "--downloadonly"
    "--destdir=${WORK_DIR}/rpms"
)

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    for exclude_pattern in "${EXCLUDE_PATTERNS[@]}"; do
        DNF_UPGRADE_ARGS+=("--exclude=${exclude_pattern}")
    done
fi

dnf "${DNF_UPGRADE_ARGS[@]}" upgrade 2>&1 \
    | tee "${WORK_DIR}/state/dnf-download.log"

# GPG鍵の自動インポートなどを含め、適用前に期待する状態を記録する。
package_list > "${WORK_DIR}/state/installed-baseline-for-apply.txt"

RPM_COUNT="$(
    find "${WORK_DIR}/rpms" -type f -name '*.rpm' | wc -l
)"
echo "${RPM_COUNT}" > "${WORK_DIR}/state/rpm-count.txt"
echo "ダウンロードRPM数: ${RPM_COUNT}"

if [[ "${RPM_COUNT}" -eq 0 ]]; then
    die "更新RPMが0件です。8.10コンテンツへのアクセスとrepo指定を確認してください。"
fi

(
    cd "${WORK_DIR}/rpms"
    find . -type f -name '*.rpm' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum
) > "${WORK_DIR}/state/SHA256SUMS"

find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
    | xargs -0 -r rpm -qp \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
    | LC_ALL=C sort \
    > "${WORK_DIR}/state/rpm-manifest.txt"

awk -F '\t' \
    '$1 == "kernel-core" && $2 ~ /[.]el8_10([.]|$)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/target-kernel-core-rpms.txt"

awk -F '\t' \
    '$1 == "redhat-release" && $2 ~ /(^|:)8[.]10-/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/target-redhat-release-rpms.txt"

if [[ ! -s "${WORK_DIR}/state/target-kernel-core-rpms.txt" ]]; then
    echo "ERROR: RHEL 8.10用kernel-core RPMがスナップショットに含まれていません。" >&2
    echo "8.10のBaseOS repo、exclude、versionlockを確認してください。" >&2
    exit 4
fi

if [[ ! -s "${WORK_DIR}/state/target-redhat-release-rpms.txt" ]]; then
    echo "ERROR: RHEL 8.10用redhat-release RPMがスナップショットに含まれていません。" >&2
    echo "8.8から8.10への更新スナップショットとして不完全なため中止します。" >&2
    exit 4
fi

SIGNATURE_LOG="${WORK_DIR}/state/rpm-signatures.txt"
if ! find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
    | LC_ALL=C xargs -0 -r rpm --checksig > "${SIGNATURE_LOG}" 2>&1; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "RPM署名の検証コマンドが失敗しました。"
fi

if signature_log_has_failure "${SIGNATURE_LOG}"; then
    sed -n '1,200p' "${SIGNATURE_LOG}"
    die "署名を検証できないRPMが含まれています。"
fi

awk -F '\t' '$1 ~ /^kernel($|-)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/kernel-rpms.txt"

rm -rf -- "${DNF_CACHE_DIR}"
mv "${WORK_DIR}" "${FINAL_DIR}"
WORK_DIR=""

echo "RPMを永続保存用tarファイルにまとめます。"
tar -C "${BASE_DIR}" -cf "${ARCHIVE}" "${SNAPSHOT_NAME}"

(
    cd "${BASE_DIR}"
    sha256sum "${SNAPSHOT_NAME}.tar" \
        > "${SNAPSHOT_NAME}.tar.sha256"
)

rm -rf -- "${FINAL_DIR}"
trap - EXIT

echo
echo "RHEL ${SOURCE_VERSION}から${TARGET_VERSION}への更新スナップショットの作成が完了しました。"
echo "アーカイブ : ${ARCHIVE}"
echo "チェックサム: ${ARCHIVE}.sha256"
echo
echo "subscription-managerやrepoの永続設定は変更していません。"
echo "Red Hat RPMを含むため、契約・組織のポリシーに従って安全に保管してください。"
