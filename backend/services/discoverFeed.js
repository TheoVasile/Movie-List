// Builds the Discover feed: gathers candidates from TMDb, scores them (services/discoverRanker.js) and returns
// them in their final order. Everything outside (TMDb, the taste vector, what to leave out) is passed in, so the
// route and the offline evaluation (scripts/evalRecs.js) share it.
//
// Candidates come from:
// - seed: pages 1 (and 2, for the SEEDS_WITH_PAGE_TWO most weighted seeds) of TMDb's recommendations for each seed
// - taste: TMDb's discover, best rated first, in the user's chosen genres or their taste's top genres, and a second
//   feed in their taste's top keywords. Both with a minimum number of votes
// - explore: this week's trending films, used only for every EXPLORE_EVERY-th place
// Seed and taste candidates need MIN_VOTES votes on TMDb

const { isTV, tmdbPath, showAsFilm, tvGenres } = require("./tmdbMedia");
const ranker = require("./discoverRanker");
const { filmVector } = require("./tasteVector");
const { tasteScore } = ranker;

const MIN_VOTES = 100;
const MIN_TRENDING_VOTES = 20;
const SEEDS_WITH_PAGE_TWO = 4;
// Seeds taken from the taste vector per page, when the app sends none
const FALLBACK_SEEDS = 6;
// Candidates described in full (keywords, director, cast) for scoring; the rest are scored by genre, era and language
const MAX_DESCRIBED = 60;

// Keeps only films a swipe card can show and the app can save, in the shape the app's Movie model decodes
function toDiscoverMovie(movie) {
    if (movie.adult || !movie.poster_path || !/^\d{4}-\d{2}-\d{2}$/.test(movie.release_date ?? "")) {
        return null;
    }
    return {
        id: movie.id,
        title: movie.title,
        release_date: movie.release_date,
        overview: movie.overview ?? "",
        poster_path: movie.poster_path,
        original_language: movie.original_language ?? "",
        popularity: movie.popularity ?? 0,
        vote_average: movie.vote_average ?? 0,
        genre_ids: movie.genre_ids ?? [],
        media_type: movie.media_type === "tv" ? "tv" : "movie",
    };
}

/// The vector for a candidate: from its full features when there are some, otherwise from what a TMDb list result has
function vectorFor(movie, features) {
    if (features) return filmVector(features);
    const year = Number(String(movie.release_date ?? "").slice(0, 4)) || null;
    return filmVector({ genres: movie.genre_ids, year, language: movie.original_language });
}

/// The Discover feed, best first. Options:
/// seeds [{ id, weight }]; types ["movie"] / ["tv"] / both; page; genres, avoidGenres (film genre ids); onlyGenres;
/// exclude: Set of ids never to show (listed, reacted to, already shown); taste: the taste vector or null;
/// friends: discover movies friends recommended, each with recommended_by; extraFeeds: more TMDb results (already
/// films) to treat as taste candidates; get(path, params): a cached TMDb answer; features(ids): Map id -> features;
/// toMovie(result): a discover movie or null
async function buildDiscover({
    seeds = [], types = ["movie"], page = 1, genres = [], avoidGenres = [], onlyGenres = false, exclude = new Set(),
    taste = null, friends = [], extraFeeds = [], get, features, toMovie,
}) {
    const typeOf = (id) => (isTV(id) ? "tv" : "movie");
    let usedSeeds = seeds.filter((seed) => types.includes(typeOf(seed.id)));
    if (!usedSeeds.length && taste?.seeds?.length) {
        // A different few of the user's favourites on each page
        const fromTaste = taste.seeds.filter((seed) => types.includes(typeOf(seed.id)));
        const start = fromTaste.length ? ((page - 1) * FALLBACK_SEEDS) % fromTaste.length : 0;
        usedSeeds = [...fromTaste.slice(start), ...fromTaste.slice(0, start)].slice(0, FALLBACK_SEEDS);
    }
    const seedIds = new Set(usedSeeds.map((seed) => seed.id));

    const resultsOf = (type, path, params) => get(path, { language: "en-US", ...params })
        .then((data) => (data?.results ?? []).map((item) => (type === "tv" ? showAsFilm(item) : item)))
        .catch(() => []);
    const genresFor = (type, ids) => (type === "tv" ? tvGenres(ids) : ids);

    // Seed recommendations: page 1 for every seed, and page 2 for the most weighted ones (cached, so cheap)
    const byWeight = [...usedSeeds].sort((a, b) => b.weight - a.weight).slice(0, SEEDS_WITH_PAGE_TWO).map((seed) => seed.id);
    const seedFetches = usedSeeds.map(async (seed) => {
        const type = typeOf(seed.id);
        const pages = await Promise.all([1, ...(byWeight.includes(seed.id) ? [2] : [])]
            .map((number) => resultsOf(type, `${tmdbPath(seed.id)}/recommendations`, { page: number })));
        return { seed, results: pages.flat() };
    });

    // Taste feeds: best rated in the chosen (or the taste's top) genres, and the most voted in the taste's keywords
    const feedGenres = genres.length ? genres : (taste?.topGenres ?? []).slice(0, 3);
    const keywords = (taste?.topKeywords ?? []).slice(0, 5);
    const tasteFetches = types.flatMap((type) => [
        ...(feedGenres.length ? [resultsOf(type, `discover/${type}`, {
            page,
            with_genres: genresFor(type, feedGenres).join("|"),
            without_genres: genresFor(type, avoidGenres).join(","),
            sort_by: "vote_average.desc",
            "vote_count.gte": type === "tv" ? 150 : 300,
            include_adult: false,
        })] : []),
        ...(keywords.length ? [resultsOf(type, `discover/${type}`, {
            page,
            with_keywords: keywords.join("|"),
            ...(onlyGenres && genres.length ? { with_genres: genresFor(type, genres).join("|") } : {}),
            without_genres: genresFor(type, avoidGenres).join(","),
            sort_by: "vote_count.desc",
            "vote_count.gte": MIN_VOTES,
            include_adult: false,
        })] : []),
    ]);
    const trendingFetches = types.map((type) => resultsOf(type, `trending/${type}/week`, { page }));

    const [seedResults, tasteResults, trendingResults, extraResults] = await Promise.all([
        Promise.all(seedFetches),
        Promise.all(tasteFetches),
        Promise.all(trendingFetches),
        Promise.all(extraFeeds.map((feed) => Promise.resolve(feed).catch(() => []))),
    ]);

    const wanted = new Set(genres);
    const avoided = new Set(avoidGenres);
    const candidates = new Map();
    const consider = (result, origin, minVotes) => {
        const movie = toMovie(result);
        if (!movie || exclude.has(movie.id) || seedIds.has(movie.id)) return null;
        if (onlyGenres && wanted.size && !movie.genre_ids.some((id) => wanted.has(id))) return null;
        if ((result.vote_count ?? 0) < minVotes) return null;
        const entry = candidates.get(movie.id) ?? { movie, support: 0, origins: new Set() };
        entry.origins.add(origin);
        candidates.set(movie.id, entry);
        return entry;
    };

    const support = ranker.seedSupport(seedResults);
    const firstResult = new Map();
    for (const { results } of seedResults) {
        for (const result of results) if (!firstResult.has(result.id)) firstResult.set(result.id, result);
    }
    for (const [id, { support: value }] of support) {
        const entry = consider(firstResult.get(id), "seed", MIN_VOTES);
        if (entry) entry.support = value;
    }
    for (const result of [...tasteResults.flat(), ...extraResults.flat()]) consider(result, "taste", MIN_VOTES);
    const main = [...candidates.values()];
    const mainIds = new Set(candidates.keys());
    const interleave = (lists) => {
        const merged = [];
        for (let i = 0; i < Math.max(0, ...lists.map((list) => list.length)); i++) {
            lists.forEach((list) => list[i] && merged.push(list[i]));
        }
        return merged;
    };
    for (const result of interleave(trendingResults)) consider(result, "trending", MIN_TRENDING_VOTES);
    const explore = [...candidates.values()].filter((entry) => !mainIds.has(entry.movie.id));

    // Score by genre first, then describe the most promising candidates (and friends' picks) in full
    const genreOnly = (entry) => tasteScore(vectorFor(entry.movie), taste);
    const maxSupport = Math.max(0, ...main.map((entry) => entry.support));
    const promising = [...main]
        .sort((a, b) => ranker.combineScore({ support: b.support, maxSupport, taste: genreOnly(b) })
            - ranker.combineScore({ support: a.support, maxSupport, taste: genreOnly(a) }))
        .slice(0, MAX_DESCRIBED);
    const described = features
        ? await features([...promising, ...explore.slice(0, 10)].map((entry) => entry.movie.id).concat(friends.map((film) => film.id)))
            .catch(() => new Map())
        : new Map();

    const score = (movie, value = 0) => {
        const full = described.get(movie.id);
        return {
            score: ranker.combineScore({
                support: value,
                maxSupport,
                taste: tasteScore(vectorFor(movie, full), taste),
                voteAverage: movie.vote_average ?? full?.vote_average,
                avoided: movie.genre_ids.some((id) => avoided.has(id)),
            }),
            vector: ranker.similarityVector(full ?? { genres: movie.genre_ids }),
        };
    };
    const output = (movie, scored, source, extra = {}) => ({ ...movie, score: Math.round(scored.score * 10000) / 10000, source, ...extra });

    const scoredMain = main
        .map((entry) => ({ entry, ...score(entry.movie, entry.support) }))
        .sort((a, b) => b.score - a.score);
    const ranked = ranker.mmr(scoredMain)
        .map(({ entry, score: value }) => output(entry.movie, { score: value }, entry.support > 0 ? "seed" : "taste"));
    const explored = explore.map((entry) => output(entry.movie, score(entry.movie), ranked.length ? "explore" : "trending"));

    const friendPicks = friends.slice(0, ranker.MAX_FRIEND_PICKS).map((film) => {
        const { recommended_by: by, ...movie } = film;
        return output(movie, score(movie), "friend", { recommended_by: by });
    });
    return ranker.placeFriends(ranked.length ? ranker.blendExplore(ranked, explored) : explored, friendPicks);
}

module.exports = { buildDiscover, toDiscoverMovie, MIN_VOTES };
