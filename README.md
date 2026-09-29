# Rocky Linux 8 更新RPMスナップショット

Rocky Linux 8.8で、更新に必要なRPMと検証情報を取得し、後からオフラインで適用するためのスクリプト群です。

ここでいう「スナップショット」は、更新RPMとパッケージ状態の記録です。ディスク全体、設定ファイル、ユーザーデータのバックアップや、更新前へ戻すロールバック機能ではありません。実行前にVMまたはストレージ側でも復旧手段を用意してください。

## スクリプトの使い分け

| スクリプト | 用途 |
| --- | --- |
| `capture-rocky8.8-to-8.10-snapshot.sh` | Rocky Linux 8.8から8.10へ更新するRPMを取得 |
| `apply-rocky8.8-to-8.10-snapshot.sh` | 上記スナップショットを検証し、Rocky Linux 8.8へオフライン適用 |
| `capture-rocky8.8-vault-snapshot.sh` | Rocky Linux 8.8 Vaultの最終状態までの更新RPMを取得。8.10には更新しない |
| `capture-rocky8-update-20260925.sh` | 2026年9月25日専用の旧取得スクリプト |
| `apply-rocky8-snapshot-update.sh` | 旧形式スナップショット用の汎用適用スクリプト |

Rocky Linux 8.8から8.10へ更新する場合は、必ず専用の取得・適用スクリプトを組み合わせてください。

## 事前確認

取得元・適用先はいずれも、実行開始時点でRocky Linux 8.8である必要があります。

```bash
cat /etc/rocky-release
uname -r
```

スクリプトへ実行権限を付与します。

```bash
chmod +x \
  capture-rocky8.8-to-8.10-snapshot.sh \
  capture-rocky8.8-vault-snapshot.sh \
  apply-rocky8.8-to-8.10-snapshot.sh
```

## Rocky Linux 8.8から8.10へ更新する

### 1. 更新RPMを取得する

```bash
sudo ./capture-rocky8.8-to-8.10-snapshot.sh
```

このスクリプトは、既存の標準リポジトリ設定を変更せず、一時的なリポジトリ設定だけを使用します。Rocky Linux公式mirrorlistからBaseOS、AppStream、ExtrasのRocky Linux 8.10リポジトリを解決し、インストールは行わずに更新RPMを保存します。

低速回線向けに、タイムアウト、低速判定、再試行回数、並列ダウンロード数を調整しています。

### 2. 更新対象を除外する

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

### 3. 生成物を確認する

既定では次の2ファイルが生成されます。

```text
/var/lib/rocky-update-snapshots/rocky8.8-to-8.10-update-YYYYMMDD-HHMMSS.tar
/var/lib/rocky-update-snapshots/rocky8.8-to-8.10-update-YYYYMMDD-HHMMSS.tar.sha256
```

`.tar` と `.tar.sha256` は同じディレクトリで保管・転送してください。

アーカイブには、RPM、RPM一覧、各RPMのSHA-256、取得前のパッケージ状態、対象バージョン情報、除外指定が含まれます。

### 4. スナップショットを適用する

取得後から適用前までの間に、対象ホストでRPMの追加・更新・削除を行わないでください。取得時のパッケージ状態と異なる場合、専用適用スクリプトはベースライン不一致として停止します。

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

## Rocky Linux 8.8 Vaultの最終状態を取得する

Rocky Linux 8.8のまま、8.8 Vaultに保存された最終更新までのRPMを取得する場合に使用します。

```bash
sudo ./capture-rocky8.8-vault-snapshot.sh
```

除外指定は8.10用取得スクリプトと同じです。

```bash
sudo ./capture-rocky8.8-vault-snapshot.sh \
  --exclude 'podman*' \
  -x 'kernel-tools*'
```

既定の生成物は次のとおりです。

```text
/var/lib/rocky-update-snapshots/rocky8.8-vault-update-YYYYMMDD-HHMMSS.tar
/var/lib/rocky-update-snapshots/rocky8.8-vault-update-YYYYMMDD-HHMMSS.tar.sha256
```

このスクリプトが取得するカーネルは8.8系列です。Rocky Linux 8.10へ更新する用途ではありません。また、このアーカイブは契約が異なるため、`apply-rocky8.8-to-8.10-snapshot.sh` では適用できません。

## 失敗した場合

取得または検証が途中で失敗した場合、未完成のアーカイブを適用しないでください。エラー原因を解消して取得からやり直します。

メタデータ取得で `Curl error (18)` や `Curl error (28)` が発生した場合は、回線、プロキシ、ファイアウォール、Rocky Linuxミラーへの到達性を確認してから再実行してください。スクリプトは標準のDNF設定よりも長いタイムアウトと多い再試行回数を設定しています。

## 旧日付固定スクリプトについて

`capture-rocky8-update-20260925.sh` は2026年9月25日だけ実行できる旧方式です。現在の8.8から8.10への取得には使用せず、`capture-rocky8.8-to-8.10-snapshot.sh` を使用してください。

## 参考資料

- [DNF Command Reference: --exclude / -x](https://dnf.readthedocs.io/en/latest/command_ref.html)
- [Rocky Linux Wiki: Repositories](https://wiki.rockylinux.org/rocky/repo/)
