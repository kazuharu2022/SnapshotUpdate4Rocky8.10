#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly TARGET_VERSION="8.10"
readonly ROCKY_MIRRORLIST="https://mirrors.rockylinux.org/mirrorlist"
readonly BASE_DIR="/var/lib/rocky-update-snapshots"
readonly ROCKY_GPG_KEY="/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial"

SNAPSHOT_REPOSITORY_IDS=(
    "rocky-8.10-installroot-baseos"
    "rocky-8.10-installroot-appstream"
    "rocky-8.10-installroot-extras"
)

usage()
{
    cat <<'USAGE_EOF'
使用方法:
  sudo ./capture-rocky8.10-installroot-snapshot.sh \
    --installroot /absolute/path/to/rocky8.10-rootfs \
    [OPTIONS]

オプション:
      --installroot PATH   基準にするPXE用Rocky Linux 8.10 rootfs
      --installroot=PATH   同上
  -x, --exclude PATTERN    DNF/YUMの更新対象からPATTERNを除外する
      --exclude=PATTERN    同上
      --disablerepo REPOID REPOIDを取得対象から明示的に除外する
      --disablerepo=REPOID 同上
  -h, --help               このヘルプを表示する

除外オプションは複数指定できます。リポジトリIDはカンマ区切りにも対応します。
ワイルドカードは引用符で囲んでください。

一時リポジトリID:
  rocky-8.10-installroot-baseos
  rocky-8.10-installroot-appstream
  rocky-8.10-installroot-extras

installroot内の/etc/yum.repos.d/*.repoは常に取得対象から隔離されます。
そこに定義されたrepo IDも--disablerepoへ指定できますが、指定しなくても
取得処理では使用されません。repo IDは[name]の角括弧内であり、name=の値ではありません。

例:
  sudo ./capture-rocky8.10-installroot-snapshot.sh \
    --installroot /srv/pxe/rocky8-rootfs \
    --disablerepo rocky-8.10-installroot-extras

この処理はrootfsのパッケージを更新しません。
rootfsのRPM DBを基準に、利用可能な8.10更新RPMだけを保存します。
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

INSTALLROOT_INPUT=""
EXCLUDE_PATTERNS=()
DISABLED_REPOSITORIES=()
EXCLUDE_PATTERN_COUNT=0
DISABLED_REPOSITORY_COUNT=0

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
        -x|--exclude)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "ERROR: $1 には空でない除外パターンが必要です。" >&2
                exit 2
            fi
            EXCLUDE_PATTERNS[${EXCLUDE_PATTERN_COUNT}]="$2"
            EXCLUDE_PATTERN_COUNT=$((EXCLUDE_PATTERN_COUNT + 1))
            shift 2
            ;;
        --exclude=*)
            exclude_pattern="${1#--exclude=}"
            if [[ -z "${exclude_pattern}" ]]; then
                echo "ERROR: --exclude には空でない除外パターンが必要です。" >&2
                exit 2
            fi
            EXCLUDE_PATTERNS[${EXCLUDE_PATTERN_COUNT}]="${exclude_pattern}"
            EXCLUDE_PATTERN_COUNT=$((EXCLUDE_PATTERN_COUNT + 1))
            shift
            ;;
        --disablerepo)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES[${DISABLED_REPOSITORY_COUNT}]="$2"
            DISABLED_REPOSITORY_COUNT=$((DISABLED_REPOSITORY_COUNT + 1))
            shift 2
            ;;
        --disablerepo=*)
            disabled_repository="${1#--disablerepo=}"
            if [[ -z "${disabled_repository}" ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES[${DISABLED_REPOSITORY_COUNT}]="${disabled_repository}"
            DISABLED_REPOSITORY_COUNT=$((DISABLED_REPOSITORY_COUNT + 1))
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

if [[ -z "${INSTALLROOT_INPUT}" ]]; then
    usage >&2
    exit 2
fi

if [[ "${INSTALLROOT_INPUT}" != /* ]]; then
    die "--installrootには絶対パスを指定してください: ${INSTALLROOT_INPUT}"
fi

if [[ "${INSTALLROOT_INPUT}" == *$'\n'* || "${INSTALLROOT_INPUT}" == *$'\r'* ]]; then
    die "--installrootのパスに改行は使用できません。"
fi

for ((option_index = 0; option_index < EXCLUDE_PATTERN_COUNT; option_index++)); do
    option_value="${EXCLUDE_PATTERNS[${option_index}]}"
    if [[ "${option_value}" == *$'\n'* || "${option_value}" == *$'\r'* ]]; then
        die "除外指定に改行は使用できません。"
    fi
done

for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
    option_value="${DISABLED_REPOSITORIES[${option_index}]}"
    if [[ "${option_value}" == *$'\n'* || "${option_value}" == *$'\r'* ]]; then
        die "除外指定に改行は使用できません。"
    fi
done

if [[ "${EUID}" -ne 0 ]]; then
    die "rootで実行してください。"
fi

for command_name in \
    awk cat chroot cmp comm cp date dnf find grep head mkdir mktemp mv readlink rm rpm sed sha256sum sort tail tar tee uname wc xargs
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

INSTALLROOT_ROCKY_VERSION="$(
    rpm --root "${INSTALLROOT}" -q rocky-release \
        --qf '%{VERSION}\n' 2>/dev/null \
        | LC_ALL=C sort -u
)"
if [[ "${INSTALLROOT_ROCKY_VERSION}" != "${TARGET_VERSION}" ]]; then
    die "installrootのrocky-release RPMが${TARGET_VERSION}ではありません: ${INSTALLROOT_ROCKY_VERSION:-未検出}"
fi

INSTALLROOT_OS_RELEASE=""
INSTALLROOT_OS_ID=""
INSTALLROOT_OS_VERSION=""
if INSTALLROOT_OS_RELEASE="$(
    chroot "${INSTALLROOT}" /bin/cat /etc/os-release 2>/dev/null
)"; then
    INSTALLROOT_OS_ID="$(
        printf '%s\n' "${INSTALLROOT_OS_RELEASE}" | os_release_value ID
    )"
    INSTALLROOT_OS_VERSION="$(
        printf '%s\n' "${INSTALLROOT_OS_RELEASE}" | os_release_value VERSION_ID
    )"
fi

if [[ -n "${INSTALLROOT_OS_ID}" && "${INSTALLROOT_OS_ID}" != "rocky" ]]; then
    die "installroot内/etc/os-releaseのIDがRocky Linuxではありません: ${INSTALLROOT_OS_ID}"
fi

if [[ -n "${INSTALLROOT_OS_VERSION}" ]] \
    && [[ "${INSTALLROOT_OS_VERSION}" != "${TARGET_VERSION}" ]]; then
    die "installroot内/etc/os-releaseのVERSION_IDが${TARGET_VERSION}ではありません: ${INSTALLROOT_OS_VERSION}"
fi

INSTALLED_KERNELS="$(
    rpm --root "${INSTALLROOT}" -q kernel-core \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' 2>/dev/null \
        | awk -F '\t' '$1 == "kernel-core" && $2 ~ /[.]el8_10([.]|$)/ {print}' \
        | LC_ALL=C sort -V
)"
if [[ -z "${INSTALLED_KERNELS}" ]]; then
    die "installrootにRocky Linux 8.10用kernel-core（.el8_10）がありません。"
fi

INSTALLROOT_GPG_KEY_PATH="${INSTALLROOT}${ROCKY_GPG_KEY}"
INSTALLROOT_GPG_KEY="$(readlink -f -- "${INSTALLROOT_GPG_KEY_PATH}" 2>/dev/null || true)"
if [[ -z "${INSTALLROOT_GPG_KEY}" ]] \
    || [[ "${INSTALLROOT_GPG_KEY}" != "${INSTALLROOT}/"* ]] \
    || [[ ! -f "${INSTALLROOT_GPG_KEY}" ]] \
    || [[ ! -r "${INSTALLROOT_GPG_KEY}" ]]; then
    die "installroot内のRocky Linux公式GPG鍵を安全に読み込めません: ${INSTALLROOT_GPG_KEY_PATH}"
fi

mkdir -p "${BASE_DIR}"

TIMESTAMP="$(TZ=Asia/Tokyo date +%Y%m%dT%H%M%S%z)"
SNAPSHOT_NAME="rocky8.10-installroot-update-${TIMESTAMP}"
WORK_DIR="$(mktemp -d "${BASE_DIR}/.${SNAPSHOT_NAME}.work.XXXXXX")"
FINAL_DIR="${BASE_DIR}/${SNAPSHOT_NAME}"
ARCHIVE="${BASE_DIR}/${SNAPSHOT_NAME}.tar"
REPO_DIR="${WORK_DIR}/repo-config"
DNF_CONFIG="${WORK_DIR}/dnf.conf"
SNAPSHOT_GPG_KEY="${WORK_DIR}/RPM-GPG-KEY-rockyofficial"
INSTALLROOT_REPOSITORY_IDS="${WORK_DIR}/state/installroot-repository-ids.txt"
CACHE_RELATIVE="/var/cache/dnf/.${SNAPSHOT_NAME}.capture.$$"
LOG_RELATIVE="/var/log/.${SNAPSHOT_NAME}.capture.$$"
CACHE_HOST_PATH="${INSTALLROOT}${CACHE_RELATIVE}"
LOG_HOST_PATH="${INSTALLROOT}${LOG_RELATIVE}"

if [[ -e "${CACHE_HOST_PATH}" || -L "${CACHE_HOST_PATH}" \
    || -e "${LOG_HOST_PATH}" || -L "${LOG_HOST_PATH}" ]]; then
    die "installroot内の一時DNFパスが既に存在します。再実行してください。"
fi

cleanup()
{
    local exit_status=$?

    if [[ -n "${CACHE_HOST_PATH:-}" ]]; then
        rm -rf -- "${CACHE_HOST_PATH}"
    fi
    if [[ -n "${LOG_HOST_PATH:-}" ]]; then
        rm -rf -- "${LOG_HOST_PATH}"
    fi
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
    "${REPO_DIR}"

cp -p "${INSTALLROOT_GPG_KEY}" "${SNAPSHOT_GPG_KEY}"

printf '%s\n' \
    'snapshot_format=2' \
    'snapshot_kind=rocky-installroot-update' \
    "source_version=${TARGET_VERSION}" \
    "target_version=${TARGET_VERSION}" \
    > "${WORK_DIR}/state/snapshot-contract.txt"

printf '%s\n' "${INSTALLROOT}" \
    > "${WORK_DIR}/state/source-installroot.txt"

: > "${WORK_DIR}/state/requested-excludes.txt"
for ((option_index = 0; option_index < EXCLUDE_PATTERN_COUNT; option_index++)); do
    printf '%s\n' "${EXCLUDE_PATTERNS[${option_index}]}" \
        >> "${WORK_DIR}/state/requested-excludes.txt"
done

: > "${WORK_DIR}/state/requested-disabled-repositories.txt"
for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
    printf '%s\n' "${DISABLED_REPOSITORIES[${option_index}]}" \
        >> "${WORK_DIR}/state/requested-disabled-repositories.txt"
done

: > "${INSTALLROOT_REPOSITORY_IDS}"
if [[ -d "${INSTALLROOT}/etc/yum.repos.d" ]]; then
    while IFS= read -r -d '' installroot_repo_file; do
        awk '
            {
                line = $0
                sub(/\r$/, "", line)
                if (line !~ /^[[:space:]]*\[[[:alnum:]_.:-]+\][[:space:]]*$/) {
                    next
                }
                sub(/^[[:space:]]*\[/, "", line)
                sub(/\][[:space:]]*$/, "", line)
                print line
            }
        ' "${installroot_repo_file}"
    done < <(
        find "${INSTALLROOT}/etc/yum.repos.d" \
            -maxdepth 1 -type f -name '*.repo' -print0
    ) | LC_ALL=C sort -u > "${INSTALLROOT_REPOSITORY_IDS}"
fi

repository_id_matches_pattern()
{
    local repository_id="$1"
    local repository_pattern="$2"

    case "${repository_id}" in
        ${repository_pattern}) return 0 ;;
        *) return 1 ;;
    esac
}

repository_pattern_is_known()
{
    local repository_pattern="$1"
    local repository_id=""

    for repository_id in "${SNAPSHOT_REPOSITORY_IDS[@]}"; do
        if repository_id_matches_pattern "${repository_id}" "${repository_pattern}"; then
            return 0
        fi
    done

    while IFS= read -r repository_id; do
        if [[ -n "${repository_id}" ]] \
            && repository_id_matches_pattern "${repository_id}" "${repository_pattern}"; then
            return 0
        fi
    done < "${INSTALLROOT_REPOSITORY_IDS}"

    return 1
}

repository_id_is_disabled()
{
    local repository_id="$1"
    local option_index=0
    local pattern_list=""
    local repository_pattern=""

    for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
        pattern_list="${DISABLED_REPOSITORIES[${option_index}]},"
        while [[ -n "${pattern_list}" ]]; do
            repository_pattern="${pattern_list%%,*}"
            pattern_list="${pattern_list#*,}"
            if [[ -n "${repository_pattern}" ]] \
                && repository_id_matches_pattern "${repository_id}" "${repository_pattern}"; then
                return 0
            fi
        done
    done

    return 1
}

for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
    pattern_list="${DISABLED_REPOSITORIES[${option_index}]},"
    while [[ -n "${pattern_list}" ]]; do
        repository_pattern="${pattern_list%%,*}"
        pattern_list="${pattern_list#*,}"
        if [[ -z "${repository_pattern}" ]]; then
            die "--disablerepoに空のリポジトリIDが含まれています。"
        fi
        if ! repository_pattern_is_known "${repository_pattern}"; then
            die "--disablerepoに指定されたrepo IDまたはglobが見つかりません: ${repository_pattern}（name=ではなく[repo ID]を指定してください）"
        fi
    done
done

cat > "${DNF_CONFIG}" <<'DNF_CONFIG_EOF'
[main]
gpgcheck=True
repo_gpgcheck=False
plugins=False
best=True
skip_if_unavailable=False
keepcache=True
DNF_CONFIG_EOF

cat > "${REPO_DIR}/Rocky-8.10-Installroot.repo" <<REPO_EOF
[rocky-8.10-installroot-baseos]
name=Rocky Linux 8.10 - Installroot Snapshot - BaseOS
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=BaseOS-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://${SNAPSHOT_GPG_KEY}
sslverify=1
skip_if_unavailable=0

[rocky-8.10-installroot-appstream]
name=Rocky Linux 8.10 - Installroot Snapshot - AppStream
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=AppStream-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://${SNAPSHOT_GPG_KEY}
sslverify=1
skip_if_unavailable=0

[rocky-8.10-installroot-extras]
name=Rocky Linux 8.10 - Installroot Snapshot - Extras
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=extras-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://${SNAPSHOT_GPG_KEY}
sslverify=1
skip_if_unavailable=0
REPO_EOF

DNF_ARGS=(
    "--installroot=${INSTALLROOT}"
    "--releasever=${TARGET_VERSION}"
    "--setopt=module_platform_id=platform:el8"
    "--config=${DNF_CONFIG}"
    "--setopt=reposdir=${REPO_DIR}"
    "--setopt=cachedir=${CACHE_RELATIVE}"
    "--setopt=logdir=${LOG_RELATIVE}"
    "--setopt=timeout=300"
    "--setopt=minrate=1"
    "--setopt=retries=20"
    "--setopt=max_parallel_downloads=1"
    "--noplugins"
    "--disablerepo=*"
)

ENABLED_SNAPSHOT_REPOSITORY_COUNT=0
for snapshot_repository_id in "${SNAPSHOT_REPOSITORY_IDS[@]}"; do
    if ! repository_id_is_disabled "${snapshot_repository_id}"; then
        DNF_ARGS+=("--enablerepo=${snapshot_repository_id}")
        ENABLED_SNAPSHOT_REPOSITORY_COUNT=$((ENABLED_SNAPSHOT_REPOSITORY_COUNT + 1))
    fi
done

if [[ ${ENABLED_SNAPSHOT_REPOSITORY_COUNT} -eq 0 ]]; then
    die "取得用のRocky Linuxリポジトリがすべて無効化されています。"
fi

snapshot_dnf()
{
    dnf "${DNF_ARGS[@]}" "$@"
}

package_list()
{
    rpm --root "${INSTALLROOT}" -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

echo "PXE用installrootのシステム情報とRPMベースラインを記録します。"

if [[ -n "${INSTALLROOT_OS_RELEASE}" ]]; then
    printf '%s\n' "${INSTALLROOT_OS_RELEASE}" \
        > "${WORK_DIR}/state/os-release.txt"
else
    : > "${WORK_DIR}/state/os-release.txt"
fi

printf '%s\n' "${INSTALLED_KERNELS}" \
    > "${WORK_DIR}/state/kernels-before.txt"

uname -a > "${WORK_DIR}/state/host-uname.txt"
dnf --version > "${WORK_DIR}/state/dnf-version.txt" 2>&1
cp -p "${REPO_DIR}/Rocky-8.10-Installroot.repo" \
    "${WORK_DIR}/state/Rocky-8.10-Installroot.repo"
cp -p "${DNF_CONFIG}" "${WORK_DIR}/state/dnf.conf"
sha256sum "${SNAPSHOT_GPG_KEY}" \
    > "${WORK_DIR}/state/rocky-gpg-key.sha256"

printf '%s\n' \
    "installroot=${INSTALLROOT}" \
    "releasever=${TARGET_VERSION}" \
    "module_platform_id=platform:el8" \
    "config=${DNF_CONFIG}" \
    "reposdir=${REPO_DIR}" \
    "cachedir=${CACHE_RELATIVE}" \
    "logdir=${LOG_RELATIVE}" \
    "disablerepo=*" \
    "installroot_repositories=not-loaded" \
    > "${WORK_DIR}/state/dnf-repository-isolation.txt"

for snapshot_repository_id in "${SNAPSHOT_REPOSITORY_IDS[@]}"; do
    if ! repository_id_is_disabled "${snapshot_repository_id}"; then
        printf 'enablerepo=%s\n' "${snapshot_repository_id}" \
            >> "${WORK_DIR}/state/dnf-repository-isolation.txt"
    fi
done

for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
    printf 'requested_disablerepo=%s\n' "${DISABLED_REPOSITORIES[${option_index}]}" \
        >> "${WORK_DIR}/state/dnf-repository-isolation.txt"
done

package_list > "${WORK_DIR}/state/installed-before-download.txt"

echo "ホストのrepo設定を参照せず、Rocky Linux ${TARGET_VERSION}のメタデータを取得します。"
echo "installroot内のrepo設定も取得対象から隔離します。"
if [[ ${DISABLED_REPOSITORY_COUNT} -gt 0 ]]; then
    echo "引数で明示的に除外するリポジトリ:"
    for ((option_index = 0; option_index < DISABLED_REPOSITORY_COUNT; option_index++)); do
        printf '  %s\n' "${DISABLED_REPOSITORIES[${option_index}]}"
    done
else
    echo "引数で明示的に除外するリポジトリ: なし"
fi

snapshot_dnf -y --refresh makecache 2>&1 \
    | tee "${WORK_DIR}/state/dnf-snapshot-makecache.log"

snapshot_dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-snapshot-repositories.txt" 2>&1

snapshot_dnf -q module list --enabled \
    > "${WORK_DIR}/state/enabled-modules.txt" 2>&1 || true

echo "installrootの現在状態からRocky Linux ${TARGET_VERSION}更新RPMをダウンロードします。"
echo "この処理ではinstallrootのパッケージを更新しません。"
if [[ ${EXCLUDE_PATTERN_COUNT} -gt 0 ]]; then
    echo "引数で指定された除外パターン:"
    for ((option_index = 0; option_index < EXCLUDE_PATTERN_COUNT; option_index++)); do
        printf '  %s\n' "${EXCLUDE_PATTERNS[${option_index}]}"
    done
else
    echo "引数で指定された除外パターン: なし"
fi

DNF_UPGRADE_ARGS=(
    "-y"
    "--refresh"
    "--best"
    "--downloadonly"
    "--destdir=${WORK_DIR}/rpms"
)
for ((option_index = 0; option_index < EXCLUDE_PATTERN_COUNT; option_index++)); do
    DNF_UPGRADE_ARGS+=("--exclude=${EXCLUDE_PATTERNS[${option_index}]}")
done
DNF_UPGRADE_ARGS+=("upgrade")

snapshot_dnf "${DNF_UPGRADE_ARGS[@]}" 2>&1 \
    | tee "${WORK_DIR}/state/dnf-download.log"

package_list > "${WORK_DIR}/state/installed-baseline-for-apply.txt"

awk -F '\t' '$1 != "gpg-pubkey" {print}' \
    "${WORK_DIR}/state/installed-before-download.txt" \
    > "${WORK_DIR}/state/installed-before-download-without-gpg-keys.txt"
awk -F '\t' '$1 != "gpg-pubkey" {print}' \
    "${WORK_DIR}/state/installed-baseline-for-apply.txt" \
    > "${WORK_DIR}/state/installed-baseline-without-gpg-keys.txt"

if ! cmp -s \
    "${WORK_DIR}/state/installed-before-download-without-gpg-keys.txt" \
    "${WORK_DIR}/state/installed-baseline-without-gpg-keys.txt"; then
    comm -3 \
        "${WORK_DIR}/state/installed-before-download-without-gpg-keys.txt" \
        "${WORK_DIR}/state/installed-baseline-without-gpg-keys.txt" \
        > "${WORK_DIR}/state/unexpected-package-change.diff" || true
    die "downloadonly処理中にinstallrootのパッケージ状態が変化しました。"
fi

RPM_COUNT="$(
    find "${WORK_DIR}/rpms" -type f -name '*.rpm' | wc -l
)"
echo "${RPM_COUNT}" > "${WORK_DIR}/state/rpm-count.txt"
echo "ダウンロードRPM数: ${RPM_COUNT}"

if [[ "${RPM_COUNT}" -eq 0 ]]; then
    die "取得対象の更新RPMがありません。installrootは指定repoの最新状態です。"
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
    '$1 == "rocky-release" && $2 ~ /(^|:)8[.]10-/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/target-rocky-release-rpms.txt"

if [[ -s "${WORK_DIR}/state/target-kernel-core-rpms.txt" ]]; then
    LC_ALL=C sort -V "${WORK_DIR}/state/target-kernel-core-rpms.txt" \
        | tail -n 1 \
        > "${WORK_DIR}/state/boot-kernel-core-rpms.txt"
else
    awk -F '\t' \
        '$1 == "kernel-core" && $2 ~ /[.]el8_10([.]|$)/ {print}' \
        "${WORK_DIR}/state/installed-baseline-for-apply.txt" \
        | LC_ALL=C sort -V \
        | tail -n 1 \
        > "${WORK_DIR}/state/boot-kernel-core-rpms.txt"
fi

if [[ ! -s "${WORK_DIR}/state/boot-kernel-core-rpms.txt" ]]; then
    die "PXEブート確認対象のRocky Linux 8.10 kernel-coreを決定できません。"
fi

RPM_SIGNATURE_LOG="${WORK_DIR}/state/rpm-signatures.txt"
SIGNATURE_DB="${WORK_DIR}/signature-rpmdb"
mkdir -p "${SIGNATURE_DB}"
rpm --dbpath "${SIGNATURE_DB}" --initdb
rpm --dbpath "${SIGNATURE_DB}" --import "${SNAPSHOT_GPG_KEY}"

mapfile -d '' -t RPM_FILES < <(
    find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
        | LC_ALL=C sort -z
)
if ! LC_ALL=C rpm --dbpath "${SIGNATURE_DB}" --checksig "${RPM_FILES[@]}" \
    > "${RPM_SIGNATURE_LOG}" 2>&1; then
    sed -n '1,200p' "${RPM_SIGNATURE_LOG}"
    die "ダウンロードRPMの署名検証コマンドが失敗しました。"
fi

if signature_log_has_failure "${RPM_SIGNATURE_LOG}"; then
    sed -n '1,200p' "${RPM_SIGNATURE_LOG}"
    die "署名を検証できないRPMが含まれています。"
fi

awk -F '\t' '$1 ~ /^kernel($|-)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/kernel-rpms.txt"

rm -rf -- "${CACHE_HOST_PATH}" "${LOG_HOST_PATH}" "${SIGNATURE_DB}"

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
echo "Rocky Linux ${TARGET_VERSION} installroot更新スナップショットの作成が完了しました。"
echo "基準rootfs : ${INSTALLROOT}"
echo "アーカイブ : ${ARCHIVE}"
echo "チェックサム: ${ARCHIVE}.sha256"
echo
echo "ホストOSとinstallrootのパッケージは更新していません。"
echo "この2ファイルを同じ場所に保管してください。"
