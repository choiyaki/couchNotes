# couchNotes

Obsidian LiveSync（CouchDB）上の Markdown ノートを読み書きする iOS・iPadOS のアプリ。共有シートの拡張機能（`couchNotesShare`。写真を couchimg へ上げる）を含む。
利用者が作者本人で、実機での確認は利用者が行う。

## 最初に読むもの

- `docs/`: リンクの対応表（`link-index.md`、`link-index-reader.md`）
- 画像（couchimg）の設計は `~/src/couchimg/docs/DESIGN.md`。経緯は `~/devops/SETUP_STATE.md` の「VPN の一本化の進め方」

## 画像（couchimg）

- アップロードと表示は `https://img.choiyaki.com`（upload・app のトークン）
- 公開・削除は、Tailscale の中の管理用の口 `http://couchimg:8751`（publish のトークン。2026-10-23 に admin から替えた。前の版が置いた admin のトークンは、起動のときに Keychain から消す）。`.` のない名前への平文の HTTP なので、`Info.plist` の `NSAllowsLocalNetworking` が要る（2026-10-23 に WireGuard から移した）
- 端末の追加・一覧・無効化（登録コードの発行）は、画像のアプリ（`~/src/couchImgApp`）だけで行う。このアプリには足さない（2026-10-23 利用者決定）
- 登録の欄は1つ（2026-10-23 利用者決定）。コードはまず一般用の口の `/pair` へ送り、421 `{redeem_at: "admin"}`（publish を含むコード）なら管理用の口の `/pair` へ送り直す。登録し直すと、手元のトークンはすべて入れ替わる（新しいコードに含まれない種類は消える）

## 守ること

- 接続情報、トークン、秘密の値を、コード、テスト、文書、コミットに書かない。設定画面から Keychain に保存する作りのままにする
- シミュレーターの中のアプリに、本番の接続情報を入力しない。同期と画像の確認は、利用者が実機で行う
- 曖昧な設計判断は、実装の前に確認する
- 最後に、ビルドと全テストの合格を確かめる
- コミットと push は、利用者の指示があったときだけ行う

## ビルドとテスト

```bash
xcodebuild -project couchNotes.xcodeproj -scheme couchNotes -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- シミュレーターの機種名は、環境によって変わる。`xcrun simctl list devices available` で確かめる
- `CODE_SIGNING_ALLOWED=NO` を付けると、Keychain を使う試験（`testTokenIsAttachedOnlyToOurHost`）が落ちる（2026-10-23 に確かめた。変更の前から同じ）
- Claude のセッションの中では、シミュレーターの仕組みにサンドボックスの中から届かないので、ビルドとテストはサンドボックスの外で動かす
- 編集画面（CodeMirror）の元は `webeditor-build/webview/`。`cd webeditor-build && npm run build` で `couchNotes/WebEditor/` へ書き出す
- TestFlight へは `~/devops/bin/tf-up check couchNotes` → 承認 → `tf-up send couchNotes`（`~/devops/TESTFLIGHT_RUNBOOK.md`）。本体と拡張機能で、配布用のプロファイルが2つ要る
