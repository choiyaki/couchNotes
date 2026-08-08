# リンクサジェスト索引：読み手アプリ実装ガイド

このドキュメントは、**別アプリ**が CouchDB 上の「リンクサジェスト索引」を読み込んで、
`[[...]]` リンク入力のオートコンプリートに使うための実装ガイドです。索引の**書き出しは
couchNotes が行う**ので、あなたのアプリは**読むだけ**です。CouchDB の読み方さえ分かれば実装できます。

---

## 0. 前提

- あなたのアプリが既に使っている CouchDB と同じ **ベース URL / DB 名 / 認証（Basic 認証）** を使う。
- 索引は「ノート」ではなく、`couchnotes_linkindex_` で始まる**専用ドキュメント群**として入っている。
- **トップレベルフォルダごとに1文書**（＋ルート用に1文書）。全部の和集合が「全ノート」に相当する。
  （端末ごとに同期フォルダが違う＝部分同期のため、1文書にまとめず分割されている。）

---

## 1. 索引文書を発見する（列挙）

ID を自分で組み立てず、**接頭辞で範囲取得**する:

```
GET {baseURL}/{db}/_all_docs?include_docs=true
      &startkey="couchnotes_linkindex_"
      &endkey="couchnotes_linkindex_￰"
```

URL エンコード例:
```
GET {baseURL}/{db}/_all_docs?include_docs=true&startkey=%22couchnotes_linkindex_%22&endkey=%22couchnotes_linkindex_%EF%BF%B0%22
Authorization: Basic ...
```

`rows[].doc` が下記スキーマの索引文書。1件も無ければ**候補なし**として扱う（エラーにしない）。

---

## 2. 文書スキーマ

```json
{
  "_id": "couchnotes_linkindex_root",
  "_rev": "3-...",
  "type": "couchnotes-linkindex",
  "version": 2,
  "folder": "Work",
  "generatedAt": "2026-07-28T12:34:56Z",
  "links": [
    { "key": "ページ名",  "title": "ページ名",  "path": "work/ページ名.md", "exists": true },
    { "key": "mynewpage", "title": "MyNewPage", "exists": false }
  ]
}
```

| フィールド | 意味 |
|---|---|
| `folder` | この文書のトップレベルフォルダ名（大小保持）。**ルート文書では省略（なし）**。 |
| `links[].key` | 照合用の正規化キー（**常に小文字**。別名`\|`・見出し`#`・`.md` は除去済み）。照合は大小区別なし。 |
| `links[].title` | 表示・挿入用の名前。**大文字小文字は書かれたまま**（実在ノートはノート名、未作成は `[[...]]` に書かれた表記）。リンクは `[[title]]` で挿入する。 |
| `links[].path` | 実在ノートの ID（＝小文字パス）。`exists=true` のみ。`{db}/{path}` を GET すればノート本体が引ける。`exists=false` には無い。 |
| `links[].exists` | `true`=実在ノート、`false`=言及されただけの未作成ページ。 |
| `type` / `version` / `generatedAt` | メタ情報。候補生成には `links` を使う。 |

`_id`/`_rev` は CouchDB のメタなので無視してよい。

---

## 3. マージ（全フォルダを1つの候補集合にする）

全文書の `links` を集約する。**同じ `key` は1件にまとめ、`exists=true` を優先**する。

> なぜ優先が必要か: あるフォルダ文書では「未作成（`exists=false`）」に見えるキーが、別フォルダ文書では
> 実在ノート（`exists=true`）として存在することがある（実在判定は各端末のローカル範囲で行われるため）。
> `exists=true` を優先すれば正しく解決される。

擬似コード:
```
candidates = {}                       // key -> entry
for doc in indexDocs:
    for e in doc.links:
        cur = candidates[e.key]
        if cur == null or (e.exists and not cur.exists):
            candidates[e.key] = e
candidateList = candidates.values()
```

---

## 4. オートコンプリートで使う

1. ユーザーが `[[query` と入力したら、`query` を **小文字化**（保険で **NFC 正規化**も）する。
2. `candidateList` を、各エントリの `key` に対して **前方一致 →（無ければ）部分一致** で絞る。
3. 候補は `title` を表示。`exists=false` は「未作成」として淡色などで区別してよい（任意）。
4. 選択したら本文に `[[title]]` を挿入。
5. 必要なら `path`（`exists=true` のみ）でノート本体を開く／`_id` 照合に使う。

擬似コード:
```
q = normalize(userQuery)              // lowercase (+ NFC)
hits = candidateList.filter(e => e.key.startsWith(q))
if hits.isEmpty:
    hits = candidateList.filter(e => e.key.contains(q))
show(hits, displayField = "title")
onSelect(e):  insert("[[" + e.title + "]]")
```

---

## 5. 特定フォルダだけ使いたい場合（任意）

- 列挙した文書のうち、`folder` フィールド（ルートは無し）で**使いたいフォルダの文書だけ**選び、
  その `links` を（3 と同じ規則で）マージして使う。
- あるいは全マージ後に、`path` の接頭辞（例 `work/`）で候補を絞る（`exists=false` は `path` が無い点に注意）。

---

## 6. 更新・キャッシュ

- 起動時に一度取得し、数分キャッシュで十分。
- 効率化するなら、各文書の `_rev` を覚えておき、次回列挙で `_rev` が変わった文書だけ `doc` を取り直す。
  もしくは `_changes` フィードで `couchnotes_linkindex_` 接頭辞の文書更新を監視して再取得する。

---

## 7. 注意点・エッジケース

- **まだ何も無い**: 索引文書が1件も無ければ候補なし（couchNotes 側が一度も書き出していない状態）。エラーにしない。
- **DB 全体をローカル複製している場合**: これらの索引文書もローカルに来る。「**`.md` で終わらない ID は
  ノートとして扱わない**」を守れば、ローカルから直接読める（列挙も同じ接頭辞で可能）。
- **NFC/NFD**: `key` は小文字化のみで NFC 統一はしていない。濁点付きの一部の名前で NFC/NFD の違いにより
  一致しないことがあるため、照合前に**クエリと `key` を両方 小文字＋NFC に揃える**とより堅牢。
- **書かない前提**: このアプリは索引を**読むだけ**。索引文書に書き込まない（書き出しは couchNotes の責務）。

---

## 8. 最小実装フロー（まとめ）

```
1. GET _all_docs?include_docs=true&startkey="couchnotes_linkindex_"&endkey="couchnotes_linkindex_￰"
2. docs = rows[].doc
3. candidates = merge(docs.links)  // key で集約・exists=true 優先
4. [[query 入力時: normalize(query) で candidates.key を前方一致→部分一致フィルタ
5. title を表示 / 選択で [[title]] 挿入 / 必要なら path でノートを開く
```
