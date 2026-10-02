//
//  CouchImgAPI.swift
//  couchNotes
//
//  couchimg の「画像の情報・一覧・検索・変更の差分・OCR の修正・整理のヒント」の呼び出し（app のトークン）。
//  応答の形は ../couchimg/docs/DESIGN.md 3.2 の表。アップロード・取得・公開・削除は CouchImgService.swift。
//

import Foundation

extension CouchImgService {
    // MARK: - 応答の形

    struct OCRInfo: Decodable, Equatable {
        struct Queue: Decodable, Equatable {
            let ahead: Int
            let etaSeconds: Int
            enum CodingKeys: String, CodingKey { case ahead, etaSeconds = "eta_seconds" }
        }
        let status: String          // pending / running / done / failed / skipped
        let text: String?
        let revision: Int
        let edited: Bool
        let model: String?
        let updatedAt: Double?
        let truncated: Bool
        let queue: Queue?
        enum CodingKeys: String, CodingKey { case status, text, revision, edited, model, updatedAt = "updated_at", truncated, queue }
    }

    /// その画像が貼られているノート
    struct NoteRef: Decodable, Equatable, Identifiable {
        let docId: String
        let path: String
        let kind: String            // embed（画像として貼ってある）/ link（リンクだけ）
        let isPublic: Bool          // 公開フォルダのノートか
        var id: String { docId }
        enum CodingKeys: String, CodingKey { case docId = "doc_id", path, kind, isPublic = "public" }
    }

    struct ImageInfo: Decodable, Equatable {
        let id: String
        let url: String
        let isPublic: Bool
        let ext: String
        let width: Int
        let height: Int
        let bytes: Int
        let createdAt: Double
        let uploadedBy: String?
        let uploadSource: String?
        let ocr: OCRInfo
        let notes: [NoteRef]
        let suggestPublish: Bool    // 非公開なのに、公開フォルダのノートに画像として貼ってある
        enum CodingKeys: String, CodingKey {
            case id, url, isPublic = "public", ext, width, height, bytes, createdAt = "created_at"
            case uploadedBy = "uploaded_by", uploadSource = "upload_source", ocr, notes, suggestPublish = "suggest_publish"
        }
    }

    /// 一覧の1件
    struct ImageSummary: Decodable, Equatable, Identifiable {
        let id: String
        let url: String
        let ext: String
        let isPublic: Bool
        let createdAt: Double
        let width: Int
        let height: Int
        let uploadedBy: String?
        let uploadSource: String?
        let ocrStatus: String
        let notes: Int              // 貼られているノートの数
        let snippet: String?        // 検索したとき: 一致した前後の文字
        enum CodingKeys: String, CodingKey {
            case id, url, ext, isPublic = "public", createdAt = "created_at", width, height
            case uploadedBy = "uploaded_by", uploadSource = "upload_source", ocrStatus = "ocr_status", notes, snippet
        }
    }

    struct ImageList: Decodable, Equatable {
        let items: [ImageSummary]
        let next: String?           // 続きがあるときの印。次の呼び出しの before に渡す
    }

    /// 変更の差分の1件。削除済みは id・seq・deleted だけ
    struct Change: Decodable, Equatable {
        let id: String
        let seq: Int
        let deleted: Bool
        let ocrStatus: String?
        let ocrText: String?
        enum CodingKeys: String, CodingKey { case id, seq, deleted, ocrStatus = "ocr_status", ocrText = "ocr_text" }
    }

    struct Changes: Decodable, Equatable {
        let gen: String             // サーバーの DB の世代。変わったら全部取り直す
        let reset: Bool
        let items: [Change]
        let next: Int
        let more: Bool
    }

    struct HintItem: Decodable, Equatable, Identifiable {
        let id: String
        let url: String
        let createdAt: Double
        enum CodingKeys: String, CodingKey { case id, url, createdAt = "created_at" }
    }

    struct Hints: Decodable, Equatable {
        let indexAt: Double?        // 対応表が最後に届いた時刻。nil = まだ届いていない
        let unattached: [HintItem]
        let publicOnlyInPrivateNotes: [HintItem]
        let privateInPublicNotes: [HintItem]
        enum CodingKeys: String, CodingKey {
            case indexAt = "index_at", unattached
            case publicOnlyInPrivateNotes = "public_only_in_private_notes", privateInPublicNotes = "private_in_public_notes"
        }
    }

    /// OCR の修正の結果。conflict = 別の端末（または AI）が先に書き換えていた
    enum OCREditResult: Equatable {
        case saved(revision: Int, text: String)
        case conflict(revision: Int, text: String?)
    }

    struct ImageFilter: Equatable {
        var query = ""
        var source: String? = nil       // couchnotes / share / web / mac / windows / import
        var unattached = false          // どのノートにも貼っていない
    }

    // MARK: - 呼び出し

    private static func appRequest(_ path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        guard let t = token(appTokenKey) else { throw CouchImgError.notRegistered }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query
            // + はサーバー側で空白として読まれるので、エンコードして送る
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, status) = try await send(appRequest(path, query: query))
        guard status == 200 else { throw error(for: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 画像の情報（公開状態・OCR・貼られているノート）
    static func imageInfo(id: String) async throws -> ImageInfo {
        try await get(ImageInfo.self, "api/images/\(id)")
    }

    /// 画像の一覧（新しい順）。before は前の応答の next
    static func listImages(_ filter: ImageFilter = .init(), before: String? = nil, limit: Int = 60) async throws -> ImageList {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        let q = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { query.append(URLQueryItem(name: "q", value: String(q.prefix(200)))) }
        if let source = filter.source { query.append(URLQueryItem(name: "source", value: source)) }
        if filter.unattached { query.append(URLQueryItem(name: "unattached", value: "1")) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get(ImageList.self, "api/images", query: query)
    }

    /// since より後に変わった画像（OCR の文字の取り込み用）
    static func changes(since: Int, gen: String?) async throws -> Changes {
        var query = [URLQueryItem(name: "since", value: String(since))]
        if let gen { query.append(URLQueryItem(name: "gen", value: gen)) }
        return try await get(Changes.self, "api/changes", query: query)
    }

    static func hints() async throws -> Hints {
        try await get(Hints.self, "api/hints")
    }

    /// OCR の文字を直す。baseRevision は、直す元にした版（ImageInfo.ocr.revision）
    static func editOCR(id: String, text: String, baseRevision: Int) async throws -> OCREditResult {
        struct Reply: Decodable { let revision: Int; let text: String? }
        var request = try appRequest("api/images/\(id)/ocr", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "base_revision": baseRevision])
        let (data, status) = try await send(request)
        guard status == 200 || status == 409, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw error(for: status)
        }
        return status == 200 ? .saved(revision: reply.revision, text: reply.text ?? "")
                             : .conflict(revision: reply.revision, text: reply.text)
    }

    /// 公開・削除を画像 ID で（一覧・プレビュー画面から）
    static func publish(id: String) async throws { try await publish(urlString: baseURL.appendingPathComponent("\(id).png").absoluteString) }
    static func delete(id: String) async throws { try await delete(urlString: baseURL.appendingPathComponent("\(id).png").absoluteString) }
}
