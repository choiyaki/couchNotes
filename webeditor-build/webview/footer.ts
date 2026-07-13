// 本文末尾のリンクフッター（リンク元＋2ホップリンク）。
// 画像オーバーレイと同じく scrollDOM に絶対配置し、文書終端の下に置いて
// 本文と一緒にスクロールさせる（contenteditable の外なので選択・カーソルに干渉しない）。
//
// 2ホップリンク: このノートの発リンク先（[[A]] 等）をグループ見出しにして、
// その下に「同じ A へリンクしている他のノート」を並べる（Scrapbox / Obsidian 2Hop Links と同様）。
import { EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";

export interface FooterNote {
  id: string;
  title: string;
  preview?: string;
}
export interface FooterGroup {
  targetTitle: string;
  targetId?: string | null;
  notes: FooterNote[];
}
export interface FooterData {
  backlinks: FooterNote[];
  twoHop: FooterGroup[];
  layout: "list" | "grid";
}

interface Poster {
  postMessage(msg: unknown): void;
}

let nativeRef: Poster | null = null;
let viewRef: EditorView | null = null;
let containerRef: HTMLDivElement | null = null;
let currentData: FooterData | null = null;

export function setFooterPoster(p: Poster) {
  nativeRef = p;
}

/** ネイティブから届いたフッターデータを反映する。 */
export function setFooterData(data: FooterData | null) {
  currentData = data;
  render();
  // 高さが変わるので位置を測り直す
  viewRef?.requestMeasure();
}

function noteButton(note: FooterNote): HTMLElement {
  const item = document.createElement("div");
  item.className = "cn-footer-item";
  const title = document.createElement("div");
  title.className = "cn-footer-item-title";
  title.textContent = note.title;
  item.appendChild(title);
  if (note.preview) {
    const body = document.createElement("div");
    body.className = "cn-footer-item-preview";
    body.textContent = note.preview;
    item.appendChild(body);
  }
  item.addEventListener("mousedown", (e) => {
    e.preventDefault();
    e.stopPropagation();
    nativeRef?.postMessage({ type: "openNote", id: note.id });
  });
  return item;
}

function sectionHeader(text: string, targetId?: string | null): HTMLElement {
  const h = document.createElement("div");
  h.className = "cn-footer-section" + (targetId ? " cn-footer-section-link" : "");
  h.textContent = text;
  if (targetId) {
    h.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      nativeRef?.postMessage({ type: "openNote", id: targetId });
    });
  }
  return h;
}

function render() {
  const container = containerRef;
  if (!container) return;
  container.textContent = "";
  const data = currentData;
  const hasContent =
    !!data && (data.backlinks.length > 0 || data.twoHop.length > 0);
  container.style.display = hasContent ? "block" : "none";
  if (!data || !hasContent) return;

  // ヘッダー行（タイトル＋リスト/グリッド切替）
  const head = document.createElement("div");
  head.className = "cn-footer-head";
  const title = document.createElement("div");
  title.className = "cn-footer-title";
  title.textContent = "リンク";
  head.appendChild(title);

  const toggles = document.createElement("div");
  toggles.className = "cn-footer-toggles";
  for (const [mode, glyph] of [["list", "☰"], ["grid", "▦"]] as const) {
    const b = document.createElement("button");
    b.className = "cn-footer-toggle" + (data.layout === mode ? " cn-on" : "");
    b.textContent = glyph;
    b.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      nativeRef?.postMessage({ type: "footerLayout", value: mode });
    });
    toggles.appendChild(b);
  }
  head.appendChild(toggles);
  container.appendChild(head);

  const itemsClass = data.layout === "grid" ? "cn-footer-items cn-footer-grid" : "cn-footer-items";

  if (data.backlinks.length > 0) {
    container.appendChild(sectionHeader(`リンク元 (${data.backlinks.length})`));
    const wrap = document.createElement("div");
    wrap.className = itemsClass;
    for (const n of data.backlinks) wrap.appendChild(noteButton(n));
    container.appendChild(wrap);
  }

  for (const g of data.twoHop) {
    container.appendChild(sectionHeader(`→ ${g.targetTitle}`, g.targetId));
    if (g.notes.length === 0) continue;
    const wrap = document.createElement("div");
    wrap.className = itemsClass;
    for (const n of g.notes) wrap.appendChild(noteButton(n));
    container.appendChild(wrap);
  }
}

/** 文書終端の下へフッターを配置する ViewPlugin。 */
const footerPlugin = ViewPlugin.fromClass(
  class {
    constructor(readonly view: EditorView) {
      viewRef = view;
      view.scrollDOM.style.position = "relative";
      const el = document.createElement("div");
      el.className = "cn-footer";
      el.style.position = "absolute";
      el.style.display = "none";
      view.scrollDOM.appendChild(el);
      containerRef = el;
      render();
      this.schedule();
    }

    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.geometryChanged) this.schedule();
    }

    schedule() {
      this.view.requestMeasure({
        read: () => {
          const view = this.view;
          const scrollerRect = view.scrollDOM.getBoundingClientRect();
          const contentRect = view.contentDOM.getBoundingClientRect();
          const cs = getComputedStyle(view.contentDOM);
          const padLeft = parseFloat(cs.paddingLeft) || 0;
          const padRight = parseFloat(cs.paddingRight) || 0;
          const padBottom = parseFloat(cs.paddingBottom) || 0;
          return {
            // 本文終端（下余白の手前）＝ content の底 - padding-bottom
            top: contentRect.bottom - padBottom - scrollerRect.top + view.scrollDOM.scrollTop + 24,
            left: contentRect.left - scrollerRect.left + padLeft,
            width: view.contentDOM.clientWidth - padLeft - padRight,
          };
        },
        write: (m: { top: number; left: number; width: number }) => {
          const el = containerRef;
          if (!el) return;
          el.style.top = `${Math.round(m.top)}px`;
          el.style.left = `${Math.round(m.left)}px`;
          el.style.width = `${Math.round(m.width)}px`;
        },
      });
    }

    destroy() {
      containerRef?.remove();
      containerRef = null;
      if (viewRef === this.view) viewRef = null;
    }
  }
);

export const footerExtension = footerPlugin;
