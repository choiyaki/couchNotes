// [[ 入力時にノート名を候補表示する（couchNotes のサジェストパネル相当）。
// 実在ノートに加えて、どこかの [[...]] に登場するだけの未作成ページ名も候補に出す
// （Cosense / Obsidian と同様）。
import { CompletionContext, CompletionResult, Completion } from "@codemirror/autocomplete";
import { EditorView } from "@codemirror/view";
import { wikiTargetsField, mentionedTargetsField } from "./state";

/**
 * 直前テキストが [[query（]] や改行を挟まない）のときだけ発火。
 * couchNotes の wikiLinkQuery と同じく、部分一致（contains）で絞り込む。
 */
export function wikiCompletionSource(context: CompletionContext): CompletionResult | null {
  // [[ の直後からカーソルまで（] を含まない）
  const before = context.matchBefore(/\[\[[^\]\n]*$/);
  if (!before) return null;

  const query = before.text.slice(2); // 先頭 "[[" を除く
  const from = before.from + 2; // 候補を差し込む開始位置（[[ の直後）
  const lower = query.toLowerCase();

  // 確定時の挿入（"]]" の重複を防ぐ共通処理）
  const applyName =
    (name: string) =>
    (view: EditorView, _c: Completion, aFrom: number, aTo: number) => {
      // すでにカーソル直後に "]]"（ツールバー挿入由来）があれば取り込み、]]]] を防ぐ
      const hasClose = view.state.sliceDoc(aTo, aTo + 2) === "]]";
      const insert = name + "]]";
      view.dispatch({
        changes: { from: aFrom, to: hasClose ? aTo + 2 : aTo, insert },
        selection: { anchor: aFrom + insert.length },
        userEvent: "input.complete",
      });
    };

  const names = context.state.field(wikiTargetsField);
  const existing: Completion[] = names
    .filter((n) => n.toLowerCase().includes(lower))
    .slice(0, 50)
    .map((name) => ({
      label: name,
      type: "text",
      apply: applyName(name),
    }));

  // 未作成ページ（言及のみ・正規化済み小文字）。実在ノートと同名は除外し、実在の後ろに並べる。
  const existingLower = new Set(names.map((n) => n.toLowerCase()));
  const mentioned: Completion[] = context.state
    .field(mentionedTargetsField)
    .filter((n) => n.includes(lower) && !existingLower.has(n))
    .slice(0, 30)
    .map((name) => ({
      label: name,
      type: "text",
      detail: "未作成",
      apply: applyName(name),
    }));

  const options = [...existing, ...mentioned];
  if (options.length === 0) return null;
  // contains で自前フィルタ済みなので CM 側の再フィルタは無効化
  return { from, options, filter: false };
}
