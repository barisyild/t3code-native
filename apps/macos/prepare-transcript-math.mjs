import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

const [checkoutPath, outputPath, moduleName = "math"] = process.argv.slice(2);
if (!checkoutPath || !outputPath) {
  throw new Error("Usage: node prepare-transcript-math.mjs CHECKOUT DESTINATION [math|mcp-app]");
}

const checkout = resolve(checkoutPath);
const output = resolve(outputPath);
const { build } = createRequire(join(checkout, "package.json"))("vite-plus");
const modules = {
  math: {
    entry: "packages/shared/src/markdownMath.ts",
    globalName: "T3MarkdownMath",
    fileName: "math-parser.js",
    licenseName: "MathParser-LICENSES.md",
  },
  "mcp-app": {
    entry: "packages/client-runtime/src/mcpApps/host.ts",
    globalName: "T3McpApp",
    fileName: "mcp-app-host.js",
    licenseName: "McpAppHost-LICENSES.md",
  },
};
const module = modules[moduleName];
if (!module) throw new Error("Unknown transcript module.");
const { licenseName } = module;

await build({
  root: checkout,
  configFile: false,
  envDir: false,
  publicDir: false,
  logLevel: "error",
  plugins: [
    {
      name: "javascriptcore-character-references",
      enforce: "pre",
      resolveId(id, importer) {
        // JavaScriptCore has no DOM for the browser entity decoder.
        if (id === "decode-named-character-reference" && importer) {
          return createRequire(importer).resolve(id);
        }
      },
    },
  ],
  build: {
    target: "safari17",
    outDir: output,
    emptyOutDir: false,
    copyPublicDir: false,
    reportCompressedSize: false,
    license: { fileName: licenseName },
    minify: true,
    lib: {
      entry: join(checkout, module.entry),
      name: module.globalName,
      formats: ["iife"],
      fileName: () => module.fileName,
    },
  },
});

const notice = await readFile(join(checkout, "LICENSE"), "utf8");
const dependencies = await readFile(join(output, licenseName), "utf8");
await writeFile(join(output, licenseName), notice + "\n" + dependencies);
