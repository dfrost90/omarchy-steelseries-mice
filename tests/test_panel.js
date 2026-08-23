// Tests for the panel's own validation of what the wrapper hands it.
//
// The functions are lifted out of BarWidget.qml rather than copied here, so
// this cannot drift from the code it claims to test. Only the leaf helpers and
// the two entry points are extracted; everything they touch is stubbed below.
//
// What is being tested is the boundary. `applyState` and `observed` are the
// only two places anything from outside becomes a property this panel paints,
// and the labels it paints into are Text.AutoText — so a value that arrives as
// markup instead of a number has to be dropped here or not at all.
//
// Run directly (`node tests/test_panel.js`) or through `tests/run`, which skips
// it when there is no JS engine to hand.

const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(
  path.join(__dirname, "..", "BarWidget.qml"), "utf8");

// One `readonly property int name: 123` from the QML, so the ceilings the
// tests assert against are the ceilings the panel actually uses.
function constant(name) {
  const m = source.match(new RegExp("readonly property int " + name + ":\\s*(\\d+)"));
  if (!m) throw new Error("BarWidget.qml has no int property " + name);
  return Number(m[1]);
}

// The body of one `function name(...) { ... }`, by brace matching.
function extract(name) {
  const start = source.indexOf("function " + name + "(");
  if (start < 0) throw new Error("BarWidget.qml has no function " + name);
  let depth = 0, seen = false;
  for (let i = start; i < source.length; i++) {
    if (source[i] === "{") { depth++; seen = true; }
    else if (source[i] === "}" && seen && --depth === 0)
      return source.slice(start, i + 1).replace("function " + name + "(", "function(");
  }
  throw new Error("unterminated function " + name);
}

// Everything the extracted code reaches for that is not itself under test.
let written = [];
const commitTimer = { stop() {} };
function run(args) { written.push(args); }
function presetCsv(list) { return list.join(","); }

const root = {
  maxPayloadBytes: constant("maxPayloadBytes"),
  maxListLength: constant("maxListLength"),
  plain: (v) => String(v === undefined || v === null ? "" : v).replace(/[<>&]/g, " "),
};
for (const name of ["whole", "wholeList"])
  root[name] = eval("(" + extract(name) + ")");
const applyState = eval("(" + extract("applyState") + ")");
const observed = eval("(" + extract("observed") + ")");

// A panel that has read one `get` and settled, which is the state every
// hostile input below arrives into.
function settled() {
  written = [];
  Object.assign(root, {
    presets: [800, 1600], selected: 1, activeDpi: 1600, polling: 1000,
    assumed: false, connected: true, haveHelper: true, lastError: "",
    appliedAt: "", deviceName: "SteelSeries Aerox 3", mode: "table",
    dpiMin: 200, dpiMax: 8500, dpiStep: 100, dpiValues: [],
    presetMin: 1, presetMax: 5, selectable: true, tracking: true,
    verified: true, pollingOptions: ["125", "250", "500", "1000"],
    pendingPresets: null, ready: false,
  });
}

let passed = 0, failed = 0;
function check(name, body) {
  settled();
  try { body(); passed++; console.log("  ok   " + name); }
  catch (e) { failed++; console.log("  FAIL " + name + "\n       " + e.message); }
}
function eq(actual, expected, what) {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) throw new Error((what ? what + ": " : "") + "expected " + b + ", got " + a);
}

const MARKUP = "<img src=http://example.invalid/x>";

// --- what counts as a number ----------------------------------------------

check("whole takes the whole non-negative range and nothing else", () => {
  eq([0, 1, 800, 18000].map(root.whole), [true, true, true, true], "accepted");
  eq(["800", 1.5, -1, NaN, Infinity, null, undefined, true, [800], {}].map(root.whole),
     [false, false, false, false, false, false, false, false, false, false], "refused");
});

check("wholeList refuses a list with anything but numbers in it", () => {
  eq(root.wholeList([800, MARKUP]), null, "markup");
  eq(root.wholeList([800, "1600"]), null, "digits as a string");
  eq(root.wholeList([]), null, "empty");
  eq(root.wholeList("800"), null, "not a list");
  eq(root.wholeList([800, 1200, 1600]), [800, 1200, 1600], "a real table");
});

check("wholeList refuses a list longer than anything a device holds", () => {
  const n = root.maxListLength;
  eq(root.wholeList(new Array(n).fill(800)).length, n, "at the ceiling");
  eq(root.wholeList(new Array(n + 1).fill(800)), null, "one past it");
  eq(root.wholeList(new Array(20000).fill(800)), null, "one chip each");
});

// --- the watch stream ------------------------------------------------------

check("a real report is taken and written back", () => {
  observed('{"selected":1,"presets":[800,1200,1600]}');
  eq(root.presets, [800, 1200, 1600], "presets");
  eq(root.selected, 1, "selected");
  eq(root.activeDpi, 1200, "activeDpi");
  eq(root.assumed, false, "assumed");
  eq(written, [["observe", "1", "--presets", "800,1200,1600"]], "written back");
});

check("a report carrying markup where a DPI belongs is dropped whole", () => {
  observed(JSON.stringify({ selected: 0, presets: [MARKUP] }));
  eq(root.presets, [800, 1600], "the table the panel already had");
  eq(written, [], "nothing written back");
});

check("a report selecting past the end of its own table is dropped", () => {
  observed('{"selected":9,"presets":[800,1200]}');
  eq(root.presets, [800, 1600]);
  eq(written, []);
});

check("a report whose selection is not a number is dropped", () => {
  observed('{"selected":"0","presets":[800]}');
  eq(root.presets, [800, 1600]);
  eq(written, []);
});

check("a report that is not JSON at all is dropped", () => {
  observed("{ not json");
  eq(root.presets, [800, 1600]);
  eq(written, []);
});

check("a report too large to be one is dropped unparsed", () => {
  observed('{"selected":0,"presets":[800],"pad":"' + "A".repeat(300000) + '"}');
  eq(root.presets, [800, 1600]);
  eq(written, []);
});

// --- the state the wrapper prints -----------------------------------------

const STATE = {
  presets: [800, 1600], selected: 1, activeDpi: 1600, polling: 500,
  assumed: false, connected: true, helper: true, error: "", appliedAt: "",
  name: "SteelSeries Aerox 3", mode: "table", dpiMin: 200, dpiMax: 8500,
  dpiStep: 100, dpiValues: [], presetMin: 1, presetMax: 5,
  selectable: true, tracking: true, verified: true,
  pollingOptions: [125, 500, 1000],
};

check("a real get is taken", () => {
  applyState(JSON.stringify(STATE));
  eq(root.presets, [800, 1600], "presets");
  eq(root.selected, 1, "selected");
  eq(root.activeDpi, 1600, "activeDpi");
  eq(root.polling, 500, "polling");
  eq(root.pollingOptions, ["125", "500", "1000"], "pollingOptions");
  eq(root.ready, true, "ready");
});

check("a table carrying markup leaves the panel unready rather than painting it", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, { presets: [MARKUP] })));
  eq(root.ready, false, "ready");
  eq(root.presets, [800, 1600], "the table the panel already had");
});

check("a twenty-thousand-preset table never reaches the panel's properties", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, {
    presets: new Array(20000).fill(800),
  })));
  eq(root.ready, false, "ready");
  eq(root.presets.length, 2, "the table the panel already had");
});

check("capability fields that are not numbers are ignored, not displayed", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, {
    dpiMin: MARKUP, dpiMax: MARKUP, dpiStep: MARKUP, presetMin: null,
    presetMax: "5", dpiValues: [MARKUP], pollingOptions: [MARKUP],
  })));
  eq(root.dpiMin, 200, "dpiMin");
  eq(root.dpiMax, 8500, "dpiMax");
  eq(root.dpiStep, 1, "dpiStep");
  eq(root.presetMin, 1, "presetMin");
  eq(root.presetMax, 5, "presetMax");
  eq(root.dpiValues, [], "dpiValues");
  eq(root.pollingOptions, ["125", "250", "500", "1000"], "pollingOptions");
});

check("a polling rate that is not a number leaves the old one alone", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, { polling: "<b>500</b>" })));
  eq(root.polling, 1000);
});

check("a selection past the end of the table falls back inside it", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, { selected: 7, activeDpi: null })));
  eq(root.selected, 0, "selected");
  eq(root.activeDpi, 800, "activeDpi");
});

check("a DPI list is taken when every value in it is a number", () => {
  applyState(JSON.stringify(Object.assign({}, STATE, { dpiValues: [400, 800, 1600, 3200] })));
  eq(root.dpiValues, [400, 800, 1600, 3200]);
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
