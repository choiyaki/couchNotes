// 画像 ![](http...) の表示。
//
// 表示方式は2系統:
//   1. 生表示の行（ライブプレビュー無効時・カーソル行）:
//      ネイティブ版と同じ「行下に padding で余白を予約し、絶対配置の <img> を重ねる」
//      オーバーレイ方式。本文 DOM は純粋なテキストのままで、iOS のネイティブ選択と干渉しない。
//   2. ライブプレビュー時の非アクティブ行:
//      記法を隠して、その位置に画像そのものをインラインウィジェットで表示（Cosense 風）。
//      カーソルが行に入るとウィジェットは消えて 1 の生表示に戻る。
//
// 拡張仕様（従来どおり）:
//   - ![|30](url) のように alt に |数値 を書くと、エディタ幅のその % を「幅」に指定。
//   - 同一行に複数の画像 URL を書くと横並び表示。幅指定の無い画像は残り幅を均等割り。
import { EditorState, Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import { livePreviewField, setLivePreview } from "./state";

const PLACEHOLDER_HEIGHT = 200; // 実寸が分かるまでの予約高さ（native placeholderHeight と同値）
const GAP = 6;                  // 行と画像・画像同士の間隔

// TEMP DEBUG: main.ts の diag() と同じ経路（native 経由）でログを転送する。
declare const window: any;
function diagLog(label: string, extra?: Record<string, unknown>) {
  try {
    window.webkit.messageHandlers.couchNotes.postMessage({
      type: "diagLog", label, t: performance.now(), info: extra ?? {},
    });
  } catch {}
}

interface ImgSpec {
  url: string;
  widthPct: number | null;
}

// ![alt](url) / ![|30](url) / ![alt|30](url)
const IMG_RE = /!\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/g;

function parseLine(text: string): ImgSpec[] {
  const specs: ImgSpec[] = [];
  IMG_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = IMG_RE.exec(text)); ) {
    const w = /\|\s*(\d+)/.exec(m[1]);
    specs.push({ url: m[2], widthPct: w ? Number(w[1]) : null });
  }
  return specs;
}

// 読み込み済み画像の実寸キャッシュとエディタ幅（モジュール共有）
const naturalSizes = new Map<string, { w: number; h: number }>();
let editorWidth = 0;
let viewRef: EditorView | null = null;

/** 画像レイアウトの再計算が必要になった（実寸判明・エディタ幅変化） */
export const imagesChanged = StateEffect.define<void>();

/** .cm-content の左右 padding（テキストの実開始位置）。config の横インセットもここに乗る。 */
function contentPadding(view: EditorView): { left: number; right: number } {
  const cs = getComputedStyle(view.contentDOM);
  return {
    left: parseFloat(cs.paddingLeft) || 0,
    right: parseFloat(cs.paddingRight) || 0,
  };
}

/** テキストが実際に使える幅（padding を除いた内側）。 */
function availableWidth(view: EditorView): number {
  const pad = contentPadding(view);
  return view.contentDOM.clientWidth - pad.left - pad.right;
}

/** 設定変更（横インセット等）で padding が変わった時に、画像レイアウトを作り直す。 */
export function refreshImageLayout() {
  if (!viewRef) return;
  const w = availableWidth(viewRef);
  if (w > 0) editorWidth = w;
  viewRef.dispatch({ effects: imagesChanged.of() });
}

/** グループ内の各画像の表示サイズ（native displaySize 相当） */
function groupSizes(specs: ImgSpec[], width: number): { w: number; h: number }[] {
  const sumSpecified = specs.reduce((a, s) => a + (s.widthPct ?? 0), 0);
  const unspecCount = specs.filter((s) => s.widthPct == null).length;
  const evenPct = unspecCount > 0 ? Math.max(0, 100 - sumSpecified) / unspecCount : 0;

  return specs.map((s) => {
    const nat = naturalSizes.get(s.url);
    if (s.widthPct != null || specs.length > 1) {
      const w = ((width - GAP * (specs.length - 1)) * (s.widthPct ?? evenPct)) / 100;
      return { w, h: nat ? (w * nat.h) / nat.w : PLACEHOLDER_HEIGHT };
    }
    // 単一・指定なし: アスペクト比を保ったまま「横幅＋縦幅」が本文幅と等しくなるサイズ
    // （native EditorImageStore.naturalSize と同じ規則。縦長は小さめ、横長は大きめに収まる）
    if (!nat) return { w: width * 0.5, h: PLACEHOLDER_HEIGHT };
    const aspect = nat.w / nat.h;
    const h = width / (aspect + 1);
    const w = aspect * h;
    if (w > width) return { w: width, h: width / aspect };  // 念のため幅は本文幅で頭打ち
    return { w, h };
  });
}

/** 行テキスト中の各画像（IMG_RE の出現順）の表示サイズ。decorations のインラインウィジェット用。 */
export function lineImageSizes(text: string): { url: string; w: number; h: number }[] {
  const specs = parseLine(text);
  if (specs.length === 0) return [];
  const width = editorWidth || 360;
  return groupSizes(specs, width).map((s, i) => ({ url: specs[i].url, w: s.w, h: s.h }));
}

/** テキストが使える現在のエディタ幅。view を渡すとその場で実測して自己修復する。
    （キャッシュ幅は、スタイルシート適用前に padding=0 で測れてしまう競合があり、
    そのまま使うと画像・テーブルが横パディングを無視した幅になる） */
export function editorContentWidth(view?: EditorView): number {
  if (view) {
    const fresh = availableWidth(view);
    if (fresh > 0 && Math.abs(fresh - editorWidth) > 1) {
      // TEMP DEBUG: 画像・テーブル幅が後から変わる問題の切り分け用
      diagLog("editorWidth-self-heal", { old: editorWidth, new: fresh });
      editorWidth = fresh;
      // 既に古い幅で描かれているものを次のフレームで作り直す
      requestAnimationFrame(() => viewRef?.dispatch({ effects: imagesChanged.of() }));
    }
  }
  return editorWidth || 360;
}

/** 画像の実寸が判明した時に呼ぶ（キャッシュ＋再レイアウト）。テーブルウィジェット等の外部から使う。 */
export function noteNaturalSize(url: string, w: number, h: number, view: EditorView) {
  if (naturalSizes.has(url) || w <= 0 || h <= 0) return;
  naturalSizes.set(url, { w, h });
  view.dispatch({ effects: imagesChanged.of() });
}

/** ライブプレビューの非アクティブ行に画像を直接描くインラインウィジェット。
    href 付き（[![](img)](url)）はタップで外部リンクを開く（main.ts の clickHandler が拾う）。 */
export class InlineImageWidget extends WidgetType {
  constructor(
    readonly url: string,
    readonly w: number,
    readonly h: number,
    readonly href: string | null
  ) {
    super();
  }
  eq(other: InlineImageWidget) {
    return (
      other.url === this.url &&
      Math.abs(other.w - this.w) < 1 &&
      Math.abs(other.h - this.h) < 1 &&
      other.href === this.href
    );
  }
  ignoreEvent() {
    return false; // クリックは contentDOM のハンドラへバブルさせる（リンク画像用）
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement("span");
    wrap.className = "cm-cn-inline-img" + (this.href ? " cm-cn-linked-img" : "");
    if (this.href) wrap.setAttribute("data-href", this.href);
    const img = document.createElement("img");
    img.src = this.url;
    img.style.width = `${Math.round(this.w)}px`;
    img.style.height = `${Math.round(this.h)}px`;
    img.addEventListener("load", () => {
      if (naturalSizes.has(this.url)) return;
      naturalSizes.set(this.url, { w: img.naturalWidth, h: img.naturalHeight });
      view.dispatch({ effects: imagesChanged.of() }); // 実寸でサイズを作り直す
    });
    wrap.appendChild(img);
    return wrap;
  }
}

/** 画像行に padding-bottom で余白を予約する行デコレーション。
    ライブプレビュー時は画像をインラインウィジェットで行内に描く（アクティブ行も併置）ため、
    オーバーレイ＋余白予約は「ライブプレビュー無効時」だけ使う。 */
function buildPaddings(state: EditorState): DecorationSet {
  if (state.field(livePreviewField)) return Decoration.set([]);
  const width = editorWidth || 360;
  const out: Range<Decoration>[] = [];
  for (let i = 1; i <= state.doc.lines; i++) {
    const line = state.doc.line(i);
    const specs = parseLine(line.text);
    if (specs.length === 0) continue;
    const rowH = Math.max(...groupSizes(specs, width).map((s) => s.h));
    const pad = Math.round(rowH) + GAP * 2;
    out.push(
      Decoration.line({ attributes: { style: `padding-bottom:${pad}px` } }).range(line.from)
    );
  }
  return Decoration.set(out, true);
}

const imagePaddingField = StateField.define<DecorationSet>({
  create: buildPaddings,
  update(deco, tr) {
    if (
      tr.docChanged ||
      tr.effects.some((e) => e.is(imagesChanged) || e.is(setLivePreview))
    ) {
      return buildPaddings(tr.state);
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

interface Placed {
  url: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 予約した余白へ <img> を絶対配置するオーバーレイ */
const imageOverlay = ViewPlugin.fromClass(
  class {
    container: HTMLDivElement;
    ro: ResizeObserver;

    constructor(readonly view: EditorView) {
      viewRef = view;
      // オーバーレイをコンテンツと一緒にスクロールさせるため、スクローラを基準にする
      view.scrollDOM.style.position = "relative";
      this.container = document.createElement("div");
      this.container.className = "cm-cn-image-overlay";
      Object.assign(this.container.style, {
        position: "absolute",
        top: "0",
        left: "0",
        width: "0",
        height: "0",
        pointerEvents: "none", // タッチ・選択操作は本文へ素通しする
      } as Partial<CSSStyleDeclaration>);
      view.scrollDOM.appendChild(this.container);
      this.ro = new ResizeObserver(() => this.syncWidth());
      this.ro.observe(view.scrollDOM);
      this.schedule();
    }

    syncWidth() {
      const w = availableWidth(this.view);
      if (w > 0 && Math.abs(w - editorWidth) > 1) {
        // TEMP DEBUG
        diagLog("imageOverlay-syncWidth", { old: editorWidth, new: w });
        editorWidth = w;
        requestAnimationFrame(() => viewRef?.dispatch({ effects: imagesChanged.of() }));
      }
      this.schedule();
    }

    update(u: ViewUpdate) {
      if (
        u.docChanged ||
        u.viewportChanged ||
        u.geometryChanged ||
        u.transactions.some((t) =>
          t.effects.some((e) => e.is(imagesChanged) || e.is(setLivePreview))
        )
      ) {
        this.schedule();
      }
    }

    schedule() {
      this.view.requestMeasure({
        read: () => this.read(),
        write: (placed: Placed[]) => this.write(placed),
      });
    }

    read(): Placed[] {
      const view = this.view;
      // ライブプレビュー時は画像をインラインウィジェットで描くため、オーバーレイは出さない
      if (view.state.field(livePreviewField)) return [];
      const width = editorWidth || availableWidth(view) || 360;
      const scrollerRect = view.scrollDOM.getBoundingClientRect();
      const contentRect = view.contentDOM.getBoundingClientRect();
      const scrollTop = view.scrollDOM.scrollTop;
      // 画像の X 起点はテキストの実開始位置（content の左端 + padding-left）
      const originX = contentRect.left - scrollerRect.left + contentPadding(view).left;
      const docTop = view.documentTop; // クライアント座標での文書先頭 Y

      const placed: Placed[] = [];
      const doc = view.state.doc;
      for (let i = 1; i <= doc.lines; i++) {
        const line = doc.line(i);
        const specs = parseLine(line.text);
        if (specs.length === 0) continue;
        const block = view.lineBlockAt(line.from);
        const sizes = groupSizes(specs, width);
        const rowH = Math.max(...sizes.map((s) => s.h));
        // 行ブロックの底（予約 padding を含む）から画像高さぶん上が画像の Y
        const y = docTop + block.bottom - rowH - GAP - scrollerRect.top + scrollTop;
        let x = originX;
        for (let k = 0; k < specs.length; k++) {
          placed.push({ url: specs[k].url, x, y, w: sizes[k].w, h: sizes[k].h });
          x += sizes[k].w + GAP;
        }
      }
      return placed;
    }

    write(placed: Placed[]) {
      const kids = this.container.children;
      while (kids.length > placed.length) kids[kids.length - 1].remove();
      while (kids.length < placed.length) {
        const img = document.createElement("img");
        img.addEventListener("load", () => {
          const key = img.getAttribute("src") ?? "";
          if (!key || naturalSizes.has(key)) return;
          naturalSizes.set(key, { w: img.naturalWidth, h: img.naturalHeight });
          viewRef?.dispatch({ effects: imagesChanged.of() }); // 実寸で余白を作り直す
        });
        this.container.appendChild(img);
      }
      for (let i = 0; i < placed.length; i++) {
        const img = kids[i] as HTMLImageElement;
        const p = placed[i];
        if (img.getAttribute("src") !== p.url) img.setAttribute("src", p.url);
        Object.assign(img.style, {
          position: "absolute",
          left: `${Math.round(p.x)}px`,
          top: `${Math.round(p.y)}px`,
          width: `${Math.round(p.w)}px`,
          height: `${Math.round(p.h)}px`,
          objectFit: "cover",
          borderRadius: "6px",
        } as Partial<CSSStyleDeclaration>);
      }
    }

    destroy() {
      this.ro.disconnect();
      this.container.remove();
      if (viewRef === this.view) viewRef = null;
    }
  }
);

export const imageField = [imagePaddingField, imageOverlay];
