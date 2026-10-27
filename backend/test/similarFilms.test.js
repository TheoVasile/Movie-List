const test = require("node:test");
const assert = require("node:assert");
const { similarFilms } = require("../services/similarFilms");

// A TMDb result with what the app needs to show it
const result = (id, extra = {}) => ({ id, title: `Film ${id}`, release_date: "2001-01-01", poster_path: `/${id}.jpg`, ...extra });
// Keeps films with a poster, like the app's mapper
const toMovie = (movie) => (movie.poster_path ? { id: movie.id, title: movie.title } : null);

// Answers TMDb paths from a table, remembering what was asked
function fakeTmdb(pages) {
    const asked = [];
    const get = async (path, params) => {
        const key = `${path}?page=${params.page}`;
        asked.push(key);
        if (!(key in pages)) {
            const error = new Error("Not found");
            error.response = { status: 404 };
            throw error;
        }
        return { results: pages[key] };
    };
    return { get, asked };
}

test("recommendations come first, without the film itself, listed films or duplicates", async () => {
    const recommendations = Array.from({ length: 20 }, (_, i) => result(100 + i));
    const tmdb = fakeTmdb({
        "movie/771/recommendations?page=1": [result(771), ...recommendations.slice(0, 10)],
        "movie/771/recommendations?page=2": [result(100), ...recommendations.slice(10), result(200)],
    });
    const films = await similarFilms(771, { get: tmdb.get, listed: new Set([101, 102]), toMovie });
    const ids = films.map((film) => film.id);
    assert.strictEqual(ids[0], 100);
    assert.ok(!ids.includes(771));
    assert.ok(!ids.includes(101) && !ids.includes(102));
    assert.strictEqual(new Set(ids).size, ids.length);
    assert.strictEqual(ids.length, 19);
    // 19 new films isn't quite enough, so similar titles were asked for too (and TMDb had none)
    assert.ok(tmdb.asked.includes("movie/771/similar?page=1"));
});

test("similar titles top up thin recommendations, and films the app can't show are dropped", async () => {
    const tmdb = fakeTmdb({
        "movie/5/recommendations?page=1": [result(1), result(2, { poster_path: null })],
        "movie/5/similar?page=1": [result(1), result(3)],
    });
    const films = await similarFilms(5, { get: tmdb.get, toMovie });
    assert.deepStrictEqual(films.map((film) => film.id), [1, 3]);
});

test("a show's recommendations are shows, with negative ids", async () => {
    const tmdb = fakeTmdb({
        "tv/1399/recommendations?page=1": [{ id: 1400, name: "Show", first_air_date: "2011-04-17", poster_path: "/s.jpg" }],
    });
    const films = await similarFilms(-1399, { get: tmdb.get, toMovie });
    assert.deepStrictEqual(films, [{ id: -1400, title: "Show" }]);
});

test("failures other than a missing film are passed on", async () => {
    const get = async () => {
        const error = new Error("TMDb is down");
        error.response = { status: 503 };
        throw error;
    };
    await assert.rejects(similarFilms(771, { get, toMovie }), /TMDb is down/);
});
