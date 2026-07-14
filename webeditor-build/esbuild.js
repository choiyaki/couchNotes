// couchNotes アプリの WKWebView に埋め込む CodeMirror エディタをビルドする。
// couchnotes-vscode/webview の装飾・コマンドロジックを流用し、VSCode 依存部分だけ
// ネイティブブリッジ（main.ts）に差し替えている。
const esbuild = require("esbuild");
const fs = require("fs");
const path = require("path");

const production = process.argv.includes("--production");
const outDir = path.join(__dirname, "..", "couchNotes", "WebEditor");

/** @type {import('esbuild').BuildOptions} */
const webviewConfig = {
  entryPoints: ["webview/main.ts"],
  bundle: true,
  outfile: path.join(outDir, "webview.js"),
  platform: "browser",
  format: "iife",
  sourcemap: !production,
  minify: production,
  logLevel: "info",
  // KaTeX の CSS が参照するフォントを WebEditor へコピーする（オフラインで数式を出すため）。
  // WebKit は woff2 を使うので、woff/ttf のフォールバックは空にしてサイズを抑える。
  loader: {
    ".woff2": "file",
    ".woff": "empty",
    ".ttf": "empty",
  },
  // サブフォルダは使わない: Xcode のフォルダ同期はバンドルへ平坦コピーするため、
  // css の相対参照 (./fonts/...) が実機で 404 になる。同じ階層に置く。
  assetNames: "[name]",
};

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  await esbuild.build(webviewConfig);

  // woff/ttf を empty loader にした結果 CSS に残る `url() format("woff")` は
  // 空 URL として @font-face 全体を無効化してしまう（KaTeX フォントが効かなくなる）ため除去する。
  const cssPath = path.join(outDir, "webview.css");
  if (fs.existsSync(cssPath)) {
    const css = fs.readFileSync(cssPath, "utf8");
    fs.writeFileSync(cssPath, css.replace(/,\s*url\(\)\s*format\([^)]*\)/g, ""));
  }

  fs.copyFileSync(path.join(__dirname, "index.html"), path.join(outDir, "index.html"));
  console.log("done ->", outDir);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
