const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

// The model with a stand-in database that records each query
const queries = [];
let failWith = null;
require.cache[path.resolve(__dirname, "../config/db.js")] = {
    id: "db", loaded: true,
    exports: {
        query: async (text, params) => {
            queries.push({ text, params });
            if (failWith && text.includes("discover_reactions")) throw Object.assign(new Error("missing"), { code: failWith });
            return { rows: [], rowCount: 0 };
        },
    },
};
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
