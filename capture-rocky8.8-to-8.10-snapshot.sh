#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SOURCE_VERSION="8.8"
readonly TARGET_VERSION="8.10"
readonly ROCKY_MIRRORLIST="https://mirrors.rockylinux.org/mirrorlist"
readonly BASE_DIR="/var/lib/rocky-update-snapshots"
readonly ROCKY_GPG_KEY="/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial"

usage()
{
    cat <<'USAGE_EOF'
使用方法:
  sudo ./capture-rocky8.8-to-8.10-snapshot.sh [OPTIONS]

オプション:
  -x, --exclude PATTERN     DNF/YUMの更新対象からPATTERNを除外する
      --exclude=PATTERN     同上
      --disablerepo REPOID  一時リポジトリからREPOIDを無効化する
      --disablerepo=REPOID  同上
  -h, --help                このヘルプを表示する

各オプションは複数指定できます。リポジトリIDはカンマ区切りにも対応します。
ワイルドカードは引用符で囲んでください。
例:
  sudo ./capture-rocky8.8-to-8.10-snapshot.sh \
    --exclude 'podman*' \
    --exclude='java-1.8.0-openjdk*' \
    --disablerepo rocky-8.10-snapshot-extras

一時リポジトリID:
  rocky-8.10-snapshot-baseos
  rocky-8.10-snapshot-appstream
  rocky-8.10-snapshot-extras
USAGE_EOF
}

EXCLUDE_PATTERNS=()
DISABLED_REPOSITORIES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--exclude)
            if [[ $# -lt 2 || -z "$2" ]]; then
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
        --disablerepo)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES+=("$2")
            shift 2
            ;;
        --disablerepo=*)
            disabled_repository="${1#--disablerepo=}"
            if [[ -z "${disabled_repository}" ]]; then
                echo "ERROR: --disablerepo には空でないリポジトリIDが必要です。" >&2
                exit 2
            fi
            DISABLED_REPOSITORIES+=("${disabled_repository}")
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

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    for disabled_repository in "${DISABLED_REPOSITORIES[@]}"; do
        if [[ "${disabled_repository}" == *$'\n'* || "${disabled_repository}" == *$'\r'* ]]; then
            echo "ERROR: リポジトリIDに改行は使用できません。" >&2
            exit 2
        fi
    done
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: rootで実行してください。"
    exit 1
fi

if ! grep -Eq '^Rocky Linux release 8\.8([[:space:]]|$)' /etc/rocky-release; then
    echo "ERROR: 更新元がRocky Linux ${SOURCE_VERSION}ではありません。"
    cat /etc/rocky-release 2>/dev/null || true
    exit 1
fi

for command_name in \
    awk cat cp date dnf find grep mktemp mv rm rpm sha256sum sort tar tee uname wc xargs
do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "ERROR: 必要なコマンドが見つかりません: ${command_name}"
        exit 1
    fi
done

if [[ ! -r "${ROCKY_GPG_KEY}" ]]; then
    echo "ERROR: Rocky Linux公式GPG鍵を読み込めません。"
    echo "${ROCKY_GPG_KEY}"
    exit 1
fi

mkdir -p "${BASE_DIR}"

TIMESTAMP="$(TZ=Asia/Tokyo date +%Y%m%dT%H%M%S%z)"
SNAPSHOT_NAME="rocky${SOURCE_VERSION}-to-${TARGET_VERSION}-update-${TIMESTAMP}"
WORK_DIR="$(mktemp -d "${BASE_DIR}/.${SNAPSHOT_NAME}.work.XXXXXX")"
FINAL_DIR="${BASE_DIR}/${SNAPSHOT_NAME}"
ARCHIVE="${BASE_DIR}/${SNAPSHOT_NAME}.tar"
REPO_DIR="${WORK_DIR}/repo-config"
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
    "${REPO_DIR}" \
    "${DNF_CACHE_DIR}"

printf '%s\n' \
    'snapshot_format=1' \
    "source_version=${SOURCE_VERSION}" \
    "target_version=${TARGET_VERSION}" \
    > "${WORK_DIR}/state/snapshot-contract.txt"

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    printf '%s\n' "${EXCLUDE_PATTERNS[@]}" \
        > "${WORK_DIR}/state/requested-excludes.txt"
else
    : > "${WORK_DIR}/state/requested-excludes.txt"
fi

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    printf '%s\n' "${DISABLED_REPOSITORIES[@]}" \
        > "${WORK_DIR}/state/requested-disabled-repositories.txt"
else
    : > "${WORK_DIR}/state/requested-disabled-repositories.txt"
fi

cat > "${REPO_DIR}/Rocky-8.10-Snapshot.repo" <<REPO_EOF
[rocky-8.10-snapshot-baseos]
name=Rocky Linux 8.10 - Snapshot - BaseOS
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=BaseOS-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial
sslverify=1
skip_if_unavailable=0

[rocky-8.10-snapshot-appstream]
name=Rocky Linux 8.10 - Snapshot - AppStream
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=AppStream-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial
sslverify=1
skip_if_unavailable=0

[rocky-8.10-snapshot-extras]
name=Rocky Linux 8.10 - Snapshot - Extras
mirrorlist=${ROCKY_MIRRORLIST}?arch=\$basearch&repo=extras-8
enabled=0
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial
sslverify=1
skip_if_unavailable=0
REPO_EOF

# /etc/yum.repos.d を一切参照せず、上で作成した8.10 repoだけを有効化する。
DNF_REPO_ARGS=(
    "--setopt=reposdir=${REPO_DIR}"
    "--setopt=cachedir=${DNF_CACHE_DIR}"
    "--setopt=timeout=300"
    "--setopt=minrate=1"
    "--setopt=retries=20"
    "--setopt=max_parallel_downloads=1"
    "--disablerepo=*"
    "--enablerepo=rocky-8.10-snapshot-baseos"
    "--enablerepo=rocky-8.10-snapshot-appstream"
    "--enablerepo=rocky-8.10-snapshot-extras"
)

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    for disabled_repository in "${DISABLED_REPOSITORIES[@]}"; do
        DNF_REPO_ARGS+=("--disablerepo=${disabled_repository}")
    done
fi

DNF_EXCLUDE_ARGS=()
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    for exclude_pattern in "${EXCLUDE_PATTERNS[@]}"; do
        DNF_EXCLUDE_ARGS+=("--exclude=${exclude_pattern}")
    done
fi

snapshot_dnf()
{
    dnf "${DNF_REPO_ARGS[@]}" "$@"
}

package_list()
{
    rpm -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

echo "システム情報と現在の有効repoを記録します。"

cat /etc/rocky-release \
    > "${WORK_DIR}/state/rocky-release.txt"

uname -a \
    > "${WORK_DIR}/state/uname-before.txt"

dnf --version \
    > "${WORK_DIR}/state/dnf-version.txt" 2>&1

# 切り替え前のrepo状態を証跡として保存する。
dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-repositories-before.txt" 2>&1 || true

cp -p "${REPO_DIR}/Rocky-8.10-Snapshot.repo" \
    "${WORK_DIR}/state/Rocky-8.10-Snapshot.repo"

sha256sum "${ROCKY_GPG_KEY}" \
    > "${WORK_DIR}/state/rocky-gpg-key.sha256"

rpm -q rocky-gpg-keys rocky-repos rocky-release \
    > "${WORK_DIR}/state/rocky-repository-packages.txt" 2>&1 || true

printf '%s\n' \
    "reposdir=${REPO_DIR}" \
    "cachedir=${DNF_CACHE_DIR}" \
    "timeout=300" \
    "minrate=1" \
    "retries=20" \
    "max_parallel_downloads=1" \
    "disablerepo=*" \
    "enablerepo=rocky-8.10-snapshot-baseos" \
    "enablerepo=rocky-8.10-snapshot-appstream" \
    "enablerepo=rocky-8.10-snapshot-extras" \
    > "${WORK_DIR}/state/dnf-repository-isolation.txt"

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    for disabled_repository in "${DISABLED_REPOSITORIES[@]}"; do
        printf 'disablerepo=%s\n' "${disabled_repository}" \
            >> "${WORK_DIR}/state/dnf-repository-isolation.txt"
    done
fi

echo "標準repo設定の参照を無効化し、Rocky Linux ${TARGET_VERSION}のメタデータを取得します。"

if [[ ${#DISABLED_REPOSITORIES[@]} -gt 0 ]]; then
    echo "引数で無効化する一時リポジトリ:"
    printf '  %s\n' "${DISABLED_REPOSITORIES[@]}"
else
    echo "引数で無効化する一時リポジトリ: なし"
fi

snapshot_dnf -y --refresh makecache 2>&1 \
    | tee "${WORK_DIR}/state/dnf-snapshot-makecache.log"

snapshot_dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-snapshot-repositories.txt" 2>&1

snapshot_dnf -q module list --enabled \
    > "${WORK_DIR}/state/enabled-modules.txt" 2>&1 || true

snapshot_dnf -q versionlock list \
    > "${WORK_DIR}/state/versionlocks.txt" 2>&1 || true

grep -RhsE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=' \
    /etc/dnf/dnf.conf /etc/yum.repos.d 2>/dev/null \
    > "${WORK_DIR}/state/dnf-excludes.txt" || true

rpm -q kernel kernel-core kernel-modules kernel-modules-extra \
    > "${WORK_DIR}/state/kernels-before.txt" 2>&1 || true

package_list \
    > "${WORK_DIR}/state/installed-before-download.txt"

echo "Rocky Linux ${SOURCE_VERSION}から${TARGET_VERSION}までの更新RPMをダウンロードします。"
echo "この処理ではパッケージの更新は実行されません。"

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    echo "引数で指定された除外パターン:"
    printf '  %s\n' "${EXCLUDE_PATTERNS[@]}"
else
    echo "引数で指定された除外パターン: なし"
fi

snapshot_dnf -y \
    --refresh \
    --best \
    --downloadonly \
    --destdir="${WORK_DIR}/rpms" \
    "${DNF_EXCLUDE_ARGS[@]}" \
    upgrade 2>&1 \
    | tee "${WORK_DIR}/state/dnf-download.log"

# GPG鍵の自動インポートなどを含め、適用前に期待する状態を記録する。
package_list \
    > "${WORK_DIR}/state/installed-baseline-for-apply.txt"

RPM_COUNT="$(
    find "${WORK_DIR}/rpms" -type f -name '*.rpm' | wc -l
)"
echo "${RPM_COUNT}" > "${WORK_DIR}/state/rpm-count.txt"

echo "ダウンロードRPM数: ${RPM_COUNT}"

# RPMごとのチェックサム
(
    cd "${WORK_DIR}/rpms"
    find . -type f -name '*.rpm' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum
) > "${WORK_DIR}/state/SHA256SUMS"

# RPMのNEVRA一覧
find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
    | xargs -0 -r rpm -qp \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
    | LC_ALL=C sort \
    > "${WORK_DIR}/state/rpm-manifest.txt"

# 8.10への更新用RPMが実際に取得できたことを必須条件とする。
awk -F '\t' \
    '$1 == "kernel-core" && $2 ~ /\.el8_10([.]|$)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/target-kernel-core-rpms.txt"

awk -F '\t' \
    '$1 == "rocky-release" && $2 ~ /(^|:)8[.]10-/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/target-rocky-release-rpms.txt"

if [[ ! -s "${WORK_DIR}/state/target-kernel-core-rpms.txt" ]]; then
    echo "ERROR: Rocky Linux 8.10用kernel-core RPMがスナップショットに含まれていません。"
    echo "repo設定、exclude、versionlockを確認してください。"
    exit 4
fi

if [[ ! -s "${WORK_DIR}/state/target-rocky-release-rpms.txt" ]]; then
    echo "ERROR: Rocky Linux 8.10用rocky-release RPMがスナップショットに含まれていません。"
    echo "8.8から8.10への更新スナップショットとして不完全なため中止します。"
    exit 4
fi

# 署名・ダイジェスト状態を記録
find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
    | xargs -0 -r rpm --checksig \
    > "${WORK_DIR}/state/rpm-signatures.txt" 2>&1 || true

# カーネル関連RPMを抽出
awk -F '\t' '$1 ~ /^kernel($|-)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/kernel-rpms.txt"

# DNFの一時キャッシュはスナップショットに含めない。
rm -rf -- "${DNF_CACHE_DIR}" "${REPO_DIR}"

mv "${WORK_DIR}" "${FINAL_DIR}"
WORK_DIR=""

echo "RPMを永続保存用tarファイルにまとめます。"

tar -C "${BASE_DIR}" \
    -cf "${ARCHIVE}" \
    "${SNAPSHOT_NAME}"

(
    cd "${BASE_DIR}"
    sha256sum "${SNAPSHOT_NAME}.tar" \
        > "${SNAPSHOT_NAME}.tar.sha256"
)

# tarが完成したので展開ディレクトリを削除する。
rm -rf -- "${FINAL_DIR}"
trap - EXIT

echo
echo "Rocky Linux ${SOURCE_VERSION}から${TARGET_VERSION}への更新スナップショットの作成が完了しました。"
echo "アーカイブ : ${ARCHIVE}"
echo "チェックサム: ${ARCHIVE}.sha256"
echo
echo "元の /etc/yum.repos.d 配下の設定は変更していません。"
echo "この2ファイルをバックアップ領域にも保存してください。"
