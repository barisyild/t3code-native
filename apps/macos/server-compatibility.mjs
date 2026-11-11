import { realpathSync } from "node:fs";
import * as NodeModule from "node:module";
import { dirname, join, relative } from "node:path";
import { pathToFileURL } from "node:url";

const entrypointPath = "apps/server/src/bin.ts";
const browserModule = "apps/server/src/preview/ServerBrowser.ts";
const contextModule = "packages/shared/src/composerContextReferences.ts";

const browserChanges = [
  [
    "    const size = tab.page.viewportSize();\n" +
      "    if (!size) return;\n" +
      "    if (tab.zoomFactor === 1) {\n" +
      "      await tab.page.setViewportSize(size);\n" +
      "      return;\n" +
      "    }\n" +
      "    const layout = (await layoutSize(tab))!;\n" +
      '    await tab.cdp.send("Emulation.setDeviceMetricsOverride", {',
    "    const layout = await layoutSize(tab);\n" +
      "    if (!layout) return;\n" +
      "    // Playwright caches viewport metrics independently of these CDP overrides.\n" +
      '    await tab.cdp.send("Emulation.setDeviceMetricsOverride", {',
  ],
  [
    "    await tab.page.setViewportSize({ width: size.width, height: size.height });\n" +
      "    await applyZoom(tab);\n" +
      "    await broadcastViewport(tab);",
    "    await tab.page.setViewportSize({ width: size.width, height: size.height });\n" +
      "    if (tab.zoomFactor !== 1) await applyZoom(tab);\n" +
      "    await broadcastViewport(tab);",
  ],
  [
    "        if (current?.width === width && current.height === height) return;\n" +
      "        await tab.page.setViewportSize({ width, height });\n" +
      "        await broadcastViewport(tab);",
    "        if (current?.width === width && current.height === height) return;\n" +
      "        await tab.page.setViewportSize({ width, height });\n" +
      "        if (tab.zoomFactor !== 1) await applyZoom(tab);\n" +
      "        await broadcastViewport(tab);",
  ],
];

const contextChanges = [
  [
    'import { replaceThreadLinks, threadLinkCandidates } from "./threadLinks.ts";',
    'import { expandAssistantCitationsForProvider } from "./assistantCitations.ts";\n' +
      'import { replaceThreadLinks, threadLinkCandidates } from "./threadLinks.ts";',
  ],
  [
    "  const occurrences = collectComposerContextReferences(input.text);\n" +
      "  if (occurrences.length === 0) return input.text;",
    "  const occurrences = collectComposerContextReferences(input.text);\n" +
      "  if (occurrences.length === 0) return expandAssistantCitationsForProvider(input.text);",
  ],
  [
    "  const body = replaceComposerContextReferences(input.text, (occurrence) =>\n" +
      "    formatComposerContextProviderMarker(\n" +
      "      recordsById.get(occurrence.contextId)?.kind ?? occurrence.kind,\n" +
      "      occurrence.label,\n" +
      "      occurrence.contextId,\n" +
      "    ),\n" +
      "  );",
    "  const body = expandAssistantCitationsForProvider(\n" +
      "    replaceComposerContextReferences(input.text, (occurrence) =>\n" +
      "      formatComposerContextProviderMarker(\n" +
      "        recordsById.get(occurrence.contextId)?.kind ?? occurrence.kind,\n" +
      "        occurrence.label,\n" +
      "        occurrence.contextId,\n" +
      "      ),\n" +
      "    ),\n" +
      "  );",
  ],
];

const changes = new Map([
  [browserModule, browserChanges],
  [contextModule, contextChanges],
]);

export function applyServerCompatibility(path, source) {
  const edits = changes.get(path);
  if (!edits) return source;
  // Apply a fix only when every original block still matches exactly once.
  if (!edits.every(([before]) => {
    const offset = source.indexOf(before);
    return offset !== -1 && source.indexOf(before, offset + 1) === -1;
  })) return source;
  return edits.reduce((current, [before, after]) => current.replace(before, () => after), source);
}

export function registerServerCompatibility(checkout) {
  if (typeof NodeModule.registerHooks !== "function") return undefined;
  const root = realpathSync(checkout);
  const urls = new Map([...changes.keys()].map((path) => [pathToFileURL(join(root, path)).href, path]));
  return NodeModule.registerHooks({
    load(url, context, nextLoad) {
      const loaded = nextLoad(url, context);
      const path = urls.get(url);
      if (path === undefined || loaded.source == null) return loaded;
      const source = typeof loaded.source === "string" ? loaded.source : Buffer.from(loaded.source).toString("utf8");
      const updated = applyServerCompatibility(path, source);
      return updated === source ? loaded : { ...loaded, source: updated };
    },
  });
}

if (process.argv[1]?.endsWith("/" + entrypointPath)) {
  const entrypoint = realpathSync(process.argv[1]);
  const checkout = dirname(dirname(dirname(dirname(entrypoint))));
  if (relative(checkout, entrypoint) === entrypointPath) registerServerCompatibility(checkout);
}
