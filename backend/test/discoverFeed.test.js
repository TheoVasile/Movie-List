const test = require("node:test");
const assert = require("node:assert");
const { buildDiscover } = require("../services/discoverFeed");
const { filmVector } = require("../services/tasteVector");

const film = (id, extra = {}) => ({ id, title: `Film ${id}`, release_date: "2001-01-01", poster_path: `/${id}.jpg`, vote_count: 500, vote_average: 7, genre_ids: [18], ...extra });
const toMovie = (result) => (result?.poster_path ? { id: result.id, title: result.title, release_date: result.release_date, genre_ids: result.genre_ids ?? [], vote_average: result.vote_average ?? 0, original_language: "en", media_type: "movie" } : null);

function fakeTmdb(answers) {
    const asked = [];
    return {
        asked,
        get: async (path, params) => {
            asked.push(`${path}?page=${params.page}`);
            return { results: answers[`${path}?page=${params.page}`] ?? answers[path] ?? [] };
        },
    };
}

test("films recommended from more seeds rank higher, with sources, scores and exclusions", async () => {
    const tmdb = fakeTmdb({
        "movie/1/recommendations?page=1": [film(10), film(11), film(12), film(13, { vote_count: 20 }), film(2)],
        "movie/2/recommendations?page=1": [film(11), film(14)],
        "trending/movie/week": [film(50), film(10)],
    });
    const items = await buildDiscover({
        seeds: [{ id: 1, weight: 1 }, { id: 2, weight: 1 }],
        exclude: new Set([12]),
        get: tmdb.get,
        toMovie,
    });
    const ids = items.map((item) => item.id);
    assert.strictEqual(ids[0], 11);
    // Excluded, below the vote floor, and the seeds themselves are left out
    assert.ok(!ids.includes(12) && !ids.includes(13) && !ids.includes(2));
    assert.deepStrictEqual(items.find((item) => item.id === 11).source, "seed");
    assert.strictEqual(items.find((item) => item.id === 50).source, "explore");
    assert.ok(items.every((item) => typeof item.score === "number"));
    assert.strictEqual(new Set(ids).size, ids.length);
    // The most weighted seeds also get their second page
    assert.ok(tmdb.asked.includes("movie/1/recommendations?page=2"));
});

test("with no seeds the taste vector's films seed it, and taste feeds use its genres", async () => {
    const taste = { likes: filmVector({ genres: [878] }), dislikes: new Map(), topGenres: [878], topKeywords: [], seeds: [{ id: 7, weight: 1 }] };
    const tmdb = fakeTmdb({
        "movie/7/recommendations?page=1": [film(70, { genre_ids: [99] })],
        "discover/movie?page=1": [film(80, { genre_ids: [878] })],
    });
    const items = await buildDiscover({ taste, get: tmdb.get, toMovie });
    assert.ok(tmdb.asked.includes("movie/7/recommendations?page=1"));
    assert.deepStrictEqual(items.map((item) => [item.id, item.source]).sort(), [[70, "seed"], [80, "taste"]]);
});

test("friends' picks go second with who recommended them; trending alone is labelled trending", async () => {
    const tmdb = fakeTmdb({ "trending/movie/week": [film(1), film(2), film(3)] });
    const friend = { ...toMovie(film(9)), recommended_by: { handle: "sam", display_name: "Sam" } };
    const items = await buildDiscover({ get: tmdb.get, toMovie, friends: [friend] });
    assert.deepStrictEqual(items.map((item) => item.id), [1, 9, 2, 3]);
    assert.deepStrictEqual(items[1].recommended_by, { handle: "sam", display_name: "Sam" });
    assert.strictEqual(items[1].source, "friend");
    assert.strictEqual(items[0].source, "trending");
});
