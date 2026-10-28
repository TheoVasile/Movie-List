// The user's taste as a sparse feature vector, built on the server from their lists, watches and Discover reactions,
// for ranking Discover, More Like This and the like (services/discoverRanker.js).
//
// Each film is described by features from TMDb (details, keywords and credits, cached for a month): its genres,
// keywords, director(s), top-billed cast, decade and original language. A feature is a key such as "g:18" (genre
// Drama) or "d:525" (directed by Christopher Nolan). Each kind of feature has a weight, split across the film's
// features of that kind, so a film with 20 keywords doesn't outweigh one with 3.
//
// How much each film counts (weightFilms):
// - Ranked lists: exp(-position / RANK_DECAY), scaled so each list adds up to min(its size, RANK_DECAY), so a
//   long list doesn't drown out a short one and a 3-film list doesn't count for more than its films
// - Unranked lists and watchlists: their order means nothing, so only FLAT_WATCHED, and only for watched films
// - Watched: +WATCHED_BOOST; each rewatch in the diary: +REWATCH_BOOST (up to MAX_REWATCHES)
// - Discover likes: +LIKE_WEIGHT. Dislikes make a separate vector the ranker subtracts
//
// The vector is kept in memory per user for TASTE_TTL, and dropped when the user reacts in Discover

const pool = require("../config/db");
const { cached, cachedMany, fetchTmdb, DAY } = require("./tmdbCache");
const { isTV, tmdbPath, filmGenres } = require("./tmdbMedia");

const RANK_DECAY = 10;
const FLAT_WATCHED = 0.1;
const WATCHED_BOOST = 0.2;
const REWATCH_BOOST = 0.3;
const MAX_REWATCHES = 3;
const LIKE_WEIGHT = 0.8;
const DISLIKE_WEIGHT = 1;
// The films considered, so building the vector stays cheap however big someone's lists are
const MAX_LIKED_FILMS = 150;
const MAX_DISLIKED_FILMS = 50;
const FEATURE_CONCURRENCY = 12;
const TASTE_TTL = 15 * 60 * 1000;
const TASTE_CACHE_SIZE = 2000;

// How much each kind of feature counts in a film's vector
const FEATURE_WEIGHTS = { g: 1, k: 0.8, d: 1.2, c: 0.6, y: 0.4, l: 0.5 };
// The kinds of feature used to tell how alike two candidates are, for diversity (MMR)
const SIMILARITY_KINDS = ["g", "k", "d"];

const MAX_KEYWORDS = 20;
const MAX_CAST = 5;

/// Whether a list is a watchlist: by name, the same test as fetchTopFilms and fetchUnwatchedWatchlist
const isWatchlist = (name) => /watch/i.test(String(name ?? ""));

/// The features of a TMDb film or show (negative id) from its full answer with keywords and credits
function featuresFromTmdb(id, film) {
    const tv = isTV(id);
    const genreIds = (film.genres ?? []).map((genre) => genre.id);
    const date = String((tv ? film.first_air_date : film.release_date) ?? "");
    const year = /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null;
    const keywords = (tv ? film.keywords?.results : film.keywords?.keywords) ?? [];
    const directors = tv
        ? (film.created_by ?? []).map((person) => person.id)
        : (film.credits?.crew ?? []).filter((person) => person.job === "Director").map((person) => person.id);
    return {
        id: Number(id),
        title: (tv ? film.name : film.title) ?? "",
        year,
        genres: tv ? filmGenres(genreIds) : genreIds,
        keywords: keywords.slice(0, MAX_KEYWORDS).map((keyword) => keyword.id),
        directors: [...new Set(directors)],
        cast: (film.credits?.cast ?? []).slice(0, MAX_CAST).map((person) => person.id),
        language: film.original_language ?? "",
        vote_count: film.vote_count ?? 0,
        vote_average: film.vote_average ?? 0,
    };
}

/// A film's features, fresh from TMDb. Null for a film TMDb doesn't have
async function loadFeatures(id) {
    try {
        return featuresFromTmdb(id, await fetchTmdb(tmdbPath(id), { language: "en-US", append_to_response: "keywords,credits" }));
    } catch (error) {
        if (error.response?.status === 404) return null;
        throw error;
    }
}

const FEATURES_MAX_AGE = 30 * DAY;
const featuresKey = (id) => `features:${id}`;

/// A film's features (see featuresFromTmdb), cached for a month since they hardly change. Null for a film TMDb
/// doesn't have (also cached, so it isn't asked again)
function filmFeatures(id) {
    return cached(featuresKey(id), FEATURES_MAX_AGE, () => loadFeatures(id));
}

/// Features for many films as a Map id -> features, from the cache in one go and TMDb a few at a time for the
/// rest. Films that fail or TMDb doesn't have are left out. load(id), for tests, replaces the cache and TMDb
async function featuresFor(ids, load = null, concurrency = FEATURE_CONCURRENCY) {
    const unique = [...new Set(ids.map(Number))];
    const found = new Map();
    if (!load) {
        const byKey = await cachedMany(unique.map(featuresKey), FEATURES_MAX_AGE, (key) => loadFeatures(Number(key.slice(9))), concurrency);
        for (const id of unique) {
            const features = byKey.get(featuresKey(id));
            if (features) found.set(id, features);
        }
        return found;
    }
    let next = 0;
    const worker = async () => {
        while (next < unique.length) {
            const id = unique[next++];
            try {
                const features = await load(id);
                if (features) found.set(id, features);
            } catch (error) {
                // A film TMDb can't answer for right now just isn't used
            }
        }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, unique.length) }, worker));
    return found;
}

/// A film's sparse vector (Map feature -> weight). kinds limits it to some kinds of feature. A film known only by
/// its genre ids (a TMDb list result) can be passed as { genres }
function filmVector(features, kinds = Object.keys(FEATURE_WEIGHTS)) {
    const vector = new Map();
    const add = (kind, values) => {
        if (!kinds.includes(kind)) return;
        const list = [...new Set((values ?? []).filter((value) => value !== null && value !== undefined && value !== ""))];
        if (!list.length) return;
        const each = FEATURE_WEIGHTS[kind] / Math.sqrt(list.length);
        for (const value of list) vector.set(`${kind}:${value}`, (vector.get(`${kind}:${value}`) ?? 0) + each);
    };
    add("g", features.genres);
    add("k", features.keywords);
    add("d", features.directors);
    add("c", features.cast);
    add("y", features.year ? [Math.floor(features.year / 10) * 10] : []);
    add("l", features.language ? [features.language] : []);
    return vector;
}

function norm(vector) {
    let sum = 0;
    for (const value of vector.values()) sum += value * value;
    return Math.sqrt(sum);
}

/// Cosine similarity of two sparse vectors, 0 when either is empty
function cosine(a, b) {
    if (!a?.size || !b?.size) return 0;
    const [small, large] = a.size <= b.size ? [a, b] : [b, a];
    let dot = 0;
    for (const [key, value] of small) {
        const other = large.get(key);
        if (other) dot += value * other;
    }
    const denominator = norm(a) * norm(b);
    return denominator ? dot / denominator : 0;
}

/// Adds weight x vector into sum
function addScaled(sum, vector, weight) {
    for (const [key, value] of vector) sum.set(key, (sum.get(key) ?? 0) + value * weight);
}

/// How much each of the user's films counts, from plain rows (see the top of this file):
/// entries: [{ list_id, list_name, is_ranked, position (0 = top), size, tmdb_id }]
/// watched: Set of TMDb ids marked watched; rewatches: Map TMDb id -> rewatches in the diary;
/// reactions: [{ tmdb_id, reaction }]. Returns { likes: Map id -> weight, dislikes: Map id -> weight }
function weightFilms({ entries = [], watched = new Set(), rewatches = new Map(), reactions = [] }) {
    const likes = new Map();
    const add = (id, weight) => likes.set(Number(id), (likes.get(Number(id)) ?? 0) + weight);

    const lists = new Map();
    for (const entry of entries) {
        if (!lists.has(entry.list_id)) lists.set(entry.list_id, []);
        lists.get(entry.list_id).push(entry);
    }
    for (const films of lists.values()) {
        const { is_ranked: ranked, list_name: name } = films[0];
        if (ranked === false || isWatchlist(name)) {
            for (const film of films) {
                if (watched.has(Number(film.tmdb_id))) add(film.tmdb_id, FLAT_WATCHED);
            }
            continue;
        }
        const sorted = [...films].sort((a, b) => a.position - b.position);
        const raw = sorted.map((_, i) => Math.exp(-i / RANK_DECAY));
        const total = raw.reduce((sum, value) => sum + value, 0);
        const scale = Math.min(sorted.length, RANK_DECAY) / total;
        sorted.forEach((film, i) => add(film.tmdb_id, raw[i] * scale));
    }
    for (const id of watched) add(id, WATCHED_BOOST);
    for (const [id, count] of rewatches) add(id, REWATCH_BOOST * Math.min(count, MAX_REWATCHES));

    const dislikes = new Map();
    for (const { tmdb_id: id, reaction } of reactions) {
        if (reaction === "like") add(id, LIKE_WEIGHT);
        if (reaction === "dislike") dislikes.set(Number(id), DISLIKE_WEIGHT);
    }
    // A film the user disliked in Discover doesn't also count as liked
    for (const id of dislikes.keys()) likes.delete(id);
    return { likes, dislikes };
}

const topByWeight = (weights, limit) => [...weights].sort((a, b) => b[1] - a[1]).slice(0, limit);

/// The taste vector from film weights (weightFilms) and their features (Map id -> features):
/// { likes: Map, dislikes: Map, topGenres: [ids], topKeywords: [ids], seeds: [{ id, weight }], size }.
/// seeds are the films that count most, for when the app sends none
function tasteFromWeights({ likes, dislikes }, features) {
    const likeVector = new Map();
    const dislikeVector = new Map();
    const liked = topByWeight(likes, MAX_LIKED_FILMS);
    for (const [id, weight] of liked) {
        const film = features.get(id);
        if (film) addScaled(likeVector, filmVector(film), weight);
    }
    for (const [id, weight] of topByWeight(dislikes, MAX_DISLIKED_FILMS)) {
        const film = features.get(id);
        if (film) addScaled(dislikeVector, filmVector(film), weight);
    }
    const top = (prefix, limit) => [...likeVector]
        .filter(([key]) => key.startsWith(prefix))
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit)
        .map(([key]) => Number(key.slice(prefix.length)));
    const maxWeight = liked[0]?.[1] ?? 1;
    return {
        likes: likeVector,
        dislikes: dislikeVector,
        topGenres: top("g:", 5),
        topKeywords: top("k:", 10),
        seeds: liked.slice(0, 24).map(([id, weight]) => ({ id, weight: weight / maxWeight })),
        size: liked.length,
    };
}

/// Which films to describe: the most weighted liked ones and the disliked ones
function filmsToFetch({ likes, dislikes }) {
    return [...topByWeight(likes, MAX_LIKED_FILMS), ...topByWeight(dislikes, MAX_DISLIKED_FILMS)].map(([id]) => id);
}

// The user's films with their list positions, watches, rewatches and Discover reactions
async function loadTasteRows(user_id) {
    const [entries, watched, rewatches, reactions] = await Promise.all([
        pool.query(
            `SELECT l.id AS list_id, l.name AS list_name, l.is_ranked, m.tmdb_id,
                    (ROW_NUMBER() OVER (PARTITION BY l.id ORDER BY lm.rank NULLS LAST, lm.id) - 1)::int AS position
             FROM lists l JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
             WHERE l.user_id = $1`,
            [user_id]
        ),
        pool.query("SELECT m.tmdb_id FROM watched_movies w JOIN movies m ON m.id = w.movie_id WHERE w.user_id = $1", [user_id]),
        pool.query(
            `SELECT m.tmdb_id, COUNT(*)::int AS count FROM watch_log w JOIN movies m ON m.id = w.movie_id
             WHERE w.user_id = $1 GROUP BY m.tmdb_id`,
            [user_id]
        ),
        // Read-only callers (scripts/evalRecs.js) may run before the table exists
        pool.query("SELECT tmdb_id, reaction FROM discover_reactions WHERE user_id = $1 AND reaction <> 'skip'", [user_id])
            .catch((error) => (error.code === "42P01" ? { rows: [] } : Promise.reject(error))),
    ]);
    return {
        entries: entries.rows.map((row) => ({ ...row, tmdb_id: Number(row.tmdb_id) })),
        watched: new Set(watched.rows.map((row) => Number(row.tmdb_id))),
        rewatches: new Map(rewatches.rows.map((row) => [Number(row.tmdb_id), row.count])),
        reactions: reactions.rows,
    };
}

// user_id -> { value, expiresAt }, oldest first; and builds under way, so a burst of requests builds once
const memory = new Map();
const building = new Map();
// Bumped when the user's reactions change, so a build that started before isn't kept
const generations = new Map();

/// The user's taste vector (tasteFromWeights), from memory when it was built in the last TASTE_TTL
async function tasteVector(user_id) {
    const hit = memory.get(user_id);
    if (hit && hit.expiresAt > Date.now()) return hit.value;
    if (building.has(user_id)) return building.get(user_id);
    const generation = generations.get(user_id) ?? 0;
    const promise = (async () => {
        const weights = weightFilms(await loadTasteRows(user_id));
        const value = tasteFromWeights(weights, await featuresFor(filmsToFetch(weights)));
        if ((generations.get(user_id) ?? 0) !== generation) return value;
        memory.delete(user_id);
        memory.set(user_id, { value, expiresAt: Date.now() + TASTE_TTL });
        if (memory.size > TASTE_CACHE_SIZE) memory.delete(memory.keys().next().value);
        return value;
    })().finally(() => building.delete(user_id));
    building.set(user_id, promise);
    return promise;
}

/// The taste vector, or null if it can't be had within ms (it carries on building, for next time) or fails
async function tasteVectorWithin(user_id, ms) {
    let timer;
    const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve(null), ms); });
    try {
        return await Promise.race([tasteVector(user_id).catch((error) => {
            console.error("Couldn't build the taste vector:", error.message);
            return null;
        }), timeout]);
    } finally {
        clearTimeout(timer);
    }
}

/// Forgets the user's taste vector, after their reactions change
function invalidateTaste(user_id) {
    memory.delete(user_id);
    building.delete(user_id);
    generations.set(user_id, (generations.get(user_id) ?? 0) + 1);
    if (generations.size > TASTE_CACHE_SIZE) generations.delete(generations.keys().next().value);
}

module.exports = {
    tasteVector, tasteVectorWithin, invalidateTaste, filmFeatures, featuresFor, featuresFromTmdb, filmVector, cosine,
    weightFilms, tasteFromWeights, filmsToFetch, loadTasteRows, isWatchlist, SIMILARITY_KINDS, FEATURE_WEIGHTS, RANK_DECAY,
};
