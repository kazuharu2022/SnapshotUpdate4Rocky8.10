#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

EXPECTED_DATE="20260925"
CURRENT_DATE="$(TZ=Asia/Tokyo date +%Y%m%d)"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: rootで実行してください。"
    exit 1
fi

if [[ "${CURRENT_DATE}" != "${EXPECTED_DATE}" ]]; then
    echo "ERROR: このスクリプトは2026年9月25日（日本時間）専用です。"
    echo "現在の日付: ${CURRENT_DATE}"
    exit 1
fi

if ! grep -Eq '^Rocky Linux release 8\.10' /etc/rocky-release; then
    echo "ERROR: Rocky Linux 8.10ではありません。"
    cat /etc/rocky-release 2>/dev/null || true
    exit 1
fi

BASE_DIR="/var/lib/rocky-update-snapshots"
mkdir -p "${BASE_DIR}"
TIMESTAMP="$(TZ=Asia/Tokyo date +%Y%m%dT%H%M%S%z)"
SNAPSHOT_NAME="rocky8.10-update-${TIMESTAMP}"
WORK_DIR="$(mktemp -d "${BASE_DIR}/.${SNAPSHOT_NAME}.work.XXXXXX")"
FINAL_DIR="${BASE_DIR}/${SNAPSHOT_NAME}"
ARCHIVE="${BASE_DIR}/${SNAPSHOT_NAME}.tar"

mkdir -p "${BASE_DIR}"
mkdir -p "${WORK_DIR}/rpms" "${WORK_DIR}/state"

package_list()
{
    rpm -qa \
        --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
        | LC_ALL=C sort
}

echo "システム情報を記録します。"

cat /etc/rocky-release \
    > "${WORK_DIR}/state/rocky-release.txt"

uname -a \
    > "${WORK_DIR}/state/uname-before.txt"

dnf --version \
    > "${WORK_DIR}/state/dnf-version.txt" 2>&1

dnf repolist --enabled \
    > "${WORK_DIR}/state/enabled-repositories.txt" 2>&1

dnf -q module list --enabled \
    > "${WORK_DIR}/state/enabled-modules.txt" 2>&1 || true

dnf -q versionlock list \
    > "${WORK_DIR}/state/versionlocks.txt" 2>&1 || true

grep -RhsE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=' \
    /etc/dnf/dnf.conf /etc/yum.repos.d 2>/dev/null \
    > "${WORK_DIR}/state/dnf-excludes.txt" || true

rpm -q kernel kernel-core kernel-modules kernel-modules-extra \
    > "${WORK_DIR}/state/kernels-before.txt" 2>&1 || true

package_list \
    > "${WORK_DIR}/state/installed-before-download.txt"

echo "2026年9月25日時点の更新RPMをダウンロードします。"
echo "この処理ではパッケージの更新は実行されません。"

dnf -y \
    --refresh \
    --best \
    --downloadonly \
    --destdir="${WORK_DIR}/rpms" \
    upgrade 2>&1 \
    | tee "${WORK_DIR}/state/dnf-download.log"

# GPG鍵の自動インポートなどを含め、適用前に期待する状態を記録する
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

# 署名・ダイジェスト状態を記録
find "${WORK_DIR}/rpms" -type f -name '*.rpm' -print0 \
    | xargs -0 -r rpm --checksig \
    > "${WORK_DIR}/state/rpm-signatures.txt" 2>&1 || true

# カーネル関連RPMを抽出
awk -F '\t' '$1 ~ /^kernel($|-)/ {print}' \
    "${WORK_DIR}/state/rpm-manifest.txt" \
    > "${WORK_DIR}/state/kernel-rpms.txt"

mv "${WORK_DIR}" "${FINAL_DIR}"

echo "RPMを永続保存用tarファイルにまとめます。"

tar -C "${BASE_DIR}" \
    -cf "${ARCHIVE}" \
    "${SNAPSHOT_NAME}"

(
    cd "${BASE_DIR}"
    sha256sum "${SNAPSHOT_NAME}.tar" \
        > "${SNAPSHOT_NAME}.tar.sha256"
)

# tarが完成したので展開ディレクトリを削除
rm -rf -- "${FINAL_DIR}"

echo
echo "スナップショットの作成が完了しました。"
echo "アーカイブ : ${ARCHIVE}"
echo "チェックサム: ${ARCHIVE}.sha256"
echo
echo "この2ファイルをバックアップ領域にも保存してください。"
