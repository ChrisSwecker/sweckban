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
const recur = html.match(/\/\/ RECUR:BEGIN[\s\S]*?\/\/ RECUR:END/);
if (!recur) {
  console.error("Could not find the RECUR:BEGIN/END block in sweckban.html");
  process.exit(1);
}
const { mergeStates, pickNewer, mergeTombstones, sameData, unifyBoard, labelsToCategories,
        addMonths, nextOccurrence } = new Function(
  block[0] + "\n" + recur[0] +
  "\nreturn { mergeStates, pickNewer, mergeTombstones, sameData, unifyBoard, labelsToCategories, addMonths, nextOccurrence };"
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
  { schema: 2, boards, people: [], departments: [], tombstones: {} },
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

// activeBoard moved to localStorage. A file written by an older build still carries the
// key, so both of these guard the mixed-version case rather than anything current.
test("the write-back check ignores which board is on screen", () => {
  const a = state([kanban("b1", "B", [], 100), kanban("b2", "B2", [], 100)]);
  const b = state([kanban("b1", "B", [], 100), kanban("b2", "B2", [], 100)]);
  b.activeBoard = "b2";
  ok(sameData(a, b), "a different open board should not count as a data change");
});

test("merging never puts the open board back into the file", () => {
  const mine = state([kanban("b1", "B", [], 100)]);
  const theirs = state([kanban("b1", "B", [], 100)]);
  mine.activeBoard = "b1";      // as an older build would have written it
  theirs.activeBoard = "b1";
  ok(!("activeBoard" in mergeStates(mine, theirs)),
     "activeBoard is device-local and must not survive a merge");
});

test("tie on updatedAt resolves the same way regardless of argument order", () => {
  const x = { id: "c1", title: "aaa", updatedAt: 100 };
  const y = { id: "c1", title: "bbb", updatedAt: 100 };
  eq(pickNewer(x, y), pickNewer(y, x));
});

// ---------- schema 3: Planner tasks become cards ----------
console.log("\nunify (planner tasks -> cards)");
const clone = o => JSON.parse(JSON.stringify(o));
const allCards = b => b.lists.flatMap(l => l.cards);
// What the app does after every merge: normalize() runs unifyBoard on each board
const settle = s => { s.boards.forEach(unifyBoard); return s; };

test("a Planner board becomes To Do / Doing / Done with its tasks in To Do", () => {
  const b = unifyBoard(planner("p1", "Plan", [task("t1", "one", 100), task("t2", "two", 100)], 100));
  eq(b.lists.map(l => l.name), ["To Do", "Doing", "Done"]);
  eq(ids(b.lists[0].cards), ["t1", "t2"]);
  ok(!("tasks" in b) && !("type" in b), "tasks and type should be gone");
  eq(b.defaultView, "timeline");
  eq(b.lists[0].cards[0].start, "2026-01-01");
  ok(!("labels" in b.lists[0].cards[0]), "labels are gone in schema 4; tasks shouldn't gain them");
});

test("a Kanban board is left alone apart from dropping its type", () => {
  const before = kanban("b1", "B", [list("l1", "To Do", [card("c1", "one", 100)], 100)], 100);
  const b = unifyBoard(clone(before));
  eq(b.lists, before.lists);
  ok(!("defaultView" in b), "a Kanban board should open on the board view");
});

test("legacy single assignee survives the move", () => {
  const t = task("t1", "one", 100); delete t.assignees; t.assignee = { type: "dept", id: "d1" };
  const b = unifyBoard(planner("p1", "Plan", [t], 100));
  eq(b.lists[0].cards[0].assignees, [{ type: "dept", id: "d1" }]);
  ok(!("assignee" in b.lists[0].cards[0]));
});

test("migrating twice changes nothing", () => {
  const once = unifyBoard(planner("p1", "Plan", [task("t1", "one", 100)], 100));
  const twice = unifyBoard(clone(once));
  eq(twice, once);
});

test("two devices migrating the same Planner independently merge without duplicates", () => {
  const p = () => state([planner("p1", "Plan", [task("t1", "one", 100), task("t2", "two", 100)], 100)]);
  const mine = settle(p()), theirs = settle(p());
  mine.boards[0].lists[0].cards[0].title = "edited here"; mine.boards[0].lists[0].cards[0].updatedAt = 300;
  const merged = settle(mergeStates(mine, theirs));
  eq(merged.boards[0].lists.length, 3, "lists should line up by id, not double up");
  eq(ids(allCards(merged.boards[0])).sort(), ["t1", "t2"]);
  eq(allCards(merged.boards[0]).find(c => c.id === "t1").title, "edited here");
});

test("an un-updated device's tasks merge into the migrated board, not beside it", () => {
  // This device migrated and moved t1 to Done; the other device is on an old build and
  // still writes a Planner, and has added t3 in the meantime.
  const mine = settle(state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]));
  const b = mine.boards[0];
  const [t1] = b.lists[0].cards.splice(0, 1);
  b.lists[2].cards.push(t1);
  b.lists[0].updatedAt = b.lists[2].updatedAt = 200;
  const theirs = state([planner("p1", "Plan", [task("t1", "one", 100), task("t3", "new on old build", 250)], 250)]);
  const merged = settle(mergeStates(mine, theirs));
  const m = merged.boards[0];
  eq(ids(m.lists[2].cards), ["t1"], "the move to Done must stick");
  eq(ids(m.lists[0].cards), ["t3"], "the new task arrives in the first column");
  ok(!("tasks" in m), "no tasks array left behind");
});

test("a newer task edit from an old build lands on the existing card", () => {
  const mine = settle(state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]));
  const newer = task("t1", "renamed on old build", 400); newer.end = "2026-03-01";
  const theirs = state([planner("p1", "Plan", [newer], 400)]);
  const merged = settle(mergeStates(mine, theirs));
  const c = allCards(merged.boards[0]);
  eq(c.length, 1);
  eq(c[0].title, "renamed on old build");
  eq(c[0].end, "2026-03-01");
});

test("an older task copy doesn't overwrite a newer card edit", () => {
  const mine = settle(state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]));
  const c = mine.boards[0].lists[0].cards[0]; c.title = "edited as a card"; c.updatedAt = 500;
  const theirs = state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]);
  const merged = settle(mergeStates(mine, theirs));
  eq(allCards(merged.boards[0])[0].title, "edited as a card");
});

test("a card deleted after migrating isn't brought back by an old build's task", () => {
  const mine = settle(state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]));
  mine.boards[0].lists[0].cards = [];
  mine.tombstones = { t1: 300 };
  const theirs = state([planner("p1", "Plan", [task("t1", "one", 100)], 100)]);
  const merged = settle(mergeStates(mine, theirs));
  eq(allCards(merged.boards[0]), []);
});

// ---------- schema 4: named categories replace colour labels ----------
console.log("\ncategories (labels -> categories)");
const labelled = (id, labels, ts) => Object.assign(card(id, id, ts), { labels });
const cardsOf = s => s.boards.flatMap(b => b.lists.flatMap(l => l.cards));

test("every label on a card becomes one of its categories", () => {
  const s = labelsToCategories(state([kanban("b1", "B", [list("l1", "L", [
    labelled("c1", ["#FF4D00", "#4DA3FF"], 100), labelled("c2", ["#ff4d00"], 100), labelled("c3", [], 100)], 100)], 100)]));
  eq(s.categories.map(c => [c.id, c.name, c.color]),
     [["cat-ff4d00", "Orange", "#FF4D00"], ["cat-4da3ff", "Blue", "#4DA3FF"]]);
  const [c1, c2, c3] = cardsOf(s);
  eq(c1.categories, ["cat-ff4d00", "cat-4da3ff"]);
  eq(c2.categories, ["cat-ff4d00"], "hex case shouldn't make a second category");
  ok(!("categories" in c3), "no labels, no categories key");
  ok(cardsOf(s).every(c => !("labels" in c)), "labels should be gone");
});

test("a colour outside the old palette still gets a category", () => {
  const s = labelsToCategories(state([kanban("b1", "B", [list("l1", "L", [labelled("c1", ["#123456"], 100)], 100)], 100)]));
  eq(s.categories[0].name, "Label #123456");
});

test("migrating categories twice changes nothing", () => {
  const once = labelsToCategories(state([kanban("b1", "B", [list("l1", "L", [labelled("c1", ["#FF4D00"], 100)], 100)], 100)]));
  eq(labelsToCategories(clone(once)), once);
});

test("two devices migrating labels independently end up with one set of categories", () => {
  const s = () => state([kanban("b1", "B", [list("l1", "L", [labelled("c1", ["#FF4D00"], 100), labelled("c2", ["#3FBF6F"], 100)], 100)], 100)]);
  const merged = labelsToCategories(mergeStates(labelsToCategories(s()), labelsToCategories(s())));
  eq(merged.categories.map(c => c.id).sort(), ["cat-3fbf6f", "cat-ff4d00"]);
});

test("categories merge, and a rename on one side wins if newer", () => {
  const mine = state([], { categories: [{ id: "k1", name: "Perf reviews", color: "#FF4D00", updatedAt: 300 }] });
  const theirs = state([], { categories: [{ id: "k1", name: "Old name", color: "#FF4D00", updatedAt: 100 },
                                          { id: "k2", name: "Tool changes", color: "#4DA3FF", updatedAt: 100 }] });
  const m = mergeStates(mine, theirs);
  eq(m.categories.map(c => c.name).sort(), ["Perf reviews", "Tool changes"]);
});

test("a deleted category isn't brought back by an old build's labels", () => {
  const s = state([kanban("b1", "B", [list("l1", "L", [labelled("c1", ["#FF4D00", "#4DA3FF"], 100)], 100)], 100)],
                  { tombstones: { "cat-ff4d00": 200 } });
  labelsToCategories(s);
  eq(s.categories.map(c => c.id), ["cat-4da3ff"]);
  eq(cardsOf(s)[0].categories, ["cat-4da3ff"]);
});

test("labels merged back in from an old build join the card's categories", () => {
  const c = Object.assign(card("c1", "one", 100), { categories: ["k1"], labels: ["#FF4D00"] });
  const s = labelsToCategories(state([kanban("b1", "B", [list("l1", "L", [c], 100)], 100)],
                                     { categories: [{ id: "k1", name: "Perf", color: "#3FBF6F" }] }));
  eq(cardsOf(s)[0].categories, ["k1", "cat-ff4d00"]);
  ok(!("labels" in cardsOf(s)[0]));
});

// ---------- repeating cards ----------
console.log("\nrepeat");

test("addMonths clamps to the end of the month and handles leap years", () => {
  eq(addMonths("2026-01-31", 1), "2026-02-28");
  eq(addMonths("2028-01-31", 1), "2028-02-29");
  eq(addMonths("2028-02-29", 12), "2029-02-28");
  eq(addMonths("2026-11-15", 3), "2027-02-15");
  eq(addMonths("2026-03-31", -1), "2026-02-28");
  eq(addMonths("", 12), "");
});

test("the next occurrence moves every date on and gets fresh ids", () => {
  let n = 0;
  const c = { id: "c1", title: "Review", desc: "d", categories: ["k1"], assignees: [{ type: "dept", id: "d1" }],
              repeat: "yearly", start: "2026-03-01", end: "2026-03-14", due: "2026-03-15",
              milestones: [{ id: "m1", label: "EOL", date: "2026-03-10" }], updatedAt: 100, archived: false };
  const next = nextOccurrence(c, () => "id" + (++n));
  eq([next.start, next.end, next.due, next.milestones[0].date],
     ["2027-03-01", "2027-03-14", "2027-03-15", "2027-03-10"]);
  eq(next.id, "id1");
  eq(next.milestones[0].id, "id2");
  eq([next.title, next.categories, next.repeat, next.assignees], ["Review", ["k1"], "yearly", [{ type: "dept", id: "d1" }]]);
  ok(!("updatedAt" in next) && !("archived" in next), "a fresh card, not a copy of the old one's state");
  eq(c.start, "2026-03-01", "the original is untouched");
});

test("quarterly and monthly step by 3 and 1 months; never repeating gives nothing", () => {
  eq(nextOccurrence({ repeat: "quarterly", due: "2026-11-30" }, () => "x").due, "2027-02-28");
  eq(nextOccurrence({ repeat: "monthly", due: "2026-12-05" }, () => "x").due, "2027-01-05");
  eq(nextOccurrence({ due: "2026-12-05" }, () => "x"), null);
});

console.log("\n" + passed + " passed, " + failed + " failed\n");
process.exit(failed ? 1 : 0);
