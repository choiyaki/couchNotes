// 【診断用・一時】iPad のハードウェアキーボードで Enter を押すと入力が消える件の調査。
// 1回目の診断で、日本語の変換が Enter より前に打ち切られ（compositionend）、残った文字が
// 「選択範囲」になり、Enter がそれを改行で置き換えて消していると分かった。
// 何が変換を打ち切るのかを知るため、直前の出来事（変換・打鍵・Swift からの更新・エディタの更新）を
// 記録し、次のときに画面の上へ出す。原因がわかったら外す。
// - 変換が終わった直後に、選択範囲が残った
// - 変換が終わって間もなく、選択範囲があるまま Enter が押された
// - CodeMirror が Enter を保留して、入力を捨てた（flushIOSKey）
import { EditorView, ViewUpdate } from "@codemirror/view";

const KEEP_MS = 3000;
const MAX_EVENTS = 40;

type DiagEvent = { at: number; text: string };
const events: DiagEvent[] = [];
let lastCompositionEnd = 0;
let lastCompositionUpdate = 0;

/** 出来事を1つ記録する（main.ts から、Swift から届いた更新の種類も記録する） */
export function diagEvent(text: string) {
  const now = Date.now();
  events.push({ at: now, text });
  while (events.length > MAX_EVENTS || (events.length && now - events[0].at > KEEP_MS)) events.shift();
}

function timeline(now: number): string {
  return events
    .filter((e) => now - e.at <= KEEP_MS)
    .map((e) => `${String(e.at - now).padStart(6)}ms ${e.text}`)
    .join("\n");
}

function short(s: string): string {
  const t = JSON.stringify(s);
  return t.length > 24 ? t.slice(0, 22) + "…\"" : t;
}

let box: HTMLDivElement | null = null;
let hideTimer: number | undefined;
let shownAt = 0;

function show(title: string, detail: string[]) {
  const now = Date.now();
  // 同じ出来事で続けて出すと、最初の内容が上書きされて読めないので、少し間を空ける
  if (now - shownAt < 1500) return;
  shownAt = now;
  if (!box) {
    box = document.createElement("div");
    box.style.cssText =
      "position:fixed;top:8px;left:8px;right:8px;z-index:9999;padding:8px 10px;" +
      "background:rgba(200,30,30,0.92);color:#fff;font:11px/1.35 ui-monospace,Menlo,monospace;" +
      "border-radius:8px;white-space:pre-wrap;word-break:break-all;pointer-events:none;" +
      "max-height:80vh;overflow:hidden;";
    document.body.appendChild(box);
  }
  box.textContent = [title, ...detail, "--- 直前の出来事（0ms = 帯を出した時） ---", timeline(now)].join("\n");
  box.style.display = "block";
  window.clearTimeout(hideTimer);
  hideTimer = window.setTimeout(() => { if (box) box.style.display = "none"; }, 15000);
}

/** 画面（DOM）の選択範囲のうち、エディタの中にあるものの文字列 */
function domSelectionText(view: EditorView): string {
  const sel = document.getSelection();
  if (!sel || sel.isCollapsed || !sel.anchorNode) return "";
  if (!view.contentDOM.contains(sel.anchorNode)) return "";
  return sel.toString();
}

function selectionSummary(view: EditorView): string {
  const s = view.state.selection.main;
  const cm = s.empty ? "なし" : `${short(view.state.sliceDoc(s.from, s.to))}（${s.from}〜${s.to}）`;
  const dom = domSelectionText(view);
  return `選択: CodeMirror=${cm}・画面=${dom ? short(dom) : "なし"}`;
}

/** エディタの更新を記録する拡張。入力と、それ以外（Swift からの更新・自前の dispatch）を見分ける */
export const enterDiagListener = EditorView.updateListener.of((u: ViewUpdate) => {
  const composing = u.view.composing ? "変換中" : "";
  if (!u.transactions.length) {
    const flags = [u.viewportChanged && "viewport", u.geometryChanged && "geometry", u.focusChanged && "focus"]
      .filter(Boolean).join(",");
    diagEvent(`更新(取引なし) ${flags} ${composing}`);
    return;
  }
  for (const tr of u.transactions) {
    const ev = ["input", "delete", "select", "undo", "redo", "move"].find((t) => tr.isUserEvent(t)) ?? "-";
    const parts = [`更新 ${ev}`];
    if (tr.docChanged) parts.push("本文");
    if (tr.selection) parts.push("選択");
    if (tr.effects.length) parts.push(`効果${tr.effects.length}`);
    if (composing) parts.push(composing);
    diagEvent(parts.join(" "));
  }
});

export function installEnterDiag(view: EditorView) {
  // Swift 側（Mac 版）から、レスポンダーチェーンの調べた結果を出す口
  (window as any).couchNotesShowDiag = (title: string, lines: string[]) => {
    shownAt = 0;   // 他の帯の間隔の制限を受けずに出す
    show(title, Array.isArray(lines) ? lines.map(String) : []);
  };
  const dom = view.contentDOM;
  // CodeMirror より先に見るため capture で付ける（見るだけで、何も止めない）
  dom.addEventListener("compositionstart", () => diagEvent("compositionstart"), true);
  dom.addEventListener("compositionupdate", (e) => {
    lastCompositionUpdate = Date.now();
    diagEvent(`compositionupdate ${short((e as CompositionEvent).data ?? "")}`);
  }, true);
  dom.addEventListener("compositionend", (e) => {
    lastCompositionEnd = Date.now();
    diagEvent(`compositionend ${short((e as CompositionEvent).data ?? "")}`);
    // 変換の確定が反映された後に、選択範囲が残っていないかを見る
    for (const delay of [0, 120]) {
      window.setTimeout(() => {
        const dom = domSelectionText(view);
        const cm = !view.state.selection.main.empty;
        if (dom || cm) {
          diagEvent(`変換後に選択あり（${delay}ms 後）`);
          show("変換の後に、選択範囲が残りました（診断）", [selectionSummary(view)]);
        }
      }, delay);
    }
  }, true);
  dom.addEventListener("keydown", (e) => {
    const k = e.key === " " ? "Space" : e.key;
    diagEvent(`keydown ${k} code=${e.keyCode}${e.isComposing ? " 変換中" : ""}`);
    // Mac 版: 変換中の矢印キーで候補を選べない件。届いたキーの様子と、その後の出来事を出す。
    // iPad（タッチあり）では矢印キーで選べているので出さない
    if (navigator.maxTouchPoints === 0 && /^Arrow/.test(e.key) &&
        (e.isComposing || e.keyCode === 229 || view.composing || Date.now() - lastCompositionUpdate < KEEP_MS)) {
      const cmComposing = (view as any).inputState?.composing;
      window.setTimeout(() => {
        show("Mac: 変換中に矢印キーが届きました（診断）", [
          `key=${e.key}・keyCode=${e.keyCode}・isComposing=${e.isComposing}`,
          `既定の動作を止めた（preventDefault）: ${e.defaultPrevented}`,
          `CodeMirror の変換の状態: composing=${cmComposing}・view.composing=${view.composing}`,
          selectionSummary(view),
        ]);
      }, 400);
    }
    if (e.key !== "Enter" && e.keyCode !== 13) return;
    if (Date.now() - lastCompositionEnd > KEEP_MS) return;
    if (!domSelectionText(view) && view.state.selection.main.empty) return;
    show("変換の後、選択範囲があるまま Enter が押されました（診断）", [
      selectionSummary(view),
      `isComposing=${e.isComposing}・compositionend は ${Date.now() - lastCompositionEnd}ms 前`,
    ]);
  }, true);
  dom.addEventListener("beforeinput", (e) => {
    const ie = e as InputEvent;
    diagEvent(`beforeinput ${ie.inputType} ${short(ie.data ?? "")}`);
  }, true);
  dom.addEventListener("blur", () => diagEvent("blur"), true);

  // CodeMirror の内部（InputState.flushIOSKey）を、このビューの分だけ包む
  const inputState = (view as any).inputState;
  if (!inputState || typeof inputState.flushIOSKey !== "function") return;
  const original = inputState.flushIOSKey.bind(inputState);
  inputState.flushIOSKey = (change?: { from: number; to: number; insert: { toString(): string } }) => {
    const pending = inputState.pendingIOSKey as { key: string } | undefined;
    // 位置は Enter を当てる前の本文のものなので、先に切り出しておく
    const removed = change ? view.state.sliceDoc(change.from, change.to) : "";
    const handled = original(change);
    // change があり、Enter に置き換えた（＝その変化は本文に入らなかった）ときだけ出す。
    // 改行だけの挿入は、Enter そのものの分なので出さない
    const lost = !!change && (/\S/.test(change.insert.toString()) || change.from < change.to);
    if (handled && lost && pending?.key === "Enter") {
      diagEvent("Enter の保留で入力を捨てた");
      show("Enter の保留で、入力を捨てました（診断）", [
        `捨てた挿入: ${short(change!.insert.toString())}`,
        `置き換え対象: ${short(removed)}（${change!.from}〜${change!.to}）`,
      ]);
    }
    return handled;
  };
}
