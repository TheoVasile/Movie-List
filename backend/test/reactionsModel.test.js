const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

// The model with a stand-in database that records each query
const queries = [];
let failWith = null;
let answer = null;
require.cache[path.resolve(__dirname, "../config/db.js")] = {
    id: "db", loaded: true,
    exports: {
        query: async (text, params) => {
            queries.push({ text, params });
            if (failWith && text.includes("discover_reactions")) throw Object.assign(new Error("missing"), { code: failWith });
            return answer?.(text, params) ?? { rows: [], rowCount: 0 };
        },
    },
};
require("axios").get = async () => { throw new Error("TMDb down"); };
const model = require("../models/reactionsModel");

test("skips keep a film out for 30 days, likes and dislikes for good", async () => {
    queries.length = 0;
    await model.fetchReactionMap("me");
    const { text, params } = queries[0];
    assert.match(text, /reaction <> 'skip' OR updated_at > CURRENT_TIMESTAMP - make_interval\(days => \$2\)/);
    assert.deepStrictEqual(params, ["me", 30]);
});

test("Show Skipped Again deletes only the user's skips", async () => {
    queries.length = 0;
    await model.deleteReactions("me", null, "skip");
    assert.match(queries[0].text, /WHERE user_id = \$1 AND reaction = \$2$/);
    assert.deepStrictEqual(queries[0].params, ["me", "skip"]);
});

test("friends' picks still come before the reactions table exists", async () => {
    queries.length = 0;
    failWith = "42P01";
    try {
        assert.deepStrictEqual(await model.fetchFriendPicks("me"), []);
        assert.strictEqual(queries.length, 2);
        assert.ok(!queries[1].text.includes("discover_reactions"));
    } finally {
        failWith = null;
    }
});

test("the same reaction again keeps its time, except a skip, and an older one changes nothing", async () => {
    queries.length = 0;
    answer = () => ({ rows: [{ tmdb_id: "550", reaction: "dislike", updated_at: "2026-11-25T10:00:00.000Z" }] });
    try {
        const saved = await model.upsertReaction("me", 550, "like", "discover", new Date("2026-11-25T09:00:00Z"));
        assert.deepStrictEqual(saved, { tmdb_id: 550, reaction: "dislike", updated_at: "2026-11-25T10:00:00.000Z" });
        const { text, params } = queries[0];
        assert.match(text, /reaction = EXCLUDED\.reaction AND EXCLUDED\.reaction <> 'skip'\s+THEN discover_reactions\.updated_at/);
        assert.match(text, /WHERE discover_reactions\.updated_at <= EXCLUDED\.updated_at/);
        assert.deepStrictEqual(params, ["me", 550, "like", "discover", "2026-11-25 09:00:00.000"]);
        await model.upsertReaction("me", 550, "like");
        assert.strictEqual(queries[1].params[4], null);
    } finally {
        answer = null;
    }
});

test("the history gives a page, where the next one starts, counts, and null for films it can't look up", async () => {
    queries.length = 0;
    const row = (tmdb_id, extra = {}) => ({ tmdb_id, reaction: "like", reacted_at: "t", at: `at-${tmdb_id}`, movie_id: null, ...extra });
    answer = (text) => {
        if (text.includes("GROUP BY reaction")) return { rows: [{ reaction: "like", count: 3 }] };
        if (text.includes("FROM discover_reactions r LEFT JOIN movies")) {
            return { rows: [row(550, { movie_id: 1, title: "Fight Club", release_date: "1999-10-15", overview: null, poster_path: "", original_language: "en", popularity: 1.2 }), row(2 ** 30), row(7)] };
        }
        return undefined;
    };
    try {
        const { items, next, counts } = await model.fetchHistory("me", "like", 2);
        assert.deepStrictEqual(items[0].movie, {
            id: 550, title: "Fight Club", release_date: "1999-10-15", overview: "", poster_path: null, original_language: "en", popularity: 1.2, genre_ids: null,
        });
        // Not an id a film can have, so it isn't looked up
        assert.strictEqual(items[1].movie, null);
        assert.strictEqual(items.length, 2);
        assert.deepStrictEqual(next, { at: `at-${2 ** 30}`, tmdb_id: 2 ** 30 });
        assert.deepStrictEqual(counts, { like: 3, dislike: 0 });
        assert.ok(queries.every(({ params }) => params[0] === "me"));
    } finally {
        answer = null;
    }
});

test("likes and dislikes are only read by their owner, for AI Picks and placement alike", async () => {
    queries.length = 0;
    await model.fetchNewestReactions("me");
    await model.fetchReactedFilms("me");
    assert.ok(queries.every(({ text, params }) => /WHERE user_id = \$1 AND reaction IN \('like', 'dislike'\)/.test(text) && params[0] === "me"));
});
