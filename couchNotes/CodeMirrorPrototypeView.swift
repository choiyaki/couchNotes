//
//  CodeMirrorPrototypeView.swift
//  couchNotes
//
//  プロトタイプ検証用の入り口。Mac矢印キー・日本語IME・自前キーボードツールバーの
//  検証が終わったら削除する。
//

import SwiftUI

struct CodeMirrorPrototypeView: View {
    @State private var text = CodeMirrorPrototypeView.sampleText
    @StateObject private var bridge = WebEditorBridge()

    var body: some View {
        CodeMirrorWebEditor(text: $text, bridge: bridge)
            .safeAreaInset(edge: .bottom, spacing: 0) { toolbar }
            .navigationTitle("CodeMirror プロトタイプ")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// 自前のキーボード上ツールバー。inputAccessoryView の代わりに、
    /// キーボード高さぶんだけ下から持ち上げて重ねる。
    private var toolbar: some View {
        HStack(spacing: 5) {
            toolbarButton("[[ ]]") { bridge.run("wikiLink") }
            toolbarButton(systemImage: "checklist") { bridge.run("listToggle") }
            toolbarButton(systemImage: "arrow.up") { bridge.run("moveLineUp") }
            toolbarButton(systemImage: "arrow.down") { bridge.run("moveLineDown") }
            toolbarButton(systemImage: "arrow.left.to.line") { bridge.run("outdent") }
            toolbarButton(systemImage: "arrow.right.to.line") { bridge.run("indent") }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func toolbarButton(_ title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let title { Text(title).font(.system(size: 13, weight: .medium)) }
                else if let systemImage { Image(systemName: systemImage) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    private static let sampleText = """
    # 見出し1 テスト

    見出しの直後の本文行です。ここから下矢印で見出しをまたげるか確認します。
    もう一行あります。

    ## 見出し2 テスト

    あああああ
    かかかかか

    ### 見出し3 テスト

    日本語入力（IME変換）もここで確認してください。にほんご にゅうりょく のへんかん。

    - リスト項目
    - [[ ]]ボタンやチェックリストボタンもここで試せます

    ## 画像の多いページの選択テスト

    以下の画像群の間で空白長押し→カーソル移動・選択範囲の調整を行い、表示が飛ばないか確認してください。

    ![](https://picsum.photos/seed/cn1/800/500)

    画像の間の本文です。ここを長押しして選択を広げてみてください。

    ![](https://picsum.photos/seed/cn2/700/900)

    ![|30](https://picsum.photos/seed/cn3/600/400) ![|30](https://picsum.photos/seed/cn4/600/400)

    さらに本文が続きます。選択範囲のハンドルを画像をまたいでドラッグしてみてください。

    ![](https://picsum.photos/seed/cn5/900/600)

    通常の段落がしばらく続きます。通常の段落がしばらく続きます。通常の段落がしばらく続きます。
    通常の段落がしばらく続きます。通常の段落がしばらく続きます。通常の段落がしばらく続きます。
    """
}
