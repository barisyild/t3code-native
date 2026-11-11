import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { applyServerCompatibility, registerServerCompatibility } from "./server-compatibility.mjs";

const checkout = new URL("../../", import.meta.url);
const hooks = registerServerCompatibility(fileURLToPath(checkout));
const { projectComposerContextForProvider } = await import(new URL(
  "packages/shared/src/composerContextReferences.ts", checkout,
));
const { serializeAssistantCitation } = await import(new URL("packages/shared/src/assistantCitations.ts", checkout));
hooks?.deregister();

test("provider input expands assistant quotes and preserves selected terminal context", () => {
  const quote = serializeAssistantCitation({
    version: 1,
    environmentId: "env",
    threadId: "thread",
    messageId: "reply",
    text: "Keep <this> wording.",
    comment: "Explain the claim",
    start: 0,
    end: 20,
    prefix: "",
    suffix: "",
  });
  assert.match(projectComposerContextForProvider({ text: quote, records: [] }), /\[assistant-quote-1\]\n\n<assistant_citations>/);
  const projected = projectComposerContextForProvider({
    text: quote + " [log](t3-context://v1/terminal/ctx_t)",
    records: [{
      version: 1,
      contextId: "ctx_t",
      kind: "terminal",
      label: "log",
      terminalId: "term-1",
      terminalLabel: "Terminal",
      lineStart: 4,
      lineEnd: 4,
      text: "Finished",
    }],
  });
  assert.ok(projected.includes("[assistant-quote-1] [Terminal: log; ref=ctx_t]"));
  assert.ok(projected.includes('"text": "Keep \\u003cthis\\u003e wording."'));
  assert.ok(projected.includes('"comment": "Explain the claim"'));
  assert.ok(projected.includes('<context kind="terminal" id="ctx_t">'));
  assert.ok(projected.includes("4 | Finished"));
  assert.ok(!projected.includes("t3-citation://"));
});

test("an incomplete upstream match is left intact", () => {
  const source = 'import { replaceThreadLinks, threadLinkCandidates } from "./threadLinks.ts";\n' +
    "export function projectComposerContextForProvider(input) { return input.text; }\n";
  assert.equal(applyServerCompatibility("packages/shared/src/composerContextReferences.ts", source), source);
  assert.equal(applyServerCompatibility("apps/desktop/src/main.ts", source), source);
});
