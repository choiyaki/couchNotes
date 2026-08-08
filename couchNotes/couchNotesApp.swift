import SwiftUI

@main
struct couchNotesApp: App {
    var body: some Scene {
        WindowGroup {
            NoteListView()
                .task {
                    // アプリ起動時に _changes リスナーを開始
                    // バックグラウンド/フォアグラウンド切替は ChangesListener が自動管理
                    ChangesListener.shared.start()
                    // リンクサジェスト索引を CouchDB に書き出す（他アプリ共有用・docs/link-index.md）
                    LinkIndexPublisher.shared.start()
                }
                .onOpenURL { url in
                    URLActionRouter.shared.handle(url)
                }
        }
    }
}
