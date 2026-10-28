const test = require("node:test");
const assert = require("node:assert");
const ranker = require("../services/discoverRanker");
const { filmVector } = require("../services/tasteVector");

test("seeds parse with optional weights; old builds' plain ids weigh 1", () => {
    assert.deepStrictEqual(ranker.parseSeeds("550:1.0,680:0.6,-1399,abc,0,550:0.2,13:9,14:x"), [
        { id: 550, weight: 1 }, { id: 680, weight: 0.6 }, { id: -1399, weight: 1 }, { id: 13, weight: 2 }, { id: 14, weight: 1 },
    ]);
    assert.strictEqual(ranker.parseSeeds(Array.from({ length: 20 }, (_, i) => i + 1).join(",")).length, ranker.SEED_LIMIT);
    assert.deepStrictEqual(ranker.parseSeeds(undefined), []);
});

test("seed support adds weight x rank decay over every seed that recommends a film", () => {
    const support = ranker.seedSupport([
        { seed: { id: 1, weight: 1 }, results: [{ id: 10 }, { id: 11 }] },
        { seed: { id: 2, weight: 0.5 }, results: [{ id: 11 }, { id: 10 }, { id: 11 }] },
    ]);
    assert.ok(Math.abs(support.get(10).support - (1 + 0.5 / 1.05)) < 1e-9);
    assert.ok(Math.abs(support.get(11).support - (1 / 1.05 + 0.5)) < 1e-9);
    assert.deepStrictEqual(support.get(11).seeds, [1, 2]);
    // Recommended by two seeds beats recommended first by one
    const two = ranker.seedSupport([
        { seed: { id: 1, weight: 1 }, results: [{ id: 5 }, { id: 6 }] },
        { seed: { id: 2, weight: 1 }, results: [{ id: 7 }, { id: 6 }] },
    ]);
    assert.ok(two.get(6).support > two.get(5).support);
});

test("the score rises with support, taste and rating, and falls for avoided genres", () => {
    const base = { support: 1, maxSupport: 2, taste: 0.3, voteAverage: 7 };
    const score = ranker.combineScore(base);
    assert.ok(ranker.combineScore({ ...base, support: 2 }) > score);
    assert.ok(ranker.combineScore({ ...base, taste: 0.6 }) > score);
    assert.ok(ranker.combineScore({ ...base, voteAverage: 8 }) > score);
    assert.ok(ranker.combineScore({ ...base, avoided: true }) < score);
    assert.strictEqual(ranker.quality(3), 0);
    assert.strictEqual(ranker.quality(10), 1);
});

test("taste score subtracts similarity to disliked films", () => {
    const taste = { likes: filmVector({ genres: [878] }), dislikes: filmVector({ genres: [27] }) };
    assert.ok(Math.abs(ranker.tasteScore(filmVector({ genres: [878] }), taste) - 1) < 1e-9);
    assert.ok(Math.abs(ranker.tasteScore(filmVector({ genres: [27] }), taste) + ranker.DISLIKE_PENALTY) < 1e-9);
    assert.strictEqual(ranker.tasteScore(filmVector({ genres: [27] }), null), 0);
});

test("MMR keeps the best first and breaks up near-duplicates", () => {
    const item = (id, score, genres) => ({ id, score, vector: filmVector({ genres }) });
    const items = [item("a", 1, [1]), item("b", 0.95, [1]), item("c", 0.9, [1]), item("d", 0.8, [2]), item("e", 0.3, [3])];
    const order = ranker.mmr(items).map((x) => x.id);
    assert.strictEqual(order[0], "a");
    // d is less relevant but different, so it comes before the copies of a
    assert.strictEqual(order[1], "d");
    assert.deepStrictEqual(new Set(order), new Set(["a", "b", "c", "d", "e"]));
    // lambda 1 is plain relevance
    assert.deepStrictEqual(ranker.mmr(items, 1).map((x) => x.id), ["a", "b", "c", "d", "e"]);
    assert.deepStrictEqual(ranker.mmr([]), []);
});

test("explore picks take every 7th place, and friends go 2nd, 6th and 12th", () => {
    const ranked = Array.from({ length: 20 }, (_, i) => ({ id: i }));
    const explore = [{ id: "e1" }, { id: "e2" }, { id: "e3" }, { id: "e4" }];
    const blended = ranker.blendExplore(ranked, explore, 7, 0);
    assert.strictEqual(blended[6].id, "e1");
    assert.strictEqual(blended[13].id, "e2");
    assert.strictEqual(blended[20].id, "e3");
    assert.strictEqual(blended.length, 23);
    // A short list is topped up with what's left
    assert.strictEqual(ranker.blendExplore([{ id: 1 }], explore, 7, 40).length, 5);

    const placed = ranker.placeFriends(ranked, [{ id: "f1" }, { id: 3 }, { id: "f3" }, { id: "f4" }]);
    assert.deepStrictEqual([placed[1].id, placed[5].id, placed[11].id], ["f1", 3, "f3"]);
    assert.strictEqual(placed.filter((film) => film.id === 3).length, 1);
    assert.strictEqual(placed.length, 22);
    assert.deepStrictEqual(ranker.placeFriends([{ id: 1 }], [{ id: "f" }, { id: "g" }]).map((film) => film.id), [1, "f", "g"]);
});

test("re-ranking by taste nudges without overturning the order", () => {
    const films = Array.from({ length: 10 }, (_, i) => ({ id: i, genre_ids: i === 3 ? [878] : [99] }));
    const taste = { likes: filmVector({ genres: [878] }), dislikes: new Map() };
    const order = ranker.rerankByTaste(films, taste, (film) => filmVector({ genres: film.genre_ids })).map((film) => film.id);
    assert.strictEqual(order[0], 3);
    assert.deepStrictEqual(order.slice(1), [0, 1, 2, 4, 5, 6, 7, 8, 9]);
    assert.strictEqual(ranker.rerankByTaste(films, null, () => new Map()), films);
});
