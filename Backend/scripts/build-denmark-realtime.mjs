import { build } from "esbuild";
import { builtinModules } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const backend = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = process.argv[2];
if (!output) throw new Error("Provide the output ES module path");

// Rhea is CommonJS. Static wrappers keep its built-in imports compatible with
// Workerd without a dynamic require shim or browser DOM/crypto replacements.
await build({
  entryPoints: [resolve(backend, "src/cloudflare/denmark-realtime-worker.ts")],
  outfile: resolve(output), bundle: true, platform: "node", format: "esm", target: "es2022",
  external: ["cloudflare:workers"],
  alias: { kerberos: resolve(backend, "src/providers/denmark-servicebus-no-kerberos.ts") },
  plugins: [{ name: "static-node-interop", setup(builder) {
    builder.onResolve({ filter: /^(node:)?[a-z][a-z_/-]*$/ }, args => {
      const name = args.path.replace(/^node:/, "");
      if (!builtinModules.includes(name)) return;
      return args.namespace === "node-interop"
        ? { path: `node:${name}`, external: true }
        : { path: name, namespace: "node-interop" };
    });
    builder.onLoad({ filter: /.*/, namespace: "node-interop" }, args => ({
      contents: `import * as builtin from 'node:${args.path}'; module.exports = builtin.default ?? builtin;`, loader: "js",
    }));
  } }],
  logLevel: "warning",
});
console.log(`Built Denmark realtime ES module: ${resolve(output)}`);
