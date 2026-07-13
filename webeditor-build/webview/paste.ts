// 画像ペースト → ネイティブへ送信（Gyazo アップロード）→ ![](url) 置換。
// couchnotes-vscode の paste.ts のネイティブブリッジ版（プロトコルは同じ）。
import { EditorView } from "@codemirror/view";

interface Poster {
  postMessage(msg: unknown): void;
}

let counter = 0;
function genId(): string {
  return Date.now().toString(36) + "-" + (counter++).toString(36);
}

function placeholderText(id: string): string {
  return `![アップロード中…](upload://${id})`;
}

/** カーソル位置にアップロード中プレースホルダを挿入し、その id を返す（ネイティブ発の画像ペースト用） */
export function insertUploadPlaceholder(view: EditorView): string {
  const id = genId();
  const placeholder = placeholderText(id);
  const sel = view.state.selection.main;
  view.dispatch({
    changes: { from: sel.from, to: sel.to, insert: placeholder },
    selection: { anchor: sel.from + placeholder.length },
    userEvent: "input.paste",
  });
  return id;
}

/** クリップボードの画像を検出してアップロードに回す paste ハンドラ */
export function pasteImages(native: Poster) {
  return EditorView.domEventHandlers({
    paste(event, view) {
      const items = event.clipboardData?.items;
      if (!items) return false;

      let file: File | null = null;
      for (const it of Array.from(items)) {
        if (it.kind === "file" && it.type.startsWith("image/")) {
          file = it.getAsFile();
          break;
        }
      }
      if (!file) return false; // 画像でなければ通常のテキストペーストに任せる

      event.preventDefault();
      const id = insertUploadPlaceholder(view);

      // data:URL から mime と base64 を取り出してネイティブへ
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result); // "data:image/png;base64,xxxx"
        const comma = result.indexOf(",");
        const mime = result.slice(5, result.indexOf(";")) || file!.type || "image/png";
        const data = result.slice(comma + 1);
        const ext = mime === "image/jpeg" ? "jpg" : (mime.split("/")[1] || "png");
        native.postMessage({ type: "pasteImage", id, mime, data, filename: `image.${ext}` });
      };
      reader.onerror = () => applyPasteResult(view, { id, error: "read-failed" });
      reader.readAsDataURL(file);
      return true;
    },
  });
}

/** アップロード結果でプレースホルダを置換（成功＝![](url)／失敗＝除去） */
export function applyPasteResult(
  view: EditorView,
  msg: { id: string; url?: string; error?: string }
) {
  const placeholder = placeholderText(msg.id);
  const idx = view.state.doc.toString().indexOf(placeholder);
  if (idx < 0) return; // ユーザーが既に消していたら何もしない
  const replacement = msg.url ? `![](${msg.url})` : "";
  view.dispatch({
    changes: { from: idx, to: idx + placeholder.length, insert: replacement },
    userEvent: "input",
  });
}
