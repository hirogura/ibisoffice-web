# ibisoffice-web

ibisOffice (https://github.com/ibisjp/ibis-office) のビルド成果物を 3367 番ポートでセルフホストする。

## リポジトリ構成

- `ibisoffice-install.sh`: ビルド環境の導入からビルド・配信起動まで一括で行うインストーラ
- `serve-ibisoffice.py`: ビルド成果物を静的配信するサーバ（COOP/COEP ヘッダ付き）
- `public-ibisoffice/`: ビルド成果物の配信ルート（`.gitignore` 対象）
- `ibis-office/`: 本家リポジトリの clone（`.gitignore` 対象）
- `README.md`: 本ドキュメント

## 必要条件

- Debian / Ubuntu 系 Linux（`apt-get` で依存を自動導入する。それ以外の環境は gcc / make / python3 / curl / git / node / npm / unzip を手動で用意）
- **WebGPU 対応ブラウザ**（Chrome / Edge / Safari 26+ など）
- （リモートから HTTPS でアクセスしたい場合）Tailscale

WebGPU は **secure context（HTTPS または localhost）のみ**で動作するため、ブラウザから直接開く場合は HTTPS でアクセスするのが確実。

## 別環境へのインストール

このリポジトリを配置したホスト上で、以下の一括インストールを実行するだけ。

```sh
mkdir -p /opt/ibisoffice/
cd /opt/ibisoffice/
curl -fsSL https://raw.githubusercontent.com/hirogura/ibisoffice-web/main/ibisoffice-install.sh -o /opt/ibisoffice/ibisoffice-install.sh
chmod +x ibisoffice-install.sh
./ibisoffice-install.sh
```

スクリプトが次を行う。

1. システム依存（build-essential / node / npm / unzip など）を `apt-get` で導入
2. Rust stable + `wasm32-unknown-unknown` target を rustup 経由で導入
3. 本家リポジトリ（submodule 含む）を `ibis-office/` に clone（既存なら pull 更新）
4. Cargo.lock と同じ版の wasm-bindgen-cli を導入して `www/` をビルド（wasm + tsc + アイコン・アートボーダー素材）
5. 成果物を `public-ibisoffice/` に配置
6. systemd unit（`/etc/systemd/system/ibisoffice-web.service`）があれば再利用し、無ければ作る場合は手動で `serve-ibisoffice.py` を起動

主要オプション:

| 引数 / 環境変数 | 内容 |
| --- | --- |
| `--port <n>` / `PORT` | 配信ポート（既定 3367） |
| `--skip-build` / `SKIP_BUILD=1` | ビルドを飛ばして配信だけやり直す |
| `--no-serve` / `NO_SERVE=1` | 配信を起動しない |

注意:

- wasm の初回ビルドはマシンによって 1〜2 時間程度かかる
- ビルド済みで成果物が `public-ibisoffice/` のまま残っている環境では `--skip-build` で数分で完了

## 配信

- ローカル HTTP: ``http://localhost:<PORT>/``（systemd: `systemctl status ibisoffice-web`。無い環境は `python3 serve-ibisoffice.py <PORT> <配信ディレクトリ>`）
- `serve-ibisoffice.py` は loopback (127.0.0.1) のみで待ち受けする。HTTPS プロキシ（後述）がポートを横取りする余地を残すため

再ビルド: `./ibisoffice-install.sh`（ビルド済みなら `--skip-build` で配信だけ更新）

## リモートアクセス（HTTPS）: Tailscale serve

MagicDNS が有効な Tailnet にホストが参加していれば、`tailscale serve` で有効な証明書の HTTPS ページとして公開できる。HTTP サーバと同じポートで HTTPS も公開する例:

```sh
tailscale serve --bg --https=<PORT> http://127.0.0.1:<PORT>
# 停止: tailscale serve --https=<PORT> off
```

ブラウザからは `https://<ホスト名>.<tailnet名>.ts.net:<PORT>/` を開く。
Tailscale が証明書を自動発行し、WebGPU が要求する secure context を満たす。

クライアント側の設定でどうしても HTTPS が使えない場合は、Chrome の
`chrome://flags/#unsafely-treat-insecure-origin-as-secure` に
`http://<ホスト>:<PORT>` を登録する方法もある（全環境へは推奨しない）。
