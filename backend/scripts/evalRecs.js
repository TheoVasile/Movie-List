// Offline evaluation of Discover's ranking. Read-only: it only reads the database (and TMDb, through the shared
// cache, which is the only thing written). Prints totals, never who the users are.
//
// For up to EVAL_USERS users with at least MIN_RANKED films in a ranked list, a fixed 20% of the top TOP_N films of
// their biggest ranked list are hidden. Each strategy then recommends from what's left, and we measure how many
// hidden films it puts in its first 20: recall@20 (share of hidden films found) and NDCG@20 (finding them higher
// up counts more).
//   old: before this change: page 1 of TMDb recommendations per seed and a popularity-sorted genre feed,
//        interleaved, then trending, first appearance wins
//   new: services/discoverFeed.js with the taste vector, seed weights, MMR and explore slots
// Both use the same seeds: the top SEEDS remaining films of the ranked list (as the app sends its top films)
//
// Run from backend/ (for .env): node scripts/evalRecs.js [users] [min ranked films, default 30]

const pool = require("../config/db");
const { tmdbGet, HOUR } = require("../services/tmdbCache");
const { weightFilms, tasteFromWeights, filmsToFetch, featuresFor, loadTasteRows, isWatchlist } = require("../services/tasteVector");
const { buildDiscover, toDiscoverMovie } = require("../services/discoverFeed");
const { isTV, tmdbPath } = require("../services/tmdbMedia");

const EVAL_USERS = Number(process.argv[2]) || 30;
const MIN_RANKED = Number(process.argv[3]) || 30;
const TOP_N = 50;
const HIDE_SHARE = 0.2;
const SEEDS = 6;
const K = 20;

const get = (path, params) => tmdbGet(path, params, HOUR);

// A small seeded random number generator, so every run hides the same films
function random(seed) {
    let state = seed >>> 0;
    return () => {
        state = (state * 1664525 + 1013904223) >>> 0;
        return state / 2 ** 32;
    };
}

function metrics(ranked, hidden, k = K) {
    const top = ranked.slice(0, k);
    const hits = top.filter((id) => hidden.has(id)).length;
    const dcg = top.reduce((sum, id, i) => sum + (hidden.has(id) ? 1 / Math.log2(i + 2) : 0), 0);
    const ideal = Array.from({ length: Math.min(hidden.size, k) }, (_, i) => 1 / Math.log2(i + 2)).reduce((a, b) => a + b, 0);
    return { recall: hits / hidden.size, ndcg: ideal ? dcg / ideal : 0, hits };
}

// Discover before this change, for the same seeds and genres
async function oldStrategy(seeds, genres, listed) {
    const results = (path, params) => get(path, { language: "en-US", page: 1, ...params }).then((data) => data.results ?? []).catch(() => []);
    const [trending, ...feeds] = await Promise.all([
        results("trending/movie/week"),
        ...seeds.map((seed) => results(`${tmdbPath(seed.id)}/recommendations`, { page: 1 })),
        ...(genres.length ? [results("discover/movie", { with_genres: genres.join("|"), without_genres: "", sort_by: "popularity.desc", "vote_count.gte": 200, include_adult: false })] : []),
    ]);
    const merged = [];
    for (let i = 0; i < Math.max(0, ...feeds.map((list) => list.length)); i++) feeds.forEach((list) => list[i] && merged.push(list[i]));
    const seen = new Set(seeds.map((seed) => seed.id));
    return [...merged, ...trending]
        .map(toDiscoverMovie)
        .filter((movie) => movie && !seen.has(movie.id) && seen.add(movie.id))
        .filter((movie) => !listed.has(movie.id))
        .map((movie) => movie.id);
}

async function main() {
    // Users with a big enough ranked list (not a watchlist), in a fixed but meaningless order
    const users = (await pool.query(
        `SELECT DISTINCT l.user_id, md5(l.user_id) AS sort_key
         FROM lists l
         WHERE l.is_ranked AND l.name NOT ILIKE '%watch%'
           AND (SELECT COUNT(*) FROM list_movies lm WHERE lm.list_id = l.id) >= $1
         ORDER BY sort_key LIMIT $2`,
        [MIN_RANKED, EVAL_USERS]
    )).rows.map((row) => row.user_id);

    const STRATEGIES = ["old", "new", "new, no explore slots"];
    const empty = () => ({ recall: 0, ndcg: 0, hits: 0, recall50: 0 });
    const totals = Object.fromEntries(STRATEGIES.map((name) => [name, empty()]));
    let evaluated = 0;
    let hiddenTotal = 0;
    for (const [index, user] of users.entries()) {
        const rows = await loadTasteRows(user);
        rows.reactions = [];
        // The user's biggest ranked list, films only, best first
        const lists = new Map();
        for (const entry of rows.entries) {
            if (entry.is_ranked === false || isWatchlist(entry.list_name)) continue;
            if (!lists.has(entry.list_id)) lists.set(entry.list_id, []);
            lists.get(entry.list_id).push(entry);
        }
        const biggest = [...lists.values()].sort((a, b) => b.length - a.length)[0] ?? [];
        const top = biggest.filter((entry) => !isTV(entry.tmdb_id)).sort((a, b) => a.position - b.position).slice(0, TOP_N);
        if (top.length < MIN_RANKED || Math.round(top.length * HIDE_SHARE) < 2) continue;

        const next = random(index + 1);
        const shuffled = [...top].sort(() => next() - 0.5);
        const hidden = new Set(shuffled.slice(0, Math.round(top.length * HIDE_SHARE)).map((entry) => entry.tmdb_id));
        // Everything about the hidden films is removed, so nothing gives them away
        const visible = {
            entries: rows.entries.filter((entry) => !hidden.has(entry.tmdb_id)),
            watched: new Set([...rows.watched].filter((id) => !hidden.has(id))),
            rewatches: new Map([...rows.rewatches].filter(([id]) => !hidden.has(id))),
            reactions: [],
        };
        const listed = new Set(visible.entries.map((entry) => entry.tmdb_id));
        const weights = weightFilms(visible);
        const taste = tasteFromWeights(weights, await featuresFor(filmsToFetch(weights)));
        const seedFilms = top.filter((entry) => !hidden.has(entry.tmdb_id)).slice(0, SEEDS);
        const seeds = seedFilms.map((entry, i) => ({ id: entry.tmdb_id, weight: Math.exp(-i / 10) }));

        const [oldRanked, newItems] = await Promise.all([
            oldStrategy(seeds.map(({ id }) => ({ id, weight: 1 })), taste.topGenres.slice(0, 3), listed),
            buildDiscover({ seeds, taste, exclude: listed, get, features: featuresFor, toMovie: toDiscoverMovie }),
        ]);
        const rankings = {
            old: oldRanked,
            new: newItems.map((item) => item.id),
            "new, no explore slots": newItems.filter((item) => item.source !== "explore").map((item) => item.id),
        };
        for (const name of STRATEGIES) {
            const result = metrics(rankings[name], hidden);
            totals[name].recall += result.recall;
            totals[name].ndcg += result.ndcg;
            totals[name].hits += result.hits;
            totals[name].recall50 += metrics(rankings[name], hidden, 50).recall;
        }
        evaluated++;
        hiddenTotal += hidden.size;
        process.stderr.write(`\r${evaluated} users evaluated`);
    }
    process.stderr.write("\n");
    if (!evaluated) {
        console.log("No users with enough ranked films.");
        return;
    }
    console.log(`Users: ${evaluated}, hidden films: ${hiddenTotal} (20% of each user's top ${TOP_N} ranked films)`);
    console.log("strategy                recall@20  NDCG@20  found in top 20  recall@50");
    for (const name of STRATEGIES) {
        const t = totals[name];
        console.log(`${name.padEnd(22)}  ${(t.recall / evaluated).toFixed(4).padStart(9)}  ${(t.ndcg / evaluated).toFixed(4).padStart(7)}  ${String(t.hits).padStart(15)}  ${(t.recall50 / evaluated).toFixed(4).padStart(9)}`);
    }
}

main()
    .catch((error) => {
        console.error("Evaluation failed:", error.message);
        process.exitCode = 1;
    })
    .finally(() => setTimeout(() => pool.end(), 500));
