const test = require("node:test");
const assert = require("node:assert");
const express = require("express");
const { createReactionsRouter } = require("../routes/discoverReactionsRoutes");

// The routes with an in-memory model, signed in as "me"
async function withServer(run) {
    const rows = new Map();
    const changed = [];
    const asked = [];
    const savedFilms = [];
    const model = {
        REACTIONS: ["like", "dislike", "skip"],
        MAX_BULK: 2000,
        upsertReaction: async (user, id, reaction, source, at) => {
            rows.set(id, { tmdb_id: id, reaction, source, at, updated_at: "now" });
            return { tmdb_id: id, reaction, updated_at: "now" };
        },
        fetchHistory: async (user, reaction, limit, after) => {
            asked.push({ user, reaction, limit, after });
            const items = [...rows.values()].filter((row) => row.reaction === reaction)
                .map((row) => ({ tmdb_id: row.tmdb_id, reaction, reacted_at: "now", movie: null }));
            return { items, next: after ? null : { at: "2026-11-25 10:00:00.123456", tmdb_id: -1399 }, counts: { like: 1, dislike: 0 } };
        },
        upsertReactions: async (user, list) => {
            list.forEach((r) => rows.set(r.tmdb_id, { tmdb_id: r.tmdb_id, reaction: r.reaction, updated_at: r.at.toISOString() }));
            return list.length;
        },
        fetchReactions: async () => [...rows.values()],
        deleteReactions: async (user, id, reaction = null) => {
            let n = 0;
            for (const [key, row] of rows) {
                if ((id === null || key === id) && (reaction === null || row.reaction === reaction)) {
                    rows.delete(key);
                    n++;
                }
            }
            return n;
        },
    };
    const app = express();
    app.use(express.json({ limit: "5mb" }));
    app.use((req, res, next) => { req.user = { uid: "me" }; next(); });
    app.use("/discover/reactions", createReactionsRouter(model, (uid) => changed.push(uid), async (id) => {
        savedFilms.push(id);
        throw new Error("TMDb down");
    }));
    const server = app.listen(0);
    const base = `http://127.0.0.1:${server.address().port}/discover/reactions`;
    const call = async (method, path = "", body) => {
        const response = await fetch(base + path, { method, headers: { "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
        return { status: response.status, body: await response.json() };
    };
    try {
        await run({ call, rows, changed, asked, savedFilms });
    } finally {
        server.close();
    }
}

test("a reaction is saved, listed, undone and reset", () => withServer(async ({ call, rows, changed }) => {
    assert.deepStrictEqual(await call("POST", "", { tmdb_id: 550, reaction: "like", source: "discover" }), {
        status: 200, body: { ok: true, reaction: { tmdb_id: 550, reaction: "like", updated_at: "now" } },
    });
    await call("POST", "", { tmdb_id: -1399, reaction: "dislike" });
    assert.strictEqual(rows.get(550).source, "discover");
    const listed = await call("GET");
    assert.deepStrictEqual(listed.body.reactions.map((r) => [r.tmdb_id, r.reaction]), [[550, "like"], [-1399, "dislike"]]);
    assert.deepStrictEqual((await call("DELETE", "?tmdb_id=550")).body, { ok: true, deleted: 1 });
    assert.deepStrictEqual((await call("DELETE")).body, { ok: true, deleted: 1 });
    assert.strictEqual(rows.size, 0);
    assert.ok(changed.length >= 4 && changed.every((uid) => uid === "me"));
}));

test("bad reactions are turned away", () => withServer(async ({ call }) => {
    assert.strictEqual((await call("POST", "", { tmdb_id: 550, reaction: "love" })).status, 400);
    assert.strictEqual((await call("POST", "", { tmdb_id: "abc", reaction: "like" })).status, 400);
    assert.strictEqual((await call("POST", "", { tmdb_id: 0, reaction: "like" })).status, 400);
    assert.strictEqual((await call("DELETE", "?tmdb_id=x")).status, 400);
    assert.strictEqual((await call("POST", "/bulk", { reactions: "no" })).status, 400);
}));

test("bulk saves valid entries, caps at 2000 and doesn't trust future times", () => withServer(async ({ call, rows }) => {
    const result = await call("POST", "/bulk", { reactions: [
        { tmdb_id: 1, reaction: "like", at: "2026-01-01T00:00:00Z" },
        { tmdb_id: 2, reaction: "skip" },
        { tmdb_id: 3, reaction: "meh" },
        { tmdb_id: 4, reaction: "dislike", at: "2999-01-01T00:00:00Z" },
    ] });
    assert.deepStrictEqual(result, { status: 200, body: { ok: true, saved: 3 } });
    assert.strictEqual(rows.get(1).updated_at, "2026-01-01T00:00:00.000Z");
    assert.ok(new Date(rows.get(4).updated_at) <= new Date());
    const tooMany = Array.from({ length: 2001 }, (_, i) => ({ tmdb_id: i + 1, reaction: "skip" }));
    assert.strictEqual((await call("POST", "/bulk", { reactions: tooMany })).status, 400);
}));

test("Show Skipped Again deletes only skips", () => withServer(async ({ call, rows }) => {
    await call("POST", "", { tmdb_id: 1, reaction: "like" });
    await call("POST", "", { tmdb_id: 2, reaction: "skip" });
    await call("POST", "", { tmdb_id: -3, reaction: "skip" });
    await call("POST", "", { tmdb_id: 4, reaction: "dislike" });
    assert.deepStrictEqual((await call("DELETE", "?reaction=skip")).body, { ok: true, deleted: 2 });
    assert.deepStrictEqual([...rows.keys()].sort(), [1, 4]);
    assert.strictEqual((await call("DELETE", "?reaction=meh")).status, 400);
}));

test("a like or dislike's film is saved in the background, and a failure there doesn't matter", () => withServer(async ({ call, savedFilms }) => {
    assert.strictEqual((await call("POST", "", { tmdb_id: 1, reaction: "like" })).status, 200);
    await call("POST", "", { tmdb_id: 2, reaction: "skip" });
    await call("POST", "", { tmdb_id: 3, reaction: "dislike" });
    assert.deepStrictEqual(savedFilms, [1, 3]);
}));

test("a reaction's time is passed on, and can't be in the future", () => withServer(async ({ call, rows }) => {
    await call("POST", "", { tmdb_id: 1, reaction: "like", at: "2026-01-01T00:00:00Z" });
    await call("POST", "", { tmdb_id: 2, reaction: "like", at: "2999-01-01T00:00:00Z" });
    await call("POST", "", { tmdb_id: 3, reaction: "like", at: "yesterday" });
    assert.strictEqual(rows.get(1).at.toISOString(), "2026-01-01T00:00:00.000Z");
    assert.ok(rows.get(2).at <= new Date());
    assert.strictEqual(rows.get(3).at, null);
}));

test("the history is paged by a cursor and checks what it's asked", () => withServer(async ({ call, asked }) => {
    await call("POST", "", { tmdb_id: 550, reaction: "like" });
    const first = await call("GET", "/history?reaction=like");
    assert.strictEqual(first.status, 200);
    assert.deepStrictEqual(first.body.items, [{ tmdb_id: 550, reaction: "like", reacted_at: "now", movie: null }]);
    assert.deepStrictEqual(first.body.counts, { like: 1, dislike: 0 });
    assert.deepStrictEqual(asked[0], { user: "me", reaction: "like", limit: 40, after: null });
    const second = await call("GET", `/history?reaction=like&limit=50&cursor=${first.body.next_cursor}`);
    assert.deepStrictEqual(asked[1], { user: "me", reaction: "like", limit: 50, after: { at: "2026-11-25 10:00:00.123456", tmdb_id: -1399 } });
    assert.strictEqual(second.body.next_cursor, null);
    const cursor = (text) => Buffer.from(text).toString("base64url");
    for (const query of ["", "?reaction=skip", "?reaction=like&limit=0", "?reaction=like&limit=51", "?reaction=like&limit=x",
        "?reaction=like&cursor=abc", `?reaction=like&cursor=${cursor("2026-02-31 10:00:00|5")}`, `?reaction=like&cursor=${cursor("2026-01-01 10:00:00|x")}`,
        `?reaction=like&cursor=${cursor("2026-01-01 29:00:00|5")}`]) {
        assert.strictEqual((await call("GET", `/history${query}`)).status, 400, query);
    }
}));

test("a reaction from a search in Discover keeps its source", () => withServer(async ({ call, rows }) => {
    const saved = await call("POST", "", { tmdb_id: -1399, reaction: "like", source: "search" });
    assert.strictEqual(saved.status, 200);
    assert.strictEqual(rows.get(-1399).source, "search");
}));
