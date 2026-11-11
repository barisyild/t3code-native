import * as NodeChildProcess from "node:child_process";
import * as NodeURL from "node:url";
import { test } from "vitest";

test("the AppKit shims work in the source server's Node loader", () => {
  // Vite's transformed imports do not exercise the hooks used by the local server.
  const checks = NodeURL.fileURLToPath(
    new URL("./server-compatibility.check.mjs", import.meta.url),
  );
  NodeChildProcess.execFileSync(process.execPath, ["--test", checks]);
});
