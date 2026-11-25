const test = require("node:test");
const assert = require("node:assert");
const { placementHint, similarReactions } = require("../services/placementHint");

const film = (id, genre = 18) => ({ id, genres: [genre], keywords: [genre], directors: [genre], year: 1994, language: "en" });
const features = new Map([[1, film(1)], [2, film(2)], [3, film(3)], [4, film(4, 27)]]);
const hint = (reactions, extra = {}) => placementHint({ tmdb_id: 1, count: 24, reactions, features, ...extra });

test("a liked film starts higher up, one marked Not for Me lower down", () => {
    assert.deepStrictEqual(hint([{ tmdb_id: 1, reaction: "like" }]), { start_index: 7, count: 24, basis: "like" });
    assert.deepStrictEqual(hint([{ tmdb_id: 1, reaction: "dislike" }]), { start_index: 16, count: 24, basis: "dislike" });
    // Without the film's features the user's own reaction still counts
    assert.strictEqual(hint([{ tmdb_id: 1, reaction: "like" }], { features: new Map() }).start_index, 7);
});

test("reactions to similar films move it less, and never more than a quarter of the list", () => {
    const similar = hint([{ tmdb_id: 2, reaction: "like" }, { tmdb_id: 3, reaction: "like" }, { tmdb_id: 4, reaction: "dislike" }]);
    assert.strictEqual(similar.basis, "similar");
    assert.ok(similar.start_index > 7 && similar.start_index < 12);
    const many = new Map([...features, ...Array.from({ length: 50 }, (_, i) => [100 + i, film(100 + i)])]);
    const all = hint([{ tmdb_id: 1, reaction: "like" }, ...Array.from({ length: 50 }, (_, i) => ({ tmdb_id: 100 + i, reaction: "like" }))], { features: many, count: 101 });
    assert.strictEqual(all.start_index, 25);
});

test("no hint for short or unranked lists, or with nothing to go on", () => {
    const liked = [{ tmdb_id: 1, reaction: "like" }];
    const none = { start_index: null, basis: "none" };
    assert.deepStrictEqual(hint(liked, { count: 3 }), { ...none, count: 3 });
    assert.deepStrictEqual(hint(liked, { count: 0 }), { ...none, count: 0 });
    assert.deepStrictEqual(hint(liked, { ranked: false }), { ...none, count: 24 });
    assert.deepStrictEqual(hint([]), { ...none, count: 24 });
    assert.deepStrictEqual(hint([{ tmdb_id: 4, reaction: "dislike" }]), { ...none, count: 24 });
});

test("similar reactions leave out the film itself and unlike or unknown films", () => {
    const rows = [1, 2, 4, 99].map((tmdb_id) => ({ tmdb_id, reaction: "like" }));
    assert.deepStrictEqual(similarReactions(1, rows, features).map((row) => row.tmdb_id), [2]);
    assert.deepStrictEqual(similarReactions(99, rows, features), []);
});
