const highlighter = Promise.all([
  import("./highlights/highlighter.js"),
  import("./highlights/highlights.wasm.mjs"),
  import("./highlights/themes/github-dark-high-contrast.js"),
  import("./highlights/themes/github-light-high-contrast.js"),
]).then(([engine, wasm, darkTheme, lightTheme]) => {
  engine.init(new WebAssembly.Module(wasm.default));
  return { engine, darkTheme: darkTheme.default, lightTheme: lightTheme.default };
});

globalThis.highlightSyntax = async (source, language, dark) => {
  const { engine, darkTheme, lightTheme } = await highlighter;
  if (!engine.isSupportedLanguage(language)) return [];
  const { tokens, fg } = engine.codeToTokens(source, {
    lang: language,
    theme: dark ? darkTheme : lightTheme,
  });
  const spans = [];
  for (const line of tokens) {
    for (const token of line) {
      if (token.color === fg || !/^#[0-9a-f]{6}$/i.test(token.color)) continue;
      spans.push(
        token.offset,
        token.offset + token.content.length,
        Number.parseInt(token.color.slice(1), 16),
      );
    }
  }
  return spans;
};
