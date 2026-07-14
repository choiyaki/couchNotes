// wiki リンクの存在判定・サジェストに使う「ワークスペース内ノート名（原文表記）」を保持。
import { StateEffect, StateField } from "@codemirror/state";

export const setWikiTargets = StateEffect.define<string[]>();

export const wikiTargetsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setWikiTargets)) return e.value;
    }
    return value;
  },
});

// どこかのノートの [[...]] に登場するが、まだページが存在しない名前（正規化済み・小文字）。
// サジェスト専用。リンクの存在色分けには使わない（wikiTargetsField と分離）。
export const setMentionedTargets = StateEffect.define<string[]>();

export const mentionedTargetsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setMentionedTargets)) return e.value;
    }
    return value;
  },
});
