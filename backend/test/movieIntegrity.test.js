const test = require("node:test");
const assert = require("node:assert");
const pool = require("../config/db");
const tmdbCache = require("../services/tmdbCache");
const { ensureMovie, appendMovieToList } = require("../models/movieModel");
const { visibleTo, notBlocked, setListFollowed } = require("../models/listModel");

// No test database: pool.query, pool.connect and TMDb are stood in for, answering by the SQL they're sent

const realQuery = pool.query, realConnect = pool.connect, realFetch = tmdbCache.fetchTmdb;
test.afterEach(() => {
    pool.query = realQuery;
    pool.connect = realConnect;
    tmdbCache.fetchTmdb = realFetch;
});

/// A movies table held in memory, as pool.query sees it. Returns the queries it was sent
function fakeMovies(rows = []) {
    const sent = [];
    pool.query = async (sql, params = []) => {
        sent.push(sql);
        if (/SELECT \* FROM movies WHERE tmdb_id/.test(sql)) return { rows: rows.filter((row) => row.tmdb_id === params[0]) };
        if (/INSERT INTO movies/.test(sql)) {
            if (rows.some((row) => row.tmdb_id === params[0])) return { rows: [] };
            const [tmdb_id, title, release_date, overview, poster_path, original_language, popularity, metadata_source] = params;
            const row = { id: rows.length + 1, tmdb_id, title, release_date, overview, poster_path, original_language, popularity, metadata_source };
            rows.push(row);
            return { rows: [row] };
        }
        // The TMDb cache's table: always a miss
        return { rows: [], rowCount: 0 };
    };
    return { rows, sent };
}

test("ensureMovie returns a film that's already saved without asking TMDb", async () => {
    const { rows } = fakeMovies([{ id: 7, tmdb_id: "771", title: "Home Alone", overview: "A boy...", metadata_source: "tmdb" }]);
    let fetches = 0;
    tmdbCache.fetchTmdb = async () => { fetches++; return {}; };
    const movie = await ensureMovie(771, { title: "Hacked title" });
    assert.strictEqual(movie.id, 7);
    assert.strictEqual(movie.title, "Home Alone");
    assert.strictEqual(fetches, 0);
    assert.strictEqual(rows.length, 1);
});

test("ensureMovie fetches a new film from TMDb once, saves TMDb's details and ignores the app's", async () => {
    const { rows } = fakeMovies();
    const paths = [];
    tmdbCache.fetchTmdb = async (path) => {
        paths.push(path);
        return { id: 900001, title: "Arrival", release_date: "2016-11-10", overview: "Linguist meets heptapods.",
            poster_path: "/x2FJsf1ElAgr63Y3PNPtJrcmpoe.jpg", original_language: "en", popularity: 40.5 };
    };
    const movie = await ensureMovie(900001, { title: "Not Arrival", overview: "spam", poster_path: "/evil.jpg" });
    assert.deepStrictEqual(paths, ["movie/900001"]);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(movie.title, "Arrival");
    assert.strictEqual(movie.overview, "Linguist meets heptapods.");
    assert.strictEqual(movie.poster_path, "/x2FJsf1ElAgr63Y3PNPtJrcmpoe.jpg");
    assert.strictEqual(movie.metadata_source, "tmdb");
    // Saved now, so asking again doesn't call TMDb
    await ensureMovie(900001);
    assert.strictEqual(paths.length, 1);
});

test("ensureMovie asks TMDb for a show (negative id) by its TV path and uses its name", async () => {
    fakeMovies();
    const paths = [];
    tmdbCache.fetchTmdb = async (path) => {
        paths.push(path);
        return { id: 900002, name: "Some Show", first_air_date: "2011-04-17", overview: "", poster_path: null };
    };
    const movie = await ensureMovie(-900002);
    assert.deepStrictEqual(paths, ["tv/900002"]);
    assert.strictEqual(movie.tmdb_id, "-900002");
    assert.strictEqual(movie.title, "Some Show");
    assert.strictEqual(movie.release_date, "2011-04-17");
    assert.strictEqual(movie.poster_path, "");
});

test("ensureMovie falls back to the app's copy, checked and cut to size, when TMDb is down", async () => {
    const { rows } = fakeMovies();
    tmdbCache.fetchTmdb = async () => { throw Object.assign(new Error("connect ETIMEDOUT"), { isAxiosError: true }); };
    const movie = await ensureMovie(900003, {
        title: `  ${"T".repeat(400)}  `,
        overview: "O".repeat(5000),
        poster_path: "/../../etc/passwd?x=1",
        release_date: "<script>",
        original_language: "en",
        popularity: "lots",
        extra: "ignored",
    });
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(movie.metadata_source, "client");
    assert.strictEqual(movie.title.length, 255);
    assert.strictEqual(movie.overview.length, 2000);
    assert.strictEqual(movie.poster_path, "");
    assert.strictEqual(movie.release_date, "");
    assert.strictEqual(movie.popularity, 0);
    assert.strictEqual(movie.original_language, "en");
});

test("ensureMovie keeps a valid poster path from the app's copy", async () => {
    fakeMovies();
    tmdbCache.fetchTmdb = async () => { throw new Error("TMDb down"); };
    const movie = await ensureMovie(900004, { title: "Heat", poster_path: "/abc_DEF-1.2.jpg", popularity: 30.1 });
    assert.strictEqual(movie.poster_path, "/abc_DEF-1.2.jpg");
    assert.strictEqual(movie.popularity, 30.1);
});

test("ensureMovie throws when TMDb is down and there's no title to fall back to, and saves nothing", async () => {
    const { rows } = fakeMovies();
    tmdbCache.fetchTmdb = async () => { throw new Error("TMDb down"); };
    await assert.rejects(ensureMovie(900005, { overview: "no title" }), /TMDb down/);
    await assert.rejects(ensureMovie(900006), /TMDb down/);
    assert.strictEqual(rows.length, 0);
});

test("ensureMovie returns null for a film TMDb doesn't have, and for ids that aren't ids", async () => {
    const { rows } = fakeMovies();
    tmdbCache.fetchTmdb = async () => { throw Object.assign(new Error("Not found"), { response: { status: 404 } }); };
    assert.strictEqual(await ensureMovie(900007, { title: "Made up" }), null);
    for (const id of [0, "abc", 1.5, null, undefined, {}, "1; DROP TABLE movies"]) {
        assert.strictEqual(await ensureMovie(id), null);
    }
    assert.strictEqual(rows.length, 0);
});

test("ensureMovie returns the other request's row when two save the same new film at once", async () => {
    // The row appears between this request's lookup and its insert
    const winner = { id: 42, tmdb_id: "900008", title: "Saved first", metadata_source: "tmdb" };
    let lookups = 0;
    pool.query = async (sql) => {
        if (/SELECT \* FROM movies WHERE tmdb_id/.test(sql)) return { rows: lookups++ === 0 ? [] : [winner] };
        if (/INSERT INTO movies/.test(sql)) return { rows: [] }; // ON CONFLICT DO NOTHING
        return { rows: [] };
    };
    tmdbCache.fetchTmdb = async () => ({ title: "Saved second" });
    assert.deepStrictEqual(await ensureMovie(900008), winner);
});

/// A list_movies table for one list, as a pooled client sees it
function fakeListClient(films) {
    const sent = [];
    const client = {
        released: false,
        release() { this.released = true; },
        async query(sql, params = []) {
            sent.push(sql.trim().split(/\s+/).slice(0, 3).join(" "));
            if (/INSERT INTO list_movies/.test(sql)) {
                if (films.some((film) => film.movie_id === params[1])) return { rows: [] };
                const rank = films.reduce((max, film) => Math.max(max, film.rank), 0) + 1;
                films.push({ movie_id: params[1], rank, added_by: params[2] });
                return { rows: [{ movie_id: params[1], rank }] };
            }
            if (/SELECT movie_id, rank FROM list_movies/.test(sql)) {
                return { rows: films.filter((film) => film.movie_id === params[1]).map(({ movie_id, rank }) => ({ movie_id, rank })) };
            }
            return { rows: [] };
        },
    };
    pool.connect = async () => client;
    return { client, sent };
}

test("appendMovieToList puts a film after the last one, and adding it again changes nothing", async () => {
    const films = [{ movie_id: 1, rank: 1 }, { movie_id: 2, rank: 2 }];
    const { client, sent } = fakeListClient(films);
    assert.deepStrictEqual(await appendMovieToList(3, 5, "uid"), { movie_id: 5, rank: 3, added: true });
    assert.deepStrictEqual(await appendMovieToList(3, 5, "uid"), { movie_id: 5, rank: 3, added: false });
    assert.deepStrictEqual(await appendMovieToList(3, 2, "uid"), { movie_id: 2, rank: 2, added: false });
    assert.strictEqual(films.length, 3);
    // The rank is worked out by the database, inside a transaction holding the list's lock
    assert.deepStrictEqual(sent.slice(0, 3), ["BEGIN", "SELECT 1 FROM", "INSERT INTO list_movies"]);
    assert.ok(client.released);
});

test("visibleTo hides the lists of someone either user has blocked, except the user's own", () => {
    const sql = visibleTo("$2").replace(/\s+/g, " ");
    assert.ok(sql.startsWith("(l.user_id = $2 OR ("), "The owner always sees their lists");
    assert.ok(sql.includes(`OR (${notBlocked("$2", "l.user_id")} AND (`), "Everyone else needs no block either way");
    assert.match(notBlocked("$2", "l.user_id"), /b\.blocker_id = \$2 AND b\.blocked_id = l\.user_id/);
    assert.match(notBlocked("$2", "l.user_id"), /b\.blocker_id = l\.user_id AND b\.blocked_id = \$2/);
});

test("Following a list goes through visibleTo, so a blocked user can't follow it", async () => {
    const sent = [];
    // The database finds no list the user can see (here: because of a block)
    pool.query = async (sql) => { sent.push(sql); return { rows: [] }; };
    assert.strictEqual(await setListFollowed("blocked-uid", 3, true), false);
    assert.strictEqual(sent.length, 1);
    assert.ok(sent[0].includes("FROM blocks b"));
});
