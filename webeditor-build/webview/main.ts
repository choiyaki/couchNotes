// couchnotes-vscode/webview/main.ts のネイティブ（WKWebView）版。
// VSCode の acquireVsCodeApi()/window message の代わりに、
// window.webkit.messageHandlers 経由でSwift側と直接やり取りする。
import "./styles.css";
import { Annotation, EditorState, Prec, Transaction } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { history, historyKeymap, defaultKeymap, moveLineUp, moveLineDown, undo, redo, undoDepth, redoDepth } from "@codemirror/commands";
import { autocompletion, completionKeymap } from "@codemirror/autocomplete";
import { wikiCompletionSource } from "./complete";
import { liveStyling } from "./decorations";
import { imageField, refreshImageLayout } from "./images";
import { clearTableMeasureCache } from "./table";
import {
  setWikiTargets,
  wikiTargetsField,
  setMentionedTargets,
  mentionedTargetsField,
  setLivePreview,
  livePreviewField,
  setEditorFocused,
  editorFocusedField,
} from "./state";
import { pasteImages, applyPasteResult, insertUploadPlaceholder } from "./paste";
import { footerExtension, setFooterData, setFooterPoster, FooterData } from "./footer";
import { mathPreview } from "./math";
import {
  listContinuation,
  indentLines,
  outdentLines,
  toggleListMarker,
  insertWikiLink,
  toggleCheckboxAt,
} from "./commands";

// --- ネイティブブリッジ（Swift 側の WKScriptMessageHandler 名 "couchNotes"） ---
interface NativeBridge {
  postMessage(msg: unknown): void;
}
interface InitPayload {
  text?: string;
  wikiTargets?: string[];
  mentionedTargets?: string[];
  fontSize?: number;
  lineSpacing?: number;
  horizontalInset?: number;
  fontCSSURL?: string;
  fontFamily?: string;
  livePreview?: boolean;
  version?: number;
}
declare global {
  interface Window {
    webkit: { messageHandlers: { couchNotes: NativeBridge } };
    couchNotesReceive: (msg: unknown) => void;
    couchNotesRunCommand: (name: string) => void;
    couchNotesInsertPlaceholder: () => string;
    // Swift 側が loadHTMLString で埋め込む初期値。通信の往復（postMessage → native →
    // evaluateJavaScript）を待たずに、最初の描画から正しい余白・文字サイズ・本文にするため、
    // ページ読み込みと同期のタイミングでこれを読んで初期化する。
    __couchNotesInit?: InitPayload;
  }
}
const native = window.webkit.messageHandlers.couchNotes;
const initPayload: InitPayload = window.__couchNotesInit ?? {};

// 拡張ホスト（Swift）由来の transaction を識別し、編集メッセージのエコーを防ぐ。
const remote = Annotation.define<boolean>();

// --- リンク判定（クリック追従用） ---
type LinkHit = { kind: "wiki" | "external"; value: string; start: number; end: number };
function linkAt(text: string, col: number): LinkHit | null {
  for (const m of text.matchAll(/\[\[([^\]]+)\]\]/g)) {
    const s = m.index!;
    const e = s + m[0].length;
    if (col >= s && col < e) return { kind: "wiki", value: m[1], start: s, end: e };
  }
  for (const m of text.matchAll(/(?<!!)\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g)) {
    const s = m.index!;
    const e = s + m[0].length;
    if (col >= s && col < e) return { kind: "external", value: m[1], start: s, end: e };
  }
  for (const m of text.matchAll(/https?:\/\/[^\s)\]]+/g)) {
    const s = m.index!;
    const e = s + m[0].length;
    if (col >= s && col < e) return { kind: "external", value: m[0], start: s, end: e };
  }
  return null;
}

const cnKeymap = keymap.of([
  { key: "Enter", run: listContinuation },
  { key: "Tab", run: indentLines },
  { key: "Shift-Tab", run: outdentLines },
  { key: "Alt-ArrowUp", run: moveLineUp },
  { key: "Alt-ArrowDown", run: moveLineDown },
  { key: "Mod-l", run: toggleListMarker },
  { key: "Mod-Shift-l", run: insertWikiLink },
]);

// タップ／クリックの処理。ネイティブ版（handleTap）と同じく、
// リンクは修飾キーなしのタップで直接開く。チェックボックスはトグル。
const clickHandler = EditorView.domEventHandlers({
  mousedown(e, view) {
    // ライブプレビューのリンク付き画像 [![](img)](url) のタップ → 外部リンクを開く
    const linkedImg = (e.target as HTMLElement | null)?.closest?.(".cm-cn-linked-img");
    if (linkedImg) {
      const href = linkedImg.getAttribute("data-href");
      if (href) {
        native.postMessage({ type: "openExternal", url: href });
        e.preventDefault();
        return true;
      }
    }

    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos == null) return false;
    const line = view.state.doc.lineAt(pos);
    const col = pos - line.from;

    const cb = /^([\t ]*)[-*] \[[ xX]\]/.exec(line.text);
    if (cb) {
      const bs = cb[1].length + 2;
      const be = bs + 3;
      if (col >= bs && col < be) {
        toggleCheckboxAt(view, pos);
        e.preventDefault();
        return true;
      }
    }

    const hit = linkAt(line.text, col);
    if (hit) {
      // ライブプレビューで記法（[[ ]] 等）が隠れている非アクティブ行では、リンクの
      // 視覚的な終端より右の空白をタップしても posAtCoords が隠れた末尾記号側に
      // 丸めてしまい、テキスト上は「リンクの範囲内」に見えることがある。
      // 実際にタップした画面座標がリンクの描画範囲内かどうかも確認し、範囲外なら
      // 通常のカーソル配置（return false）に任せる。
      // 折り返しリンクでは終端が別の視覚行にあるため、この判定は「タップが終端と
      // 同じ視覚行にある」場合だけ適用する（さもないと1行目のリンク部分のタップが
      // 全て『終端より右』と誤判定されて反応しなくなる）。
      const endCoords = view.coordsAtPos(line.from + hit.end, -1);
      if (
        endCoords &&
        e.clientY >= endCoords.top && e.clientY <= endCoords.bottom &&
        e.clientX > endCoords.right
      ) {
        return false;
      }
      if (hit.kind === "wiki") native.postMessage({ type: "openWiki", target: hit.value });
      else native.postMessage({ type: "openExternal", url: hit.value });
      e.preventDefault();
      return true;
    }
    return false;
  },
});

// WKWebView（特に Mac Catalyst）は、copy/cut イベントの clipboardData.setData 自体は
// 正しく効く（CM6 標準のコピー処理で確認済み）のに、それをシステムのペーストボードへ
// 実際に反映する内部のブリッジ処理が壊れていて、型（text/plain）だけ宣言されて中身が
// 空のペーストボード項目になってしまうことがある。
// さらに cut は、copy/cut の DOM イベント（event.preventDefault()）とは別に、
// ネイティブ側の「独立した削除アクション」が並行して走ってしまうらしく、
// こちら側で選択範囲を削除した「後」に、ズレた（古い）範囲でもう一度削除が走り、
// 行全体が消える・クリップボードの中身が別の範囲になる、という二重処理が起きていた。
// copy/cut の DOM イベントではなく、キー入力（keydown）の段階で横取りして
// event.preventDefault() することで、ブラウザの既定動作（＝この二重処理の発生源）
// 自体を起こさせない。Prec.highest で他のキーマップより確実に先に処理する。
const nativeClipboard = Prec.highest(keymap.of([
  { key: "Mod-c", run: (view) => sendToNativeClipboard(view, false), preventDefault: true },
  { key: "Mod-x", run: (view) => sendToNativeClipboard(view, true), preventDefault: true },
]));

function sendToNativeClipboard(view: EditorView, isCut: boolean): boolean {
  const sel = view.state.selection.main;
  let text: string, from: number, to: number;
  if (!sel.empty) {
    text = view.state.sliceDoc(sel.from, sel.to);
    from = sel.from;
    to = sel.to;
  } else {
    // 選択なし: カーソル行を行単位でコピー（CM6標準のフォールバックと同じ挙動）
    const line = view.state.doc.lineAt(sel.from);
    text = line.text;
    from = line.from;
    to = Math.min(line.to + 1, view.state.doc.length);
  }
  if (!text) return false;
  native.postMessage({ type: "copy", text });
  if (isCut) {
    view.dispatch({ changes: { from, to, insert: "" }, userEvent: "delete.cut" });
  }
  return true;
}

// 文書の世代番号。Swift 側が外部更新（同期反映）で文書を差し替えるたびに上がる。
// 編集は全文＋この世代番号で送り、Swift 側は古い世代の編集を破棄する。
// 差分（オフセット）方式は、同期による全文差し替えと交差した時に
// 「別の文書へ古い位置で適用」してしまい本文を壊すため使わない。
let docVersion = initPayload.version ?? 0;

const updateListener = EditorView.updateListener.of((u) => {
  if (!u.docChanged) return;
  if (u.transactions.some((t) => t.annotation(remote))) return;
  native.postMessage({
    type: "edit",
    text: u.state.doc.toString(),
    version: docVersion,
    // シェイク Undo（ネイティブの NSUndoManager プロキシ）の有効/無効表示用
    undoDepth: undoDepth(u.state),
    redoDepth: redoDepth(u.state),
  });
});

// カーソル・選択の「動いた側の端」を最小限だけ追従スクロールする。
// iOS のスペース長押し（トラックパッドモード）や選択ハンドルのドラッグは、
// 入れ子のスクローラ（.cm-scroller）を自動スクロールしてくれないため、
// 端で詰まって下へ進めない。y:"nearest" は見えていれば何もしないので、
// これが実質のオートスクロールとして働く（過剰な制御はしない）。
let lastSelAnchor = 0;
let lastSelHead = 0;
let pendingRevealPos: number | null = null;
const caretFollow = EditorView.updateListener.of((u) => {
  const sel = u.state.selection.main;
  if (u.transactions.some((t) => t.annotation(remote)))  {
    lastSelAnchor = sel.anchor;
    lastSelHead = sel.head;
    return;
  }
  if (!u.selectionSet && !u.docChanged) return;
  // 動いた側の端を追従（head が動けば head、anchor 側だけ動けば anchor）
  let pos = sel.head;
  if (sel.head === lastSelHead && sel.anchor !== lastSelAnchor) pos = sel.anchor;
  lastSelAnchor = sel.anchor;
  lastSelHead = sel.head;
  if (!u.view.hasFocus) return;

  const alreadyScheduled = pendingRevealPos != null;
  pendingRevealPos = pos;   // 連続イベントでは常に最新位置を使う
  if (alreadyScheduled) return;
  requestAnimationFrame(() => {
    const target = pendingRevealPos;
    pendingRevealPos = null;
    if (target == null || target > view.state.doc.length) return;
    view.dispatch({
      effects: EditorView.scrollIntoView(target, { y: "nearest", yMargin: 28 }),
    });
  });
});

// フォントサイズ・行間・左右余白・Web フォント（アプリ設定）を CSS に反映する。
// styles.css 側の :root で定義したカスタムプロパティ（--cn-*）の値をここで
// インラインスタイルとして直接書き換える。以前は <style> 要素の textContent を
// 書き換える方式だったが、WKWebView ではそれが computed style に反映されるまで
// 数百ms〜遅延することがあり（ページ表示直後だけ左寄せ・小さいフォントのまま
// しばらく変わらない不具合の原因だった）、インラインスタイル（プロパティの値）は
// stylesheet の再パースを伴わないため常に即時反映される。
const root = document.documentElement;
const fontLink = document.createElement("link");
fontLink.rel = "stylesheet";
let fontLinkAttached = false;

function applyConfig(
  fontSize: unknown,
  lineSpacing: unknown,
  horizontalInset: unknown,
  fontCSSURL: unknown,
  fontFamily: unknown
) {
  const fs = typeof fontSize === "number" ? fontSize : 16;
  const ls = typeof lineSpacing === "number" ? lineSpacing : 0;
  const hi = typeof horizontalInset === "number" ? horizontalInset : 0;

  // Web フォントの CSS（Google Fonts 等）を <link> で読み込む。
  // オフライン・読み込み失敗時はフォールバック（システムフォント）で表示される。
  const url = typeof fontCSSURL === "string" ? fontCSSURL.trim() : "";
  if (url) {
    if (fontLink.getAttribute("href") !== url) fontLink.setAttribute("href", url);
    if (!fontLinkAttached) {
      document.head.appendChild(fontLink);
      fontLinkAttached = true;
    }
  } else if (fontLinkAttached) {
    fontLink.remove();
    fontLinkAttached = false;
  }

  const fam = (typeof fontFamily === "string" ? fontFamily : "").replace(/["\\]/g, "").trim();
  const famList = fam
    ? `"${fam}", -apple-system, "Hiragino Sans", sans-serif`
    : `-apple-system, "Hiragino Sans", sans-serif`;

  root.style.setProperty("--cn-font-family", famList);
  root.style.setProperty("--cn-font-size", `${fs}px`);
  root.style.setProperty("--cn-line-height", `calc(1.45em + ${ls}px)`);
  root.style.setProperty("--cn-padding-h", `${16 + hi}px`);
  // padding が変わると画像の X 起点・使える幅も変わるため作り直す
  refreshImageLayout();
}

const view = new EditorView({
  parent: document.getElementById("editor")!,
  state: EditorState.create({
    doc: initPayload.text ?? "",
    extensions: [
      wikiTargetsField,
      mentionedTargetsField,
      livePreviewField,
      editorFocusedField,
      // フォーカス変化を State に流し込む（数式プレビューの表示判定などが参照する）
      EditorView.focusChangeEffect.of((_state, focusing) => setEditorFocused.of(focusing)),
      history(),
      // drawSelection / allowMultipleSelections は使わない:
      // CodeMirror の自前選択描画は、iOS のスペース長押し（トラックパッドモード）が動かす
      // ネイティブ選択と取り合いになり、カーソル移動が選択化・飛びに化ける。
      // ネイティブの選択描画に任せる（マルチカーソルは旧エディタにも無い機能なので不要）。
      EditorView.lineWrapping,
      EditorState.tabSize.of(2),
      // iOS の予測変換・候補バー（キーボード上部に出る帯）を抑制する。
      // 日本語入力そのものは autocorrect/spellcheck の対象外のため影響しない。
      EditorView.contentAttributes.of({
        autocorrect: "off",
        autocapitalize: "off",
        spellcheck: "false",
      }),
      liveStyling,
      imageField,
      mathPreview,
      autocompletion({
        override: [wikiCompletionSource],
        activateOnTyping: true,
      }),
      pasteImages(native),
      nativeClipboard,
      footerExtension,
      clickHandler,
      updateListener,
      caretFollow,
      keymap.of(completionKeymap),
      cnKeymap,
      keymap.of([...historyKeymap, ...defaultKeymap]),
    ],
  }),
});

// フォーカス状態をネイティブへ通知（キーボードツールバーの表示制御用）
view.contentDOM.addEventListener("focus", () => native.postMessage({ type: "focus" }));
view.contentDOM.addEventListener("blur", () => native.postMessage({ type: "blur" }));

// キーボード表示（＋ツールバー）でエディタの高さが縮んだ時、カーソルが表示域の外に
// 取り残されていれば最小限だけスクロールして見せる。
// y:"nearest" は「見えていれば何もしない」ので、通常のスクロール位置には干渉しない。
window.addEventListener("resize", () => {
  if (!view.hasFocus) return;
  requestAnimationFrame(() => {
    view.dispatch({
      effects: EditorView.scrollIntoView(view.state.selection.main.head, {
        y: "nearest",
        yMargin: 24,
      }),
    });
  });
});

// フッター（リンク元・2ホップ）のタップをネイティブへ流す
setFooterPoster(native);

// ビュー作成の直後・同じ同期実行の中で初期値を適用する（ブラウザが最初の paint をする前）。
// これにより「見出し・リストは即描画、余白・文字サイズだけ通信の往復後に反映される」という
// タイミング差（＝開いた瞬間は左寄せ→少し待つと揃う）が構造的に無くなる。
view.dispatch({
  effects: [
    setWikiTargets.of(initPayload.wikiTargets ?? []),
    setMentionedTargets.of(initPayload.mentionedTargets ?? []),
    setLivePreview.of(!!initPayload.livePreview),
  ],
});
applyConfig(
  initPayload.fontSize,
  initPayload.lineSpacing,
  initPayload.horizontalInset,
  initPayload.fontCSSURL,
  initPayload.fontFamily
);

// Web フォントの読み込み完了で文字幅が変わる → テーブルの測定キャッシュを捨てて再レイアウト
document.fonts?.addEventListener?.("loadingdone", () => {
  clearTableMeasureCache();
  refreshImageLayout();
});

function setDocText(text: string) {
  const cur = view.state.doc.toString();
  if (cur === text) return;
  const head = Math.min(view.state.selection.main.head, text.length);
  // 外部更新でスクロール位置を失わない（native の contentOffset 保存・復元と同じ）。
  const scrollTop = view.scrollDOM.scrollTop;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
    selection: { anchor: head },
    // 外部更新は Undo 履歴に乗せない（シェイク Undo で同期内容まで巻き戻さない）
    annotations: [remote.of(true), Transaction.addToHistory.of(false)],
  });
  view.requestMeasure({
    read: () => {},
    write: () => { view.scrollDOM.scrollTop = scrollTop; },
  });
}

// 自前のキーボード上ツールバー（Swiftのフローティングビュー）から呼ばれるコマンド実行口。
// inputAccessoryView を使わない代わりに、ボタン押下→ここでCM6コマンドを直接叩く。
window.couchNotesRunCommand = (name: string) => {
  switch (name) {
    case "wikiLink": insertWikiLink(view); break;
    case "listToggle": toggleListMarker(view); break;
    case "moveLineUp": moveLineUp(view); break;
    case "moveLineDown": moveLineDown(view); break;
    case "indent": indentLines(view); break;
    case "outdent": outdentLines(view); break;
    // iOS の標準 Undo ジェスチャは WebKit 側のスタックを見るため CM の履歴に届かない。
    // ツールバーから明示的に CM の履歴を叩く。
    case "undo": undo(view); break;
    case "redo": redo(view); break;
  }
  view.focus();
};

// ネイティブ発の画像アップロード（ツールバーのペースト・写真）用:
// カーソル位置にプレースホルダを挿し、その id を返す（evaluateJavaScript の戻り値になる）。
window.couchNotesInsertPlaceholder = () => insertUploadPlaceholder(view);

// Swift 側 evaluateJavaScript("window.couchNotesReceive({...})") から呼ばれる。
window.couchNotesReceive = (msg: any) => {
  switch (msg?.type) {
    case "init":
      if (typeof msg.version === "number") docVersion = msg.version;
      applyConfig(msg.fontSize, msg.lineSpacing, msg.horizontalInset, msg.fontCSSURL, msg.fontFamily);
      view.dispatch({
        effects: [
          setWikiTargets.of((msg.wikiTargets ?? []) as string[]),
          setMentionedTargets.of((msg.mentionedTargets ?? []) as string[]),
          setLivePreview.of(!!msg.livePreview),
        ],
      });
      setDocText(msg.text ?? "");
      break;
    case "externalUpdate":
      if (typeof msg.version === "number") docVersion = msg.version;
      setDocText(msg.text ?? "");
      break;
    case "wikiTargets":
      view.dispatch({
        effects: [
          setWikiTargets.of((msg.targets ?? []) as string[]),
          setMentionedTargets.of((msg.mentioned ?? []) as string[]),
        ],
      });
      break;
    case "config":
      applyConfig(msg.fontSize, msg.lineSpacing, msg.horizontalInset, msg.fontCSSURL, msg.fontFamily);
      view.dispatch({ effects: setLivePreview.of(!!msg.livePreview) });
      break;
    case "insertText": {
      // ツールバーのペースト（テキスト）等。ユーザー編集扱いで Swift 側へもエコーさせる。
      const t = String(msg.text ?? "");
      if (!t) break;
      const sel = view.state.selection.main;
      view.dispatch({
        changes: { from: sel.from, to: sel.to, insert: t },
        selection: { anchor: sel.from + t.length },
        userEvent: "input.paste",
      });
      view.focus();
      break;
    }
    case "pasteResult":
      applyPasteResult(view, msg);
      break;
    case "footer":
      setFooterData((msg.data ?? null) as FooterData | null);
      break;
    case "revealBlock": {
      // ブロック参照リンク（[[ページ#^ID]]）で開かれた: ^ID が行末に付く行へスクロールする。
      const id = String(msg.id ?? "").toLowerCase();
      if (!id) break;
      const doc = view.state.doc;
      for (let n = 1; n <= doc.lines; n++) {
        const line = doc.line(n);
        const bm = /\^([a-zA-Z0-9_-]+)\s*$/.exec(line.text);
        if (bm && bm[1].toLowerCase() === id) {
          // 初期レイアウト前に dispatch するとスクロール量が不正確になるため 1 フレーム待つ
          requestAnimationFrame(() => {
            view.dispatch({
              effects: EditorView.scrollIntoView(line.from, { y: "start", yMargin: 24 }),
            });
          });
          break;
        }
      }
      break;
    }
  }
};

native.postMessage({ type: "ready" });
