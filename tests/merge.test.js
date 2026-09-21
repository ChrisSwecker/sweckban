#!/usr/bin/env node
// Tests for the sync merge. Run with:  node tests/merge.test.js
//
// The app is one HTML file, so rather than restructure it these tests pull the block
// between the MERGE:BEGIN / MERGE:END markers out of sweckban.html and evaluate it.
// That block is deliberately free of DOM and app state. Testing the shipped source
// directly means the tests can't drift from what actually runs.

const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "..", "sweckban.html"), "utf8");
const block = html.match(/\/\/ MERGE:BEGIN[\s\S]*?\/\/ MERGE:END/);
if (!block) {
  console.error("Could not find the MERGE:BEGIN/END block in sweckban.html");
  process.exit(1);
}
const { mergeStates, pickNewer, mergeTombstones, sameData } = new Function(
  block[0] + "\nreturn { mergeStates, pickNewer, mergeTombstones, sameData };"
)();

// ---------- tiny harness ----------
let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); console.log("  ok   " + name); passed++; }
  catch (e) { console.log("  FAIL " + name + "\n         " + e.message.replace(/\n/g, "\n         ")); failed++; }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) throw new Error((msg ? msg + "\n" : "") + "got:      " + a + "\nexpected: " + b);
}
function ok(cond, msg) { if (!cond) throw new Error(msg || "expected truthy"); }

// ---------- builders ----------
const card = (id, title, ts) => ({ id, title, desc: "", labels: [], due: "", updatedAt: ts });
const list = (id, name, cards, ts) => ({ id, name, cards, updatedAt: ts });
const kanban = (id, name, lists, ts) => ({ id, name, type: "kanban", lists, updatedAt: ts });
const planner = (id, name, tasks, ts) => ({ id, name, type: "planner", tasks, updatedAt: ts });
const task = (id, title, ts) => ({ id, title, start: "2026-01-01", end: "2026-02-01", assignees: [], milestones: [], updatedAt: ts });
const person = (id, name, ts) => ({ id, name, handle: name.toLowerCase(), color: "#FF4D00", updatedAt: ts });
const state = (boards, extra) => Object.assign(
  { schema: 2, activeBoard: boards[0] && boards[0].id, boards, people: [], departments: [], tombstones: {} },
  extra || {}
);
const ids = arr => arr.map(x => x.id);
const findBoard = (s, id) => s.boards.find(b => b.id === id);
const findList = (s, bid, lid) => findBoard(s, bid).lists.find(l => l.id === lid);

console.log("\nmerge");

// ---------- the core case: neither side loses work ----------
test("keeps an edit each side made while the other was offline", () => {
  const base = t => state([kanban("b1", "Board", [list("l1", "To Do", [card("c1", "one", t)], t)], t)]);
  const mine = base(100);
  mine.boards[0].lists[0].cards.push(card("c2", "mine", 200));
  mine.boards[0].lists[0].updatedAt = 200;
  const theirs = base(100);
  theirs.boards[0].lists[0].cards.push(card("c3", "theirs", 210));
  theirs.boards[0].lists[0].updatedAt = 210;

  const m = mergeStates(mine, theirs);
  eq(ids(findList(m, "b1", "l1").cards).sort(), ["c1", "c2", "c3"], "both new cards survive");
});

test("newer edit to the same card wins", () => {
  const mk = (title, ts) => state([kanban("b1", "B", [list("l1", "L", [card("c1", title, ts)], ts)], ts)]);
  eq(findList(mergeStates(mk("old", 100), mk("new", 200)), "b1", "l1").cards[0].title, "new");
  eq(findList(mergeStates(mk("new", 200), mk("old", 100)), "b1", "l1").cards[0].title, "new",
     "same answer whichever side is 'mine'");
});

test("a board only the other device has is adopted", () => {
  const mine = state([kanban("b1", "Mine", [], 100)]);
  const theirs = state([kanban("b1", "Mine", [], 100), kanban("b2", "Theirs", [], 150)]);
  eq(ids(mergeStates(mine, theirs).boards).sort(), ["b1", "b2"]);
});

// ---------- deletes ----------
test("a delete beats an older edit on the other side", () => {
  const mine = state([kanban("b1", "B", [list("l1", "L", [card("c1", "still here", 100)], 100)], 100)]);
  const theirs = state([kanban("b1", "B", [list("l1", "L", [], 300)], 300)], { tombstones: { c1: 300 } });
  eq(ids(findList(mergeStates(mine, theirs), "b1", "l1").cards), [], "card stays deleted");
});

test("an edit after the delete brings the card back", () => {
  const mine = state([kanban("b1", "B", [list("l1", "L", [card("c1", "edited later", 400)], 400)], 400)]);
  const theirs = state([kanban("b1", "B", [list("l1", "L", [], 300)], 300)], { tombstones: { c1: 300 } });
  const cards = findList(mergeStates(mine, theirs), "b1", "l1").cards;
  eq(ids(cards), ["c1"], "resurrected because the edit is newer than the delete");
  eq(cards[0].title, "edited later");
});

test("deleting a list takes its cards with it", () => {
  const mine = state([kanban("b1", "B", [list("l1", "L", [card("c1", "x", 100)], 100)], 100)]);
  const theirs = state([kanban("b1", "B", [], 300)], { tombstones: { l1: 300, c1: 300 } });
  eq(ids(mergeStates(mine, theirs).boards[0].lists), []);
});

test("tombstones are unioned, keeping the later timestamp", () => {
  eq(mergeTombstones({ a: 100, b: 500 }, { a: 300, c: 700 }), { a: 300, b: 500, c: 700 });
});

// ---------- ordering and moves ----------
test("card order follows the list that was touched later", () => {
  const cards = [card("c1", "one", 50), card("c2", "two", 50), card("c3", "three", 50)];
  const mine = state([kanban("b1", "B", [list("l1", "L", [cards[0], cards[1], cards[2]], 100)], 100)]);
  const theirs = state([kanban("b1", "B", [list("l1", "L", [cards[2], cards[0], cards[1]], 500)], 500)]);
  eq(ids(findList(mergeStates(mine, theirs), "b1", "l1").cards), ["c3", "c1", "c2"],
     "the reorder made at t=500 wins");
});

test("a card moved between lists ends up in exactly one", () => {
  // Mine: c1 moved into Doing at t=500. Theirs: still in To Do, untouched since t=100.
  const mine = state([kanban("b1", "B", [
    list("l1", "To Do", [], 500),
    list("l2", "Doing", [card("c1", "moved", 500)], 500),
  ], 500)]);
  const theirs = state([kanban("b1", "B", [
    list("l1", "To Do", [card("c1", "moved", 100)], 100),
    list("l2", "Doing", [], 100),
  ], 100)]);
  const m = mergeStates(mine, theirs);
  eq(ids(findList(m, "b1", "l1").cards), [], "gone from the old list");
  eq(ids(findList(m, "b1", "l2").cards), ["c1"], "present in the new list, once");
});

// ---------- other entity types ----------
test("planner tasks merge like cards", () => {
  const mine = state([planner("p1", "Plan", [task("t1", "mine", 200)], 200)]);
  const theirs = state([planner("p1", "Plan", [task("t2", "theirs", 210)], 210)]);
  eq(ids(mergeStates(mine, theirs).boards[0].tasks).sort(), ["t1", "t2"]);
});

test("people merge, and a deleted person stays deleted", () => {
  const mine = state([kanban("b1", "B", [], 100)], { people: [person("p1", "Josh", 100), person("p2", "Nick", 100)] });
  const theirs = state([kanban("b1", "B", [], 100)], { people: [person("p1", "Josh", 100)], tombstones: { p2: 400 } });
  eq(ids(mergeStates(mine, theirs).people), ["p1"]);
});

test("schema takes the higher of the two", () => {
  const a = state([kanban("b1", "B", [], 1)]); a.schema = 2;
  const b = state([kanban("b1", "B", [], 1)]); b.schema = 3;
  eq(mergeStates(a, b).schema, 3);
});

// ---------- properties that make convergence possible ----------
const scenario = () => {
  const mine = state([
    kanban("b1", "Work", [
      list("l1", "To Do", [card("c1", "a", 100), card("c2", "local edit", 900)], 900),
      list("l2", "Done", [card("c4", "d", 100)], 100),
    ], 900),
    kanban("b3", "Only Mine", [], 800),
  ], { people: [person("p1", "Josh", 100)], tombstones: { c9: 500 } });
  const theirs = state([
    kanban("b1", "Work", [
      list("l1", "To Do", [card("c1", "a", 100), card("c3", "remote add", 950)], 950),
      list("l2", "Done", [], 700),
    ], 950),
    kanban("b2", "Only Theirs", [], 850),
  ], { people: [person("p1", "Josh", 100), person("p2", "Nick", 600)], tombstones: { c4: 700 } });
  return { mine, theirs };
};

test("merge is commutative (both devices reach the same data)", () => {
  const { mine, theirs } = scenario();
  ok(sameData(mergeStates(mine, theirs), mergeStates(theirs, mine)),
     "merge(a,b) and merge(b,a) disagree:\n" +
     JSON.stringify(mergeStates(mine, theirs)) + "\n" + JSON.stringify(mergeStates(theirs, mine)));
});

test("merge is idempotent (re-syncing changes nothing)", () => {
  const { mine, theirs } = scenario();
  const once = mergeStates(mine, theirs);
  ok(sameData(mergeStates(once, theirs), once), "merging the same file again moved the data");
  ok(sameData(mergeStates(once, once), once), "merging with itself moved the data");
});

test("nothing is silently dropped", () => {
  const { mine, theirs } = scenario();
  const merged = mergeStates(mine, theirs);
  const tombs = merged.tombstones;
  const collect = s => {
    const out = new Set();
    (s.boards || []).forEach(b => {
      out.add(b.id);
      (b.lists || []).forEach(l => { out.add(l.id); (l.cards || []).forEach(c => out.add(c.id)); });
      (b.tasks || []).forEach(t => out.add(t.id));
    });
    (s.people || []).forEach(p => out.add(p.id));
    return out;
  };
  const after = collect(merged);
  [mine, theirs].forEach(side => collect(side).forEach(id => {
    if (tombs[id] === undefined) ok(after.has(id), "lost entity " + id + " that was never deleted");
  }));
});

test("the write-back check ignores which board is on screen", () => {
  const a = state([kanban("b1", "B", [], 100), kanban("b2", "B2", [], 100)]);
  const b = state([kanban("b1", "B", [], 100), kanban("b2", "B2", [], 100)]);
  b.activeBoard = "b2";
  ok(sameData(a, b), "a different open board should not count as a data change");
});

test("tie on updatedAt resolves the same way regardless of argument order", () => {
  const x = { id: "c1", title: "aaa", updatedAt: 100 };
  const y = { id: "c1", title: "bbb", updatedAt: 100 };
  eq(pickNewer(x, y), pickNewer(y, x));
});

console.log("\n" + passed + " passed, " + failed + " failed\n");
process.exit(failed ? 1 : 0);
