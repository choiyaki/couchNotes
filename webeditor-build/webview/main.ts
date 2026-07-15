// couchnotes-vscode/webview/main.ts のネイティブ（WKWebView）版。
// VSCode の acquireVsCodeApi()/window message の代わりに、
// window.webkit.messageHandlers 経由でSwift側と直接やり取りする。
import "./styles.css";
import { Annotation, EditorState, Transaction } from "@codemirror/state";
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

// TEMP DEBUG: 開いた瞬間の左寄り表示・画像サイズのタイミング切り分け用。
// console.log に加えて native へも転送し、Xcode/コンソール.app の Swift ログと
// 同じ場所で時系列を突き合わせられるようにする（Safari Web Inspector 不要）。
const diagT0 = performance.now();
function diag(label: string, extra?: Record<string, unknown>) {
  const editor = document.getElementById("editor");
  const info = {
    windowInnerWidth: window.innerWidth,
    editorClientWidth: editor?.clientWidth,
    hasInitPayload: !!window.__couchNotesInit,
    horizontalInset: initPayload.horizontalInset,
    ...extra,
  };
  console.log(`[cn-diag] ${label} t=${(performance.now() - diagT0).toFixed(1)}ms`, info);
  native.postMessage({ type: "diagLog", label, t: performance.now() - diagT0, info });
}
diag("script-start");

// 拡張ホスト（Swift）由来の transaction を識別し、編集メッセージのエコーを防ぐ。
const remote = Annotation.define<boolean>();

// --- リンク判定（クリック追従用） ---
type LinkHit = { kind: "wiki" | "external"; value: string };
function linkAt(text: string, col: number): LinkHit | null {
  for (const m of text.matchAll(/\[\[([^\]]+)\]\]/g)) {
    const s = m.index!;
    if (col >= s && col < s + m[0].length) return { kind: "wiki", value: m[1] };
  }
  for (const m of text.matchAll(/(?<!!)\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g)) {
    const s = m.index!;
    if (col >= s && col < s + m[0].length) return { kind: "external", value: m[1] };
  }
  for (const m of text.matchAll(/https?:\/\/[^\s)\]]+/g)) {
    const s = m.index!;
    if (col >= s && col < s + m[0].length) return { kind: "external", value: m[0] };
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
      if (hit.kind === "wiki") native.postMessage({ type: "openWiki", target: hit.value });
      else native.postMessage({ type: "openExternal", url: hit.value });
      e.preventDefault();
      return true;
    }
    return false;
  },
});

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
// TEMP DEBUG: Web フォントの <link> 読み込み完了/失敗のタイミングを見る。
// 旧方式（<style> 書き換え）での反映遅延が、この <link> 挿入（新しい外部スタイル
// シートの追加）にブラウザ側のスタイル解決が引きずられていたせいかどうかを
// 切り分けるためのログ。もしこれの load/error と反映タイミングが一致するなら
// それが根本原因ということになる。
fontLink.addEventListener("load", () => diag("fontLink-load", { href: fontLink.getAttribute("href") }));
fontLink.addEventListener("error", () => diag("fontLink-error", { href: fontLink.getAttribute("href") }));

function applyConfig(
  fontSize: unknown,
  lineSpacing: unknown,
  horizontalInset: unknown,
  fontCSSURL: unknown,
  fontFamily: unknown
) {
  // TEMP DEBUG: 生の引数の型と値をそのまま見る
  diag("applyConfig-enter", {
    fontSizeType: typeof fontSize, fontSizeVal: String(fontSize),
    hiType: typeof horizontalInset, hiVal: String(horizontalInset),
  });
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

  // TEMP DEBUG: カスタムプロパティが実際に computed style へ反映されるまでの
  // タイムラグを追う（本当に即時反映されるのか、何か別要因でまだ遅延するのか）。
  const checkApplied = (label: string) => {
    diag(label, {
      cssVarFontSize: getComputedStyle(root).getPropertyValue("--cn-font-size"),
      cssVarPaddingH: getComputedStyle(root).getPropertyValue("--cn-padding-h"),
      computedFontSize: getComputedStyle(view.contentDOM).fontSize,
      computedPaddingLeft: getComputedStyle(view.contentDOM).paddingLeft,
    });
  };
  checkApplied("applyConfig-check-sync");
  requestAnimationFrame(() => checkApplied("applyConfig-check-raf"));
  for (const ms of [50, 150, 300, 600, 1200]) {
    setTimeout(() => checkApplied(`applyConfig-check-t${ms}`), ms);
  }
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

diag("view-created", {
  contentClientWidth: view.contentDOM.clientWidth,
  scrollClientWidth: view.scrollDOM.clientWidth,
});

// フォーカス状態をネイティブへ通知（キーボードツールバーの表示制御用）
view.contentDOM.addEventListener("focus", () => {
  diag("focus", { contentClientWidth: view.contentDOM.clientWidth });
  native.postMessage({ type: "focus" });
});
view.contentDOM.addEventListener("blur", () => native.postMessage({ type: "blur" }));

// TEMP DEBUG: WKWebView 自体のサイズ確定タイミングを見る
new ResizeObserver((entries) => {
  for (const e of entries) {
    diag("editor-resize", { boxWidth: e.contentRect.width });
  }
}).observe(document.getElementById("editor")!);

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
diag("applyConfig-done", {
  computedPaddingLeft: getComputedStyle(view.contentDOM).paddingLeft,
  computedFontSize: getComputedStyle(view.contentDOM).fontSize,
});

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
  }
};

native.postMessage({ type: "ready" });
