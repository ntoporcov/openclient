import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";
import { sanitizeSourceEndpoint } from "../src/source-endpoint.mjs";

test("server source metadata accepts only simple HTTP origins and effective ports", () => {
  assert.deepEqual(sanitizeSourceEndpoint("http://0.0.0.0:4096"), { protocol: "http", port: 4096 });
  assert.deepEqual(sanitizeSourceEndpoint(new URL("https://localhost")), { protocol: "https", port: 443 });
  for (const value of ["ftp://localhost:21", "http://user:pass@localhost:4096", "http://localhost:4096/v2", "http://localhost:4096?token=x", "http://localhost:99999", "not a url", undefined]) assert.equal(sanitizeSourceEndpoint(value), null);
});

test("browser suggestion uses the PWA hostname with IPv6-safe and conventional port formatting", async () => {
  const app = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const source = app.slice(app.indexOf("function suggestedBaseURL"), app.indexOf("\nconst tokenKey"));
  const context = {}; vm.createContext(context); vm.runInContext(`${source}; globalThis.suggest = suggestedBaseURL;`, context);
  const suggest = context.suggest;
  assert.equal(suggest("openclient.example", { protocol: "http", port: 4096 }), "http://openclient.example:4096");
  assert.equal(suggest("openclient.example", { protocol: "https", port: 443 }), "https://openclient.example");
  assert.equal(suggest("[fd00::1]", { protocol: "http", port: 80 }), "http://[fd00::1]");
  assert.equal(suggest("fd00::1", { protocol: "https", port: 8443 }), "https://[fd00::1]:8443");
  assert.equal(suggest("host/path", { protocol: "http", port: 4096 }), "");
  assert.equal(suggest("example.com", { protocol: "ftp", port: 21 }), "");
});
