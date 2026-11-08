// 【診断用・一時】iPad のハードウェアキーボードで Enter を押すと入力が消える件の調査。
// CodeMirror は iOS で Enter を保留し（pendingIOSKey）、直後に来た本文の変化を捨てて
// Enter のコマンドに置き換える（flushIOSKey）。その「捨てた変化」を画面の上に数秒出す。
// 文字が消えたときにこの表示が出れば、原因はこの仕組みと確かめられる。原因がわかったら外す。
import { EditorView } from "@codemirror/view";

// 直近の Enter の keydown（IME の変換中だったか）
let lastEnter: { at: number; isComposing: boolean; keyCode: number } | null = null;
let lastCompositionEnd = 0;

let box: HTMLDivElement | null = null;
let hideTimer: number | undefined;

function show(message: string) {
  if (!box) {
    box = document.createElement("div");
    box.style.cssText =
      "position:fixed;top:8px;left:8px;right:8px;z-index:9999;padding:8px 10px;" +
      "background:rgba(200,30,30,0.92);color:#fff;font:12px/1.4 -apple-system,sans-serif;" +
      "border-radius:8px;white-space:pre-wrap;word-break:break-all;pointer-events:none;";
    document.body.appendChild(box);
  }
  box.textContent = message;
  box.style.display = "block";
  window.clearTimeout(hideTimer);
  hideTimer = window.setTimeout(() => { if (box) box.style.display = "none"; }, 6000);
}

export function installEnterDiag(view: EditorView) {
  const dom = view.contentDOM;
  // CodeMirror より先に見るため capture で付ける（見るだけで、何も止めない）
  dom.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.keyCode === 13 || e.keyCode === 229) {
      lastEnter = { at: Date.now(), isComposing: e.isComposing, keyCode: e.keyCode };
    }
  }, true);
  dom.addEventListener("compositionend", () => { lastCompositionEnd = Date.now(); }, true);

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
      const now = Date.now();
      const lines = [
        "Enter の保留で、入力を捨てました（診断）",
        `捨てた挿入: ${JSON.stringify(change!.insert.toString())}`,
        `置き換え対象: ${JSON.stringify(removed)}（${change!.from}〜${change!.to}）`,
        lastEnter
          ? `Enter keydown: ${now - lastEnter.at}ms 前・keyCode=${lastEnter.keyCode}・isComposing=${lastEnter.isComposing}`
          : "Enter keydown: 記録なし",
        `compositionend: ${lastCompositionEnd ? `${now - lastCompositionEnd}ms 前` : "なし"}`,
      ];
      show(lines.join("\n"));
    }
    return handled;
  };
}
