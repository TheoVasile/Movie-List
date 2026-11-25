const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const express = require("express");

// Stand-ins for the database, TMDb, Firebase and the AI, so the real route runs without any of them. They have to be in
// place before anything that uses them is loaded, or that keeps the real ones
process.env.ANTHROPIC_API_KEY = "test";
// Nowhere to connect to, should anything get past the stand-in database
process.env.DATABASE_URL = "postgres://localhost:1/none";
const stub = (id, exports) => { require.cache[require.resolve(id)] = { id, loaded: true, exports }; };
const prompts = [];
let aiPicks = [];
stub("@anthropic-ai/sdk", class {
    messages = {
        create: async (request) => {
            prompts.push(JSON.stringify(request));
            return { usage: {}, stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ recommendations: aiPicks }) }] };
        },
    };
});
stub("../config/firebase", {});
const queries = [];
let state;
stub("../config/db", { query: async (text, params = []) => {
    queries.push(text);
    return answer(text, params);
} });
const axios = require("axios");
axios.get = async (url, { params }) => ({ data: tmdb(new URL(url).pathname.replace("/3/", ""), params) });

const ranker = require("../services/discoverRanker");
const { filmVector } = require("../services/tasteVector");

const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const result = (id, extra = {}) => ({
    id, title: `Film ${LETTERS[id % 26]}${id}`, release_date: "2001-01-01", poster_path: `/${id}.jpg`, vote_count: 500, vote_average: 7, genre_ids: [18], overview: "", original_language: "en", popularity: 1, ...extra,
});

function tmdb(route, params) {
    const recommendations = route.match(/^movie\/(\d+)\/recommendations$/);
    if (recommendations) return { results: state.recommendations[recommendations[1]] ?? [] };
    if (route === "search/movie") return { results: [...Array(400).keys()].map((id) => result(id)).filter((film) => film.title === params.query) };
    const film = route.match(/^movie\/(\d+)$/);
    if (film) return { id: Number(film[1]), title: `Film ${film[1]}`, release_date: "2001-01-01", genres: state.genres?.[film[1]] ?? [{ id: 18 }], original_language: "en" };
    return { results: [] };
}

function answer(text, params) {
    const rows = (list) => ({ rows: list, rowCount: list.length });
    if (/username AS name, ai_allowed FROM users WHERE firebase_uid = \$1/.test(text)) return rows([{ firebase_uid: "me", name: "Me", ai_allowed: true }]);
    if (/FROM watch_groups g\s+JOIN users u/.test(text)) return rows([{ firebase_uid: "me", handle: "me", ai_allowed: true }, { firebase_uid: "sam", handle: "sam", ai_allowed: state.samAllowsAI ?? true }]);
    if (/SELECT user_id, tmdb_id, reaction FROM discover_reactions/.test(text)) return rows(state.reactions);
    if (/SELECT m\.tmdb_id, m\.title\s+FROM list_movies/.test(text)) return rows(state.top[params[0]] ?? []);
    if (/INSERT INTO group_picks/.test(text)) state.saved.push(params[1]);
    if (/INSERT INTO ai_usage/.test(text)) return { rows: [{ count: 1 }], rowCount: 1 };
    return rows([]);
}

async function movieNight(body, setup) {
    state = { reactions: [], top: {}, recommendations: {}, saved: [], ...setup };
    queries.length = 0;
    prompts.length = 0;
    const app = express();
    app.use(express.json());
    app.use((req, res, next) => { req.user = { uid: "me" }; next(); });
    app.use("/movies", require("../routes/movieRoutes"));
    const server = app.listen(0);
    try {
        const response = await fetch(`http://127.0.0.1:${server.address().port}/movies/movie-night`, {
            method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ group_id: 3, ...body }),
        });
        return { status: response.status, body: await response.json() };
    } finally {
        server.close();
    }
}

const reaction = (user_id, tmdb_id, kind) => ({ user_id, tmdb_id, reaction: kind });

// Each test seeds from different films, since TMDb answers are cached. 2 favourites each, 8 recommendations from each
function setup(base) {
    const favourite = (n) => ({ tmdb_id: base + n, title: `Favourite ${base + n}` });
    const recommendations = {};
    for (let n = 0; n < 4; n++) recommendations[base + n] = Array.from({ length: 2 }, (_, i) => result(base + 10 + n * 2 + i));
    return { top: { me: [favourite(0), favourite(1)], sam: [favourite(2), favourite(3)] }, recommendations };
}

test("a film someone liked moves up, but not past one more people's favourites lead to", async () => {
    const base = setup(100);
    base.recommendations[102].push(result(110));
    const plain = await movieNight({ mode: "classic" }, base);
    assert.strictEqual(plain.body[0].id, 110);
    const liked = await movieNight({ mode: "classic" }, { ...base, reactions: [reaction("sam", 117, "like")] });
    assert.deepStrictEqual(liked.body.slice(0, 2).map((film) => film.id), [110, 117]);
    assert.notStrictEqual(plain.body[1].id, 117);
});

test("a film anyone marked Not for Me is left out while there are enough others, and comes last otherwise", async () => {
    const base = setup(130);
    const reactions = [reaction("sam", 140, "dislike")];
    const enough = await movieNight({ mode: "classic", count: 5 }, { ...base, reactions });
    assert.strictEqual(enough.body.length, 5);
    assert.ok(!enough.body.some((film) => film.id === 140));
    const few = await movieNight({ mode: "classic", count: 8 }, { ...base, reactions });
    assert.strictEqual(few.body.length, 8);
    assert.strictEqual(few.body[7].id, 140);
});

test("likes lead to picks when favourites don't, and nothing says whose they were", async () => {
    const setupLikes = { recommendations: { 170: [result(171), result(172)] }, reactions: [reaction("sam", 170, "like")] };
    const { body } = await movieNight({ mode: "classic" }, setupLikes);
    assert.deepStrictEqual(body.map((film) => film.id), [171, 172]);
    assert.ok(body.every((film) => film.reason === "Picked for your group"));
});

test("picks have the same fields with reactions as without, and reasons never name a reacted film", async () => {
    const base = setup(200);
    const fields = (films) => [...new Set(films.flatMap((film) => Object.keys(film)))].sort();
    const plain = await movieNight({ mode: "classic" }, base);
    const reacted = await movieNight({ mode: "classic" }, { ...base, reactions: [reaction("sam", 210, "like"), reaction("me", 212, "dislike"), reaction("sam", 229, "like")] });
    assert.deepStrictEqual(fields(reacted.body), fields(plain.body));
    assert.ok(!fields(plain.body).includes("base"));
    assert.ok(reacted.body.every((film) => /Favourite/.test(film.reason)));
});

test("the AI isn't told about reactions, which re-order its picks afterwards; consent still comes first", async () => {
    aiPicks = [240, 241, 242, 243, 244, 245].map((id) => ({ title: result(id).title, year: 2001, reason: "Because" }));
    const reactions = [reaction("sam", 242, "like"), reaction("me", 240, "dislike"), reaction("sam", 259, "like")];
    const plain = await movieNight({ mode: "ai", count: 4 }, {});
    const plainPrompt = prompts[0];
    assert.deepStrictEqual(plain.body.map((film) => film.id), [240, 241, 242, 243]);
    const reacted = await movieNight({ mode: "ai", count: 4 }, { reactions });
    assert.deepStrictEqual(reacted.body.map((film) => film.id), [242, 241, 243, 244]);
    assert.deepStrictEqual(Object.keys(reacted.body[0]).sort(), Object.keys(plain.body[0]).sort());
    // The only difference is how many films are asked for
    assert.strictEqual(prompts[0].replace(/Recommend \d+ films/, ""), plainPrompt.replace(/Recommend \d+ films/, ""));

    const off = await movieNight({ mode: "ai" }, { reactions, samAllowsAI: false });
    assert.strictEqual(off.status, 403);
    assert.strictEqual(prompts.length, 0);
    assert.ok(!queries.some((text) => text.includes("discover_reactions")));
});

test("reactions never touch votes, and don't change the order that breaks ties in a vote", async () => {
    const base = setup(280);
    await movieNight({ mode: "classic", count: 8, save: true }, base);
    const order = state.saved;
    assert.strictEqual(order.length, 8);
    await movieNight({ mode: "classic", count: 8, save: true }, { ...base, reactions: [reaction("sam", 297, "like"), reaction("me", 297, "like")] });
    // The same films are shown, so they're saved in the same order however they were reacted to
    assert.deepStrictEqual(state.saved, order);
    assert.ok(!queries.some((text) => /(INSERT INTO|UPDATE|DELETE FROM) (group_pick_reactions|poll_votes|poll_options|group_polls)/.test(text)));
});

test("saving a reaction writes nowhere near a group, and votes and tallies never read reactions", async () => {
    const model = require("../models/reactionsModel");
    queries.length = 0;
    await model.upsertReaction("me", 550, "like");
    await model.upsertReactions("me", [{ tmdb_id: 551, reaction: "dislike", at: new Date() }]);
    await model.deleteReactions("me", 550);
    assert.ok(queries.length === 3 && !queries.some((text) => /group_|poll_/.test(text)));
    for (const file of ["pollModel.js", "groupPicksModel.js", "groupModel.js"]) {
        assert.doesNotMatch(fs.readFileSync(path.join(__dirname, "../models", file), "utf8"), /discover_reactions|reactionsModel/, file);
    }
});

test("the most reactions can do is less than one more person's favourites", () => {
    assert.ok(ranker.GROUP_BOOST + ranker.GROUP_PENALTY + ranker.GROUP_QUALITY < 1);
    const vector = filmVector({ genres: [18], keywords: [1] });
    const features = new Map(Array.from({ length: 30 }, (_, i) => [i + 1, { genres: [18], keywords: [1] }]));
    const ids = [...features.keys()];
    const loves = ranker.groupTaste({ likes: ids }, features), hates = ranker.groupTaste({ dislikes: ids }, features);
    assert.ok(ranker.groupBoost(99, vector, [loves]) > 0.4 && ranker.groupBoost(99, vector, [loves]) <= ranker.GROUP_BOOST);
    assert.strictEqual(ranker.groupBoost(1, vector, [loves]), ranker.GROUP_BOOST);
    assert.strictEqual(ranker.groupBoost(99, vector, [hates]), -ranker.GROUP_PENALTY);
    assert.strictEqual(ranker.groupBoost(99, vector, [ranker.groupTaste({})]), 0);
    assert.strictEqual(ranker.groupBoost(99, vector, []), 0);
});
