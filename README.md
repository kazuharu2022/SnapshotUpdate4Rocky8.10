# SnapshotUpdate4Rocky8.10



### リポジトリのスナップショットの作成

現状の確認
```
cat /etc/rocky-release
uname -r
```

capture-rocky8-update-20260925.shを実行すると、次のようなファイルが作成される

```
/var/lib/rocky-update-snapshots/rocky8.10-update-20260925T123000+0900.tar
/var/lib/rocky-update-snapshots/rocky8.10-update-20260925T123000+0900.tar.sha256
```
アーカイブ名を念のため確認します。
```
ls -lh /var/lib/rocky-update-snapshots/
```



### アップデートの実施
```
sudo /root/apply-rocky8-snapshot-update.sh \
  /var/lib/rocky-update-snapshots/rocky8.10-update-20260925T123000+0900.tar
```
途中でY/Nが出たらYを選択

終わったら再起動
```
sudo reboot
```


再起動後の確認項目

```
cat /etc/rocky-release
uname -r
rpm -q kernel-core --last
sudo dnf check
systemctl --failed
```
