import * as NodeAssert from "node:assert/strict";
import * as NodeFS from "node:fs";
import * as NodeTest from "node:test";
import * as NodeURL from "node:url";

import { applyServerCompatibility, registerServerCompatibility } from "./server-compatibility.mjs";

const checkout = new URL("../../", import.meta.url);
const hooks = registerServerCompatibility(NodeURL.fileURLToPath(checkout));
const { projectComposerContextForProvider } = await import(
  new URL("packages/shared/src/composerContextReferences.ts", checkout)
);
const { serializeAssistantCitation } = await import(
  new URL("packages/shared/src/assistantCitations.ts", checkout)
);
const { ASSISTANT_CITATION_MAX_ID_LENGTH = 512 } = await import(
  new URL("packages/contracts/src/assistantCitations.ts", checkout)
);
hooks?.deregister();

NodeTest.test(
  "provider input expands assistant quotes and preserves selected terminal context",
  () => {
    const quote = serializeAssistantCitation({
      version: 1,
      environmentId: "env",
      threadId: "thread",
      messageId: "r".repeat(ASSISTANT_CITATION_MAX_ID_LENGTH),
      text: "Keep <this> wording.",
      comment: "Explain the claim",
      start: 0,
      end: 20,
      prefix: "",
      suffix: "",
    });
    NodeAssert.match(
      projectComposerContextForProvider({ text: quote, records: [] }),
      /\[assistant-quote-1\]\n\n<assistant_citations>/,
    );
    const projected = projectComposerContextForProvider({
      text: quote + " [log](t3-context://v1/terminal/ctx_t)",
      records: [
        {
          version: 1,
          contextId: "ctx_t",
          kind: "terminal",
          label: "log",
          terminalId: "term-1",
          terminalLabel: "Terminal",
          lineStart: 4,
          lineEnd: 4,
          text: "Finished",
        },
      ],
    });
    NodeAssert.ok(projected.includes("[assistant-quote-1] [Terminal: log; ref=ctx_t]"));
    NodeAssert.ok(projected.includes('"text": "Keep \\u003cthis\\u003e wording."'));
    NodeAssert.ok(projected.includes('"comment": "Explain the claim"'));
    NodeAssert.ok(projected.includes('<context kind="terminal" id="ctx_t">'));
    NodeAssert.ok(projected.includes("4 | Finished"));
    NodeAssert.ok(!projected.includes("t3-citation://"));
  },
);

NodeTest.test("an incomplete upstream match is left intact", () => {
  const source =
    'import { replaceThreadLinks, threadLinkCandidates } from "./threadLinks.ts";\n' +
    "export function projectComposerContextForProvider(input) { return input.text; }\n";
  NodeAssert.equal(
    applyServerCompatibility("packages/shared/src/composerContextReferences.ts", source),
    source,
  );
  NodeAssert.equal(applyServerCompatibility("apps/desktop/src/main.ts", source), source);
});

NodeTest.test("the browser zoom shim still matches the checkout", () => {
  const path = "apps/server/src/preview/ServerBrowser.ts";
  const source = NodeFS.readFileSync(new URL(path, checkout), "utf8");
  NodeAssert.ok(
    applyServerCompatibility(path, source).includes(
      "// Playwright caches viewport metrics independently of these CDP overrides.",
    ),
    "Review the browser zoom shim after the upstream change. Remove it if T3 now preserves zoom.",
  );
});

NodeTest.test("the browser viewer can attach while the first still is captured", () => {
  const path = "apps/server/src/preview/ServerBrowser.ts";
  const source = NodeFS.readFileSync(new URL(path, checkout), "utf8");
  NodeAssert.ok(
    applyServerCompatibility(path, source).includes(
      "if (!screencastStarted) yield* Effect.forkScoped(Effect.promise(pushStill));",
    ),
    "Review the initial still capture if the viewer no longer attaches independently.",
  );
  const viewerOnly = "    if (!screencastStarted) yield* Effect.promise(pushStill);\n    return {";
  NodeAssert.equal(
    applyServerCompatibility(path, viewerOnly),
    "    if (!screencastStarted) yield* Effect.forkScoped(Effect.promise(pushStill));\n    return {",
  );
});
