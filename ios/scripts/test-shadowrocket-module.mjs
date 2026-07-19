import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const repositoryRoot = new URL("../../", import.meta.url);
const settingsSource = await readFile(new URL("dist/wloc-settings.js", repositoryRoot), "utf8");
const wlocSource = await readFile(new URL("dist/wloc.js", repositoryRoot), "utf8");

function shadowrocketContext({ storage, requestURL, argument, exposeSettings = false }) {
  let finish;
  const completion = new Promise((resolve) => { finish = resolve; });
  const context = {
    console: { log() {} },
    $argument: argument,
    $request: { url: requestURL ?? "https://gs-loc.apple.com/clls/wloc" },
    $rocket: {},
    $persistentStore: {
      read(key) { return storage.has(key) ? storage.get(key) : null; },
      write(value, key) {
        storage.set(key, value);
        return true;
      },
    },
    $done(result) { finish(result); },
  };
  vm.createContext(context);

  let source = exposeSettings ? wlocSource : settingsSource;
  if (exposeSettings) {
    const marker = "}let ze;(async()=>";
    assert.equal(source.split(marker).length - 1, 1, "wloc.js settings resolver marker changed");
    source = source.replace(marker, "}globalThis.__wlocResolvedSettings=Pe();let ze;(async()=>");
  }
  vm.runInContext(source, context, { timeout: 2_000 });
  return { context, completion };
}

async function runSettingsRequest(storage, query) {
  const { completion } = shadowrocketContext({
    storage,
    requestURL: `https://gs-loc.apple.com/wloc-settings/save?${query}`,
  });
  const result = await Promise.race([
    completion,
    new Promise((_, reject) => setTimeout(() => reject(new Error("wloc-settings.js timed out")), 2_000)),
  ]);
  assert.equal(result.response.status, 200);
  return JSON.parse(result.response.body);
}

async function resolvedWlocSettings({ storedValue, argument }) {
  const storage = new Map();
  if (storedValue !== undefined) storage.set("wloc_settings", JSON.stringify(storedValue));
  const { context, completion } = shadowrocketContext({
    storage,
    argument,
    exposeSettings: true,
  });
  await completion;
  return context.__wlocResolvedSettings;
}

const storage = new Map();
assert.deepEqual(
  await runSettingsRequest(storage, "lon=0&lat=0&acc=25"),
  { success: true, longitude: 0, latitude: 0, accuracy: 25 },
  "the settings endpoint must accept the equator/prime-meridian intersection",
);
const queryZero = await runSettingsRequest(storage, "action=query");
assert.equal(queryZero.success, true);
assert.equal(queryZero.longitude, 0);
assert.equal(queryZero.latitude, 0);
assert.equal(queryZero.accuracy, 25);
assert.equal(typeof queryZero.updatedAt, "string");
assert.equal((await runSettingsRequest(storage, "lon=181&lat=0&acc=25")).success, false);
assert.equal((await runSettingsRequest(storage, "lon=0&lat=-91&acc=25")).success, false);
assert.equal((await runSettingsRequest(storage, "action=clear")).success, true);
assert.deepEqual(
  await runSettingsRequest(storage, "action=query"),
  { success: false, error: "无已保存的坐标" },
);

const moduleArgument = "longitude=113.94114&latitude=22.544577&accuracy=25&logLevel=info";
const persistedZero = await resolvedWlocSettings({
  storedValue: { longitude: 0, latitude: 0, accuracy: 25 },
  argument: moduleArgument,
});
assert.equal(persistedZero.longitude, 0);
assert.equal(persistedZero.latitude, 0);

const argumentZero = await resolvedWlocSettings({
  argument: "longitude=0&latitude=0&accuracy=25&logLevel=info",
});
assert.equal(argumentZero.longitude, 0);
assert.equal(argumentZero.latitude, 0);

console.log("Verified: Shadowrocket settings save/query/clear and zero-coordinate handling.");
