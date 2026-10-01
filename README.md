# Rocky Linux 8 / RHEL 8 更新RPMスナップショット

Rocky Linux 8.8またはRed Hat Enterprise Linux（RHEL）8.8で、8.10への更新に必要なRPMと検証情報を取得し、後からオフラインで適用するためのスクリプト群です。

ここでいう「スナップショット」は、更新RPMとパッケージ状態の記録です。ディスク全体、設定ファイル、ユーザーデータのバックアップや、更新前へ戻すロールバック機能ではありません。実行前にVMまたはストレージ側でも復旧手段を用意してください。

## スクリプトの使い分け

| スクリプト | 用途 |
| --- | --- |
| `capture-rocky8.8-to-8.10-snapshot.sh` | Rocky Linux 8.8から8.10へ更新するRPMを取得 |
| `apply-rocky8.8-to-8.10-snapshot.sh` | 上記スナップショットを検証し、Rocky Linux 8.8へオフライン適用 |
| `capture-rhel8.8-to-8.10-snapshot.sh` | RHEL 8.8から8.10へ更新するRPMを構成済みrepoから取得 |
| `apply-rhel8.8-to-8.10-snapshot.sh` | RHEL専用スナップショットを検証し、RHEL 8.8へオフライン適用 |
| `capture-rocky8.8-vault-snapshot.sh` | Rocky Linux 8.8 Vaultの最終状態までの更新RPMを取得。8.10には更新しない |
| `capture-rocky8-update-20260925.sh` | 2026年9月25日専用の旧取得スクリプト |
| `apply-rocky8-snapshot-update.sh` | 旧形式スナップショット用の汎用適用スクリプト |

Rocky用とRHEL用のスナップショットには互換性がありません。必ず同じディストリビューションの専用取得・適用スクリプトを組み合わせてください。

## 事前確認

取得元・適用先はいずれも、実行開始時点で対象ディストリビューションの8.8である必要があります。

```bash
# Rocky Linux
cat /etc/rocky-release

# RHEL
cat /etc/redhat-release

uname -r
```

Rocky Linux上では次のファイルが存在します。

```bash
test -r /etc/rocky-release
```

RHEL上では `/etc/os-release` の `ID=rhel` と `VERSION_ID=8.8` も確認されます。

スクリプトへ実行権限を付与します。

```bash
chmod +x \
  capture-rocky8.8-to-8.10-snapshot.sh \
  capture-rocky8.8-vault-snapshot.sh \
  apply-rocky8.8-to-8.10-snapshot.sh \
  capture-rhel8.8-to-8.10-snapshot.sh \
  apply-rhel8.8-to-8.10-snapshot.sh
```

## Rocky Linux 8.8から8.10へ更新する

### 1. 更新RPMを取得する

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh
```

このスクリプトは、既存の標準リポジトリ設定を変更せず、一時的なリポジトリ設定だけを使用します。Rocky Linux公式mirrorlistからBaseOS、AppStream、ExtrasのRocky Linux 8.10リポジトリを解決し、インストールは行わずに更新RPMを保存します。

低速回線向けに、タイムアウト、低速判定、再試行回数、並列ダウンロード数を調整しています。

### 2. 更新対象またはリポジトリを除外する

#### パッケージを除外する

DNF/YUM互換の次の指定方法を使用できます。

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh --exclude 'podman*'
sudo ./capture-rocky8.8-to-8.10-snapshot.sh --exclude='java-1.8.0-openjdk*'
sudo ./capture-rocky8.8-to-8.10-snapshot.sh -x 'kernel-tools*'
```

複数のパターンも同時に指定できます。

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh \
  --exclude 'podman*' \
  --exclude='java-1.8.0-openjdk*' \
  -x 'kernel-tools*'
```

シェルによるファイル名展開を避けるため、ワイルドカードを含むパターンはシングルクォートで囲んでください。指定したパターンはスナップショット内の `state/requested-excludes.txt` に1行ずつ記録されます。

注意事項:

- 除外指定は取得する更新RPMだけに適用され、インストール済みパッケージを削除するものではありません。
- 依存関係に必要なパッケージを除外すると、DNFの依存関係解決に失敗する場合があります。
- `kernel-core` または `rocky-release` の8.10版が取得できない除外指定は、8.10用スナップショットとして成立しないため失敗します。
- 使用可能な引数は `./capture-rocky8.8-to-8.10-snapshot.sh --help` で確認できます。

#### リポジトリを無効化する

`--disablerepo REPOID` または `--disablerepo=REPOID` を使用します。複数指定、カンマ区切り、引用符で囲んだワイルドカード指定に対応しています。

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh \
  --disablerepo rocky-8.10-snapshot-extras
```

パッケージ除外と組み合わせることもできます。

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh \
  --exclude 'podman*' \
  --disablerepo rocky-8.10-snapshot-extras
```

指定可能な一時リポジトリIDは次のとおりです。

- `rocky-8.10-snapshot-baseos`
- `rocky-8.10-snapshot-appstream`
- `rocky-8.10-snapshot-extras`

既存の `/etc/yum.repos.d` は最初から参照しないため、そこで定義されたリポジトリを指定する必要はありません。指定内容はスナップショット内の `state/requested-disabled-repositories.txt` に1行ずつ記録されます。

BaseOSを無効化すると、8.10の `kernel-core` や `rocky-release` を取得できず、完全な8.10更新スナップショットとして成立しない可能性があります。その場合は安全のため取得処理が失敗します。

### 3. 生成物を確認する

既定では次の2ファイルが生成されます。

```text
/var/lib/rocky-update-snapshots/rocky8.8-to-8.10-update-YYYYMMDD-HHMMSS.tar
/var/lib/rocky-update-snapshots/rocky8.8-to-8.10-update-YYYYMMDD-HHMMSS.tar.sha256
```

`.tar` と `.tar.sha256` は同じディレクトリで保管・転送してください。

アーカイブには、RPM、RPM一覧、各RPMのSHA-256、取得前のパッケージ状態、対象バージョン情報、パッケージ除外指定、リポジトリ無効化指定が含まれます。

### 4. スナップショットを適用する

取得後から適用前までの間に、対象ホストでRPMの追加・更新・削除を行わないでください。取得時のパッケージ状態と異なる場合、専用適用スクリプトはベースライン不一致として停止します。

例外として、スナップショットに保存されたkernel関連RPMを先に導入した場合だけ、自動検証後に適用を継続できます。許可条件はすべて満たす必要があります。

- 追加されたパッケージ名が `kernel` または `kernel-` で始まる
- 名前、Epoch、Version、Release、Architectureが保存済みRPMと一致する
- インストール済みRPMの不変ヘッダーIDが保存済みRPMと一致する
- installonly上限などで旧パッケージが削除されている場合は、同名・同一Architectureの保存済み新RPMが追加されている
- kernel関連以外の追加・更新・削除がない

条件を満たす場合も差分を `/var/log/rocky8.8-to-8.10-package-drift-*.diff` に保存し、外部repoを無効化したDNFテストトランザクションを実行してから適用します。条件外の差分は従来どおり終了コード3で停止します。この例外は旧形式用の `apply-rocky8-snapshot-update.sh` には適用されません。

```bash
sudo ./apply-rocky8.8-to-8.10-snapshot.sh \
  /var/lib/rocky-update-snapshots/rocky8.8-to-8.10-update-YYYYMMDD-HHMMSS.tar
```

適用前に次の検証を行います。

- 隣接する `.sha256` とアーカイブ本体の整合性
- アーカイブ内のパスとファイル種別
- 取得元8.8・対象8.10というスナップショット契約
- RPM一覧、件数、各RPMのSHA-256
- Rocky Linux 8.10の `kernel-core` と `rocky-release` の存在
- RPM署名
- 取得時と適用時のパッケージ状態
- オフラインDNFのテストトランザクション

検証後に更新内容が表示され、実際に適用する前に確認を求めます。8.8から8.10へのスナップショットには、旧 `apply-rocky8-snapshot-update.sh` を使用しないでください。

### 5. 再起動して確認する

適用スクリプトは自動再起動しません。適用完了後に再起動してください。

```bash
sudo reboot
```

再ログイン後に確認します。

```bash
cat /etc/rocky-release
uname -r
sudo dnf check
```

`cat /etc/rocky-release` がRocky Linux 8.10を、`uname -r` が `.el8_10` を含むカーネルを表示することを確認してください。

## RHEL 8.8から8.10へ更新する

### RHEL版の前提

RHEL版は、ホストにすでに構成されているRHSM、クラウドRHUI、またはRed Hat Satelliteのrepoを使用します。Red Hatのコンテンツへアクセスできる有効な購読またはクラウド契約と、RHEL 8.10コンテンツを提供するrepoが必要です。

RHEL専用適用スクリプトもRocky Linux版と同じ限定条件で、保存済みkernel関連RPMの先行導入を許可します。許可された場合も差分を `/var/log/rhel8.8-to-8.10-package-drift-*.diff` に記録し、オフラインDNFテストトランザクションを省略しません。

次を事前に確認してください。

```bash
cat /etc/redhat-release
uname -m
sudo dnf repolist --enabled

if command -v subscription-manager >/dev/null 2>&1; then
  sudo subscription-manager release --show
fi
```

このスクリプトは次の操作を行いません。

- RHSMへの登録や購読割り当て
- `subscription-manager release` の永続的な設定変更
- RHUIクライアントの更新・切り替え
- SatelliteのContent ViewやLifecycle Environmentの変更
- IdM、SAP、HAなど製品固有のアップグレード手順

これらが必要な環境では、先にRed Hatまたは環境管理者の手順でRHEL 8.10コンテンツを利用可能にしてください。

### 1. RHEL更新RPMを取得する

現在有効なrepoを使用する場合:

```bash
sudo ./capture-rhel8.8-to-8.10-snapshot.sh
```

実行時だけDNFへ `--releasever=8.10` を渡します。パッケージは更新せず、RPMと検証情報を `/var/lib/rhel-update-snapshots` に保存します。

パッケージ除外、repoの一時的な有効化・無効化も指定できます。

```bash
sudo ./capture-rhel8.8-to-8.10-snapshot.sh \
  --exclude 'podman*' \
  --disablerepo 'third-party-*'
```

RHSM直接接続の一般的なx86_64環境で、8.8 EUS repoを外して通常のRHEL 8 BaseOS/AppStreamを明示する例:

```bash
sudo ./capture-rhel8.8-to-8.10-snapshot.sh \
  --disablerepo '*-eus-*' \
  --enablerepo 'rhel-8-for-x86_64-baseos-rpms' \
  --enablerepo 'rhel-8-for-x86_64-appstream-rpms'
```

repo IDは契約、アーキテクチャ、RHUI、Satellite構成によって異なります。実在するIDを `dnf repolist --all` または管理システムで確認してください。引数は複数指定、カンマ区切り、引用符で囲んだglobに対応します。

取得処理は、RHEL 8.10の `redhat-release` と `.el8_10` の `kernel-core` が含まれない場合に失敗します。

### 2. 生成物を確認する

```text
/var/lib/rhel-update-snapshots/rhel8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar
/var/lib/rhel-update-snapshots/rhel8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar.sha256
```

`.tar` と `.tar.sha256` は同じディレクトリで保管してください。アーカイブにはRed Hatの購読対象RPMが含まれるため、GitHubなどへ公開せず、契約と組織のポリシーに従って管理してください。

### 3. RHELスナップショットを適用する

取得後にRPM構成を変更していない同一ホストで実行します。

```bash
sudo ./apply-rhel8.8-to-8.10-snapshot.sh \
  /var/lib/rhel-update-snapshots/rhel8.8-to-8.10-update-YYYYMMDDTHHMMSS+0900.tar
```

適用スクリプトはアーカイブ、RPM一覧、SHA-256、署名、取得時のパッケージ状態、RHEL 8.10の `redhat-release` とカーネルを検証します。外部repoを無効化したテストトランザクションが成功した後、実適用前にDNFの確認を求めます。

### 4. 永続repo設定を整合させて再起動する

適用スクリプトはRHSM/RHUI/Satelliteの永続設定を変更しません。次回オンラインでDNFを使う前に、管理方式に応じてRHEL 8.10向けrepoへ整合させてください。一般的なRHSM環境ではrelease lockの解除が必要になる場合がありますが、EUS/E4S、SAP、RHUI、Satelliteでは手順が異なるため、契約・管理方式の公式手順を優先してください。

設定確認後に再起動します。

```bash
sudo reboot
```

再ログイン後:

```bash
cat /etc/redhat-release
uname -r
sudo dnf check
```

`/etc/redhat-release` がRHEL 8.10を、`uname -r` が `.el8_10` を含むカーネルを表示することを確認してください。

## Rocky Linux 8.8 Vaultの最終状態を取得する

Rocky Linux 8.8のまま、8.8 Vaultに保存された最終更新までのRPMを取得する場合に使用します。

```bash
sudo ./capture-rocky8.8-vault-snapshot.sh
```

パッケージ除外指定は8.10用取得スクリプトと同じです。

```bash
sudo ./capture-rocky8.8-vault-snapshot.sh \
  --exclude 'podman*' \
  -x 'kernel-tools*'
```

リポジトリを無効化する場合は、Vault用の一時リポジトリIDを指定します。

```bash
sudo ./capture-rocky8.8-vault-snapshot.sh \
  --disablerepo rocky-8.8-vault-extras
```

指定可能な一時リポジトリIDは次のとおりです。

- `rocky-8.8-vault-baseos`
- `rocky-8.8-vault-appstream`
- `rocky-8.8-vault-extras`

指定内容はスナップショット内の `state/requested-disabled-repositories.txt` に記録されます。BaseOSや依存関係に必要なリポジトリを無効化すると、DNFの依存関係解決に失敗する場合があります。

既定の生成物は次のとおりです。

```text
/var/lib/rocky-update-snapshots/rocky8.8-vault-update-YYYYMMDD-HHMMSS.tar
/var/lib/rocky-update-snapshots/rocky8.8-vault-update-YYYYMMDD-HHMMSS.tar.sha256
```

このスクリプトが取得するカーネルは8.8系列です。Rocky Linux 8.10へ更新する用途ではありません。また、このアーカイブは契約が異なるため、`apply-rocky8.8-to-8.10-snapshot.sh` では適用できません。

## 失敗した場合

取得または検証が途中で失敗した場合、未完成のアーカイブを適用しないでください。エラー原因を解消して取得からやり直します。

メタデータ取得で `Curl error (18)` や `Curl error (28)` が発生した場合は、回線、プロキシ、ファイアウォール、利用repoへの到達性を確認してから再実行してください。スクリプトは標準のDNF設定よりも長いタイムアウトと多い再試行回数を設定しています。

RHEL版で `redhat-release` または `kernel-core` が不足する場合は、8.10コンテンツがrepoに公開されているか、release lock、EUS/E4S、RHUI、Satellite Content View、`--enablerepo`・`--disablerepo`・versionlockを確認してください。

## 旧日付固定スクリプトについて

`capture-rocky8-update-20260925.sh` は2026年9月25日だけ実行できる旧方式です。現在の8.8から8.10への取得には使用せず、`capture-rocky8.8-to-8.10-snapshot.sh` を使用してください。

## 参考資料

- [DNF Command Reference: --exclude / -x / --disablerepo](https://dnf.readthedocs.io/en/latest/command_ref.html)
- [Rocky Linux Wiki: Repositories](https://wiki.rockylinux.org/rocky/repo/)
- [Red Hat: How do I apply package updates to my RHEL system?](https://access.redhat.com/articles/11258)
- [Red Hat Enterprise Linux release dates](https://access.redhat.com/articles/red-hat-enterprise-linux-release-dates)
