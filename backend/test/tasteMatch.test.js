const test = require("node:test");
const assert = require("node:assert");
const { computeTasteMatch, placesFrom, spearman, tierFor } = require("../services/tasteMatch");

// A ranked list as the rows the database gives: films with these TMDb ids, top first
const list = (listId, ids, year = "2001-01-01") =>
    ids.map((id, index) => ({ tmdb_id: String(id), title: `Film ${id}`, poster_path: `/${id}.jpg`, release_date: year,
                              list_id: listId, position: String(index + 1), list_size: String(ids.length) }));
const range = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const dramas = () => [18];

test("Spearman is 1 for the same order, -1 for the reverse, and handles ties", () => {
    assert.strictEqual(spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1);
    assert.strictEqual(spearman([1, 2, 3, 4], [40, 30, 20, 10]), -1);
    assert.ok(Math.abs(spearman([1, 1, 2, 3], [1, 2, 2, 3])) <= 1);
    assert.strictEqual(spearman([1, 1, 1], [1, 2, 3]), 0);
});

test("a film's place is its best across lists, from 0 at the top to 1 at the bottom", () => {
    const places = placesFrom([...list(1, [10, 11, 12, 13, 14]), ...list(2, [14, 99])]);
    assert.strictEqual(places.get(10).place, 0);
    assert.strictEqual(places.get(12).place, 0.5);
    assert.strictEqual(places.get(14).place, 0); // #1 of list 2 beats last of list 1
    assert.strictEqual(places.get(14).rank, 1);
    // A one-film list isn't a ranking
    assert.strictEqual(placesFrom(list(3, [50])).size, 0);
});

test("identical rankings are soulmates, reversed ones score low", () => {
    const ids = range(1, 12);
    const same = computeTasteMatch(placesFrom(list(1, ids)), placesFrom(list(2, ids)), dramas);
    assert.strictEqual(same.enough, true);
    assert.strictEqual(same.score, 100);
    assert.strictEqual(same.tier, "Cinematic soulmates");
    assert.strictEqual(same.shared_count, 12);
    assert.strictEqual(same.fight_over.length, 0);
    assert.deepStrictEqual(same.both_love.map((film) => film.tmdb_id), [1, 2, 3]);
    assert.strictEqual(same.top_genre, "Drama");

    const reversed = computeTasteMatch(placesFrom(list(1, ids)), placesFrom(list(2, [...ids].reverse())), dramas);
    assert.ok(reversed.score < 50, `reversed scored ${reversed.score}`);
    assert.strictEqual(reversed.tier, "Opposites attract");
    assert.strictEqual(reversed.both_love.length, 0);
    // The biggest gaps: each one's #1 is the other's last
    assert.strictEqual(reversed.fight_over.length, 2);
    const fight = reversed.fight_over[0];
    assert.ok([1, 12].includes(fight.tmdb_id));
    assert.strictEqual(Math.abs(fight.my_rank - fight.their_rank), 11);
});

test("the score is always a whole number from 0 to 100, and the same every time", () => {
    const mine = placesFrom(list(1, range(1, 20)));
    const theirs = placesFrom(list(2, [5, 3, 40, 41, 1, 42, 18, 43, 2, 44]));
    const genres = (id) => (id % 2 ? [18, 35] : [27]);
    const first = computeTasteMatch(mine, theirs, genres);
    const again = computeTasteMatch(mine, theirs, genres);
    assert.deepStrictEqual(first, again);
    assert.ok(Number.isInteger(first.score) && first.score >= 0 && first.score <= 100);
    assert.strictEqual(first.tier, tierFor(first.score));
});

test("with no films in common, genres and decades decide", () => {
    const mine = placesFrom(list(1, range(1, 10), "1975-05-01"));
    const alike = computeTasteMatch(mine, placesFrom(list(2, range(101, 110), "1977-01-01")), () => [27, 53]);
    assert.strictEqual(alike.enough, true);
    assert.strictEqual(alike.shared_count, 0);
    assert.ok(alike.score >= 90, `alike scored ${alike.score}`);
    assert.strictEqual(alike.breakdown.rank_agreement, null);

    const unalike = computeTasteMatch(mine, placesFrom(list(2, range(101, 110), "2020-01-01")),
        (id) => (id < 100 ? [27] : [10749]));
    assert.ok(unalike.score < 10, `unalike scored ${unalike.score}`);
    assert.strictEqual(unalike.top_genre, null);
});

test("not enough to go on says who needs to rank more", () => {
    const five = placesFrom(list(1, range(1, 5)));
    const four = placesFrom(list(2, range(1, 4)));
    assert.deepStrictEqual(computeTasteMatch(four, five), { enough: false, needs: "you" });
    assert.deepStrictEqual(computeTasteMatch(five, four), { enough: false, needs: "them" });
    // No genres and nothing in common
    assert.deepStrictEqual(computeTasteMatch(five, placesFrom(list(2, range(50, 60)))), { enough: false, needs: "overlap" });
});

test("tiers", () => {
    assert.strictEqual(tierFor(100), "Cinematic soulmates");
    assert.strictEqual(tierFor(90), "Cinematic soulmates");
    assert.strictEqual(tierFor(89), "Same wavelength");
    assert.strictEqual(tierFor(75), "Same wavelength");
    assert.strictEqual(tierFor(50), "Friendly rivals");
    assert.strictEqual(tierFor(49), "Opposites attract");
    assert.strictEqual(tierFor(0), "Opposites attract");
});

// The model, with pool.query and TMDb stood in for: answers by the SQL it's sent
const pool = require("../config/db");
const tmdbCache = require("../services/tmdbCache");
const { tasteMatch, SelfMatchError } = require("../models/tasteMatchModel");

function fakeDatabase({ users, films }) {
    const sent = [];
    pool.query = async (sql, params = []) => {
        sent.push({ sql, params });
        if (/FROM users u/.test(sql)) {
            return { rows: users.filter((user) => user.firebase_uid === params[0] || user.handle === params[1]) };
        }
        if (/FROM lists l/.test(sql)) return { rows: films[params[1]] ?? [] };
        return { rows: [], rowCount: 0 }; // the TMDb cache's table: always a miss
    };
    return sent;
}

test("tasteMatch reads the other person's lists through visibleTo as the viewer, and names both people", async (t) => {
    const realQuery = pool.query, realFetch = tmdbCache.fetchTmdb;
    t.after(() => { pool.query = realQuery; tmdbCache.fetchTmdb = realFetch; });
    const ids = range(900101, 900110);
    const sent = fakeDatabase({
        users: [{ firebase_uid: "me", handle: "theo", display_name: "Theo" }, { firebase_uid: "alex-uid", handle: "alex", display_name: "Alex" }],
        films: { me: list(1, ids), "alex-uid": list(2, ids) },
    });
    tmdbCache.fetchTmdb = async () => ({ genres: [{ id: 18 }] });

    const match = await tasteMatch("me", "alex");
    assert.strictEqual(match.me.handle, "theo");
    assert.strictEqual(match.them.handle, "alex");
    assert.strictEqual(match.score, 100);
    assert.strictEqual(match.top_genre, "Drama");

    const theirs = sent.find(({ sql, params }) => /FROM lists l/.test(sql) && params[1] === "alex-uid");
    assert.deepStrictEqual(theirs.params, ["me", "alex-uid"]);
    assert.match(theirs.sql, /l\.visibility = 'public'/);
    assert.match(theirs.sql, /FROM blocks b/);
    assert.match(theirs.sql, /l\.is_ranked/);
    // The person is looked up only if neither has blocked the other
    assert.match(sent[0].sql, /FROM blocks b/);
});

test("tasteMatch is null for someone missing or blocked, and refuses the user's own handle", async (t) => {
    const realQuery = pool.query;
    t.after(() => { pool.query = realQuery; });
    fakeDatabase({ users: [{ firebase_uid: "me", handle: "theo", display_name: "Theo" }], films: {} });
    assert.strictEqual(await tasteMatch("me", "nobody"), null);
    await assert.rejects(tasteMatch("me", "theo"), SelfMatchError);
});
