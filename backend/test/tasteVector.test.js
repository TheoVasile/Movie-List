const test = require("node:test");
const assert = require("node:assert");
const { weightFilms, tasteFromWeights, filmVector, cosine, featuresFromTmdb, featuresFor, RANK_DECAY } = require("../services/tasteVector");

const near = (a, b, epsilon = 1e-9) => assert.ok(Math.abs(a - b) < epsilon, `${a} != ${b}`);
const entry = (list_id, tmdb_id, position, extra = {}) => ({ list_id, list_name: "Favourites", is_ranked: true, tmdb_id, position, ...extra });

test("cosine is 1 for the same direction, 0 for nothing shared or nothing at all", () => {
    const a = new Map([["g:1", 1], ["g:2", 2]]);
    near(cosine(a, new Map([["g:1", 2], ["g:2", 4]])), 1);
    near(cosine(a, new Map([["g:3", 1]])), 0);
    near(cosine(a, new Map()), 0);
    near(cosine(new Map([["g:1", 1]]), new Map([["g:1", 1], ["g:2", 1]])), 1 / Math.sqrt(2));
});

test("a film's features of one kind share their kind's weight", () => {
    const one = filmVector({ keywords: [1] });
    const four = filmVector({ keywords: [1, 2, 3, 4] });
    const squared = (vector) => [...vector.values()].reduce((sum, value) => sum + value * value, 0);
    near(squared(one), squared(four));
    assert.deepStrictEqual([...filmVector({ genres: [18], year: 1994, language: "en" }).keys()].sort(), ["g:18", "l:en", "y:1990"]);
});

test("ranked lists decay exponentially and add up to min(size, k)", () => {
    const entries = Array.from({ length: 30 }, (_, i) => entry(1, 100 + i, i));
    const { likes } = weightFilms({ entries });
    near(likes.get(101) / likes.get(100), Math.exp(-1 / RANK_DECAY));
    near([...likes.values()].reduce((a, b) => a + b, 0), RANK_DECAY);
    const short = weightFilms({ entries: [entry(2, 1, 0), entry(2, 2, 1)] }).likes;
    near(short.get(1) + short.get(2), 2);
});

test("unranked lists and watchlists only count watched films, a little", () => {
    const entries = [
        entry(1, 10, 0, { is_ranked: false }),
        entry(1, 11, 1, { is_ranked: false }),
        entry(2, 12, 0, { list_name: "Watchlist" }),
    ];
    const { likes } = weightFilms({ entries, watched: new Set([10]) });
    // 0.1 for being watched in an unranked list, plus the watched boost
    near(likes.get(10), 0.1 + 0.2);
    assert.ok(!likes.has(11) && !likes.has(12));
});

test("rewatches and likes add weight, dislikes go to their own vector and aren't liked", () => {
    const { likes, dislikes } = weightFilms({
        entries: [entry(1, 1, 0), entry(1, 2, 1)],
        rewatches: new Map([[1, 5]]),
        reactions: [{ tmdb_id: 3, reaction: "like" }, { tmdb_id: 2, reaction: "dislike" }, { tmdb_id: 4, reaction: "skip" }],
    });
    assert.ok(likes.get(1) > 1.5);
    near(likes.get(3), 0.8);
    assert.ok(!likes.has(2) && !likes.has(4));
    assert.deepStrictEqual([...dislikes.keys()], [2]);
});

test("the taste vector leans towards liked features and names the top genres and seeds", () => {
    const features = new Map([
        [1, { id: 1, genres: [878], keywords: [9], directors: [525] }],
        [2, { id: 2, genres: [878, 28], directors: [525] }],
        [3, { id: 3, genres: [10749] }],
    ]);
    const taste = tasteFromWeights({ likes: new Map([[1, 1], [2, 0.5]]), dislikes: new Map([[3, 1]]) }, features);
    assert.strictEqual(taste.topGenres[0], 878);
    assert.deepStrictEqual(taste.seeds.map((seed) => seed.id), [1, 2]);
    near(taste.seeds[0].weight, 1);
    assert.ok(cosine(filmVector({ genres: [878], directors: [525] }), taste.likes) > cosine(filmVector({ genres: [10749] }), taste.likes));
    assert.ok(cosine(filmVector({ genres: [10749] }), taste.dislikes) > 0.9);
});

test("features come from TMDb details, keywords and credits, for films and shows", () => {
    const film = featuresFromTmdb(550, {
        title: "Fight Club", release_date: "1999-10-15", original_language: "en", vote_count: 30000, vote_average: 8.4,
        genres: [{ id: 18 }], keywords: { keywords: [{ id: 1 }, { id: 2 }] },
        credits: { crew: [{ id: 7467, job: "Director" }, { id: 1, job: "Writer" }], cast: Array.from({ length: 8 }, (_, i) => ({ id: i })) },
    });
    assert.deepStrictEqual([film.year, film.genres, film.keywords, film.directors, film.cast.length], [1999, [18], [1, 2], [7467], 5]);
    const show = featuresFromTmdb(-1399, { name: "GoT", first_air_date: "2011-04-17", genres: [{ id: 10765 }], keywords: { results: [{ id: 3 }] }, created_by: [{ id: 9 }] });
    assert.deepStrictEqual([show.title, show.year, show.genres, show.keywords, show.directors], ["GoT", 2011, [878, 14], [3], [9]]);
});

test("featuresFor skips films that fail or are unknown", async () => {
    const found = await featuresFor([1, 2, 3, 1], async (id) => {
        if (id === 2) throw new Error("TMDb down");
        return id === 3 ? null : { id };
    });
    assert.deepStrictEqual([...found.keys()], [1]);
});
