const express = require("express");
const axios = require("axios");
const { setMovieNote } = require("../models/notesModel");
const { createMovie, addMovieToList, removeMovieFromList, updateMovieRank } = require("../models/movieModel");

const requireListOwner = require("../middleware/listOwnership");
const { setMovieWatched, logWatch, deleteRewatch, fetchDiary } = require("../models/watchedModel");
const { mapWithConcurrency, createLimiter } = require("../services/letterboxdService");
const { fetchListsForTaste, fetchListedTmdbIds, fetchFriend, fetchTopFilms, fetchUnwatchedWatchlist } = require("../models/tasteModel");
const { recommendFilms, recommendForGroup, placeInList, AIUnavailableError, AILimitError } = require("../services/aiDiscoverService");
const { MAX_MEMBERS: MAX_GROUP_MEMBERS, followedByHandle, groupParticipants } = require("../models/groupModel");
const { fetchPicks, pickHistory, saveRecommendations } = require("../models/groupPicksModel");
const pool = require("../config/db");
const { parseFilters, hasFilters, matchesFilters, availableServices } = require("../services/filmFilters");
const { isTV, tmdbPath, showAsFilm, filmGenres, tvGenres } = require("../services/tmdbMedia");

const router = express.Router();
// The list's owner, or someone they invited to edit it
const editsBodyList = requireListOwner.requireListEditor((req) => req.body.list_id);

// Lowercase, treat "&" as "and", drop punctuation and a leading article so
// "Home, Alone" matches "Home Alone" and "godfather" matches "The Godfather"
function normalizeTitle(title = "") {
    return title
        .toLowerCase()
        .replace(/&/g, " and ")
        .replace(/[^\p{L}\p{N}\s]/gu, " ")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/^(the|a|an) (?=\S)/, "");
}

// TMDb's own ordering leans on short-term popularity, which can bury well-known films
// (e.g. Home Alone (1990) ranks 11th out of season). Rank by how known a film is instead,
// scaled by how well its title matches. Scaling rather than adding keeps an obscure exact
// match ("Bardo", 3 votes) from beating a known film whose title only starts with the
// query ("BARDO, False Chronicle of a Handful of Truths", 278 votes)
function titleMatchWeight(movie, query) {
    const titles = [movie.title, movie.original_title].map(normalizeTitle);
    const queryWords = query.split(" ");
    if (titles.includes(query)) {
        return 1;
    }
    if (titles.some((t) => t.startsWith(query))) {
        return 0.8;
    }
    // Every query word starts some word of the title, e.g. "lost new york" in "Home Alone 2: Lost in New York"
    if (titles.some((t) => {
        const words = t.split(" ");
        return queryWords.every((q) => words.some((w) => w.startsWith(q)));
    })) {
        return 0.6;
    }
    // TMDb matched it some other way, such as an alternative title
    return 0.3;
}

function relevanceScore(movie, query) {
    // Vote count is a stable measure of how known a film is; popularity gives
    // recent releases that haven't gathered votes yet a smaller boost
    const fame = Math.log10((movie.vote_count || 0) + 1) + 0.5 * Math.log10((movie.popularity || 0) + 1);
    return titleMatchWeight(movie, query) * fame;
}

router.get("/search", async (req, res) => {
    try {
        const API_KEY = process.env.API_KEY;
        const { name } = req.query;
        if (!name) {
            return res.status(400).json({ error: "Movie name is required" });
        }
        // TV shows too, for app versions that can tell them apart (see services/tmdbMedia.js)
        const types = req.query.include_tv === "1" ? ["movie", "tv"] : ["movie"];

        const params = {
            query: name,
            include_adult: false,
            language: "en-US",
            api_key: API_KEY,
        };

        // Two pages, since the film being looked for can sit past TMDb's first 20 results
        console.log("📡 Fetching movies from TMDb...");
        const pages = await Promise.all(types.flatMap((type) => [1, 2].map((page) =>
            axios.get(`https://api.themoviedb.org/3/search/${type}`, { params: { ...params, page } })
                .then((response) => (type === "tv" ? response.data.results.map(showAsFilm) : response.data.results)))));
        const seen = new Set();
        const movies = pages
            .flat()
            .filter((movie) => !seen.has(movie.id) && seen.add(movie.id));

        // Array.prototype.sort is stable, so equal scores keep TMDb's order
        const query = normalizeTitle(name);
        const ranked = movies
            .map((movie) => ({ movie, score: relevanceScore(movie, query) }))
            .sort((a, b) => b.score - a.score)
            .slice(0, 20)
            .map(({ movie }) => movie);

        console.log("✅ Movies fetched successfully!");
        res.json(ranked);
    } catch (error) {
        console.error("❌ Error fetching movies:", error.message);
        res.status(500).json({ error: "Internal Server Error" });
    }
});

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

// Comma-separated TMDb ids from a query parameter, e.g. "28,35"
function parseIds(value, limit) {
    return String(value ?? "")
        .split(",")
        .map((id) => parseInt(id, 10))
        .filter((id) => id > 0)
        .slice(0, limit);
}

// Comma-separated film and show ids, where shows are negative, e.g. "771,-1399"
function parseMediaIds(value, limit) {
    return String(value ?? "")
        .split(",")
        .map((id) => parseInt(id, 10))
        .filter((id) => Number.isInteger(id) && id !== 0)
        .slice(0, limit);
}

// A film or show id from a query parameter, or null when it isn't one
function mediaId(value) {
    const id = Number(value);
    return Number.isInteger(id) && id !== 0 ? id : null;
}

// Films for the Discover tab: TMDb recommendations for the given films (seeds: the user's top-ranked
// and recently liked films) plus well-rated films in their favourite genres (genres), interleaved so
// no single source dominates, followed by this week's trending films. avoid_genres keeps disliked
// genres out of the genre feed. only_genres=1 means the user picked these genres themselves: then every
// film returned has at least one of them. kind=tv gives TV shows instead (negative ids, see services/tmdbMedia.js)
// and kind=all both; seeds can be shows. The app filters out films already in a list and orders by taste
router.get("/discover", async (req, res) => {
    try {
        const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
        const kind = ["movie", "tv", "all"].includes(req.query.kind) ? req.query.kind : "movie";
        const types = kind === "all" ? ["movie", "tv"] : [kind];
        const seeds = parseMediaIds(req.query.seeds, 8).filter((id) => types.includes(isTV(id) ? "tv" : "movie"));
        const onlyGenres = req.query.only_genres === "1";
        const genres = parseIds(req.query.genres, onlyGenres ? 20 : 3);
        const avoidGenres = parseIds(req.query.avoid_genres, 3);
        const params = { api_key: process.env.API_KEY, language: "en-US", page };
        // Optional: only films in these original languages, and/or streaming on these services in region
        const filters = parseFilters(req.query);
        // Genres are film genres; shows are asked for in the closest TV genres
        const genresFor = (type, ids) => (type === "tv" ? tvGenres(ids) : ids);
        // TMDb results as films, shows included
        const fetchResults = (type, path, extra = {}) => axios.get(`https://api.themoviedb.org/3/${path}`, { params: { ...params, ...extra } })
            .then((response) => (response.data.results ?? []).map((item) => (type === "tv" ? showAsFilm(item) : item)));

        // Films in any of the favourite genres ("|" means or), skipping obscure titles
        const genreFeeds = genres.length
            ? types.map((type) => fetchResults(type, `discover/${type}`, {
                with_genres: genresFor(type, genres).join("|"),
                without_genres: genresFor(type, avoidGenres).join(","),
                sort_by: "popularity.desc",
                "vote_count.gte": type === "tv" ? 100 : 200,
                include_adult: false,
            }))
            : [];

        // With filters, recommendations alone rarely have enough matches, so TMDb is also asked directly for films
        // that fit: one feed per language (or one for the services alone), in the chosen genres
        const filteredFeeds = hasFilters(filters)
            ? types.flatMap((type) => (filters.languages.length ? filters.languages.slice(0, 3) : [null]).map((language) => fetchResults(type, `discover/${type}`, {
                ...(language ? { with_original_language: language } : {}),
                ...(filters.providers.length ? { with_watch_providers: filters.providers.join("|"), watch_region: filters.region, with_watch_monetization_types: "flatrate|free|ads" } : {}),
                ...(genres.length && onlyGenres ? { with_genres: genresFor(type, genres).join("|") } : {}),
                sort_by: "popularity.desc",
                "vote_count.gte": type === "tv" ? 50 : 100,
                include_adult: false,
            })))
            : [];

        // allSettled so one seed TMDb doesn't know about can't fail the whole request
        const outcomes = await Promise.allSettled([
            ...types.map((type) => fetchResults(type, `trending/${type}/week`)),
            // The app sends different seeds for every batch, so each seed's best (first page) recommendations are used
            ...seeds.map((id) => fetchResults(isTV(id) ? "tv" : "movie", `${tmdbPath(id)}/recommendations`, { page: 1 })),
            ...genreFeeds,
            ...filteredFeeds,
        ]);
        const resultsOf = (outcome) => (outcome.status === "fulfilled" ? outcome.value : []);
        const interleave = (lists) => {
            const merged = [];
            for (let i = 0; i < Math.max(0, ...lists.map((list) => list.length)); i++) {
                lists.forEach((list) => list[i] && merged.push(list[i]));
            }
            return merged;
        };
        const trending = interleave(outcomes.slice(0, types.length).map(resultsOf));
        const interleaved = interleave(outcomes.slice(types.length).map(resultsOf));

        const seen = new Set(seeds);
        const wanted = new Set(genres);
        const movies = [...interleaved, ...trending]
            .map(toDiscoverMovie)
            .filter((movie) => movie && !seen.has(movie.id) && seen.add(movie.id))
            .filter((movie) => !onlyGenres || movie.genre_ids.some((id) => wanted.has(id)));

        if (!hasFilters(filters)) {
            return res.json(movies);
        }
        // Every film is checked, recommendations and the filtered feeds alike, so nothing slips through
        const passes = await mapWithConcurrency(movies, (movie) => matchesFilters(movie, filters), 10);
        res.json(movies.filter((_, i) => passes[i]));
    } catch (error) {
        console.error("Error fetching discover movies:", error.message);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Short strings from the app, trimmed and capped so a request can't inflate the AI prompt
function cleanText(value, maxLength = 120) {
    return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function cleanFilms(value, limit) {
    return (Array.isArray(value) ? value : [])
        .slice(0, limit)
        .map((film) => ({ title: cleanText(film?.title), year: cleanText(String(film?.year ?? ""), 4) }))
        .filter((film) => film.title);
}

function cleanStrings(value, limit) {
    return (Array.isArray(value) ? value : []).slice(0, limit).map((item) => cleanText(item)).filter(Boolean);
}

// The TMDb film for an AI pick, matching on title and year (a year either side allows for festival
// vs. general release dates), or null when TMDb doesn't have it
async function findOnTmdb(title, year) {
    const search = (params) => axios.get("https://api.themoviedb.org/3/search/movie", {
        params: { api_key: process.env.API_KEY, query: title, include_adult: false, ...params },
        timeout: 15000,
    }).then((response) => response.data.results ?? []);
    let results = await search({ year });
    if (!results.length) {
        results = (await search({})).filter((movie) => Math.abs(Number(String(movie.release_date).slice(0, 4)) - year) <= 1);
    }
    return results[0] ?? null;
}

const LEGACY_GENDER_PRONOUNS = { Woman: "She/Her", Man: "He/Him", "Non-binary": "They/Them" };

// Films for the Discover tab chosen by the AI from everything in the user's lists, plus their Discover
// swipes and anything they chose to share (age range, pronouns) for when their lists are empty.
// Answers 503 when AI isn't set up and 429 at the daily limit, so the app can fall back to /discover.
// With "Accept: application/x-ndjson" the films stream back one JSON object per line as the AI picks them,
// so the first card shows in seconds; otherwise (builds from before streaming) they come as one array
// How many of each person's favourites seed Classic movie night picks, how many picks can come from any one
// favourite (so one shared love doesn't fill the list), and how many TMDb votes a pick needs
const MOVIE_NIGHT_SEEDS = 6;
const MOVIE_NIGHT_PER_SEED = 2;
const MOVIE_NIGHT_MIN_VOTES = 100;

/// Movie night picks without AI, for the user and everyone else coming: films on several people's watchlists
/// first, then films TMDb recommends from everyone's favourites, preferring films recommended from more people's
/// favourites. Each favourite leads to at most a couple of picks. people is [{ firebase_uid, name, me }].
/// filters (languages, services) and genres narrow the picks. Returns [{ ...discover movie, reason }]
async function classicMovieNight(people, count, filters, genres) {
    // Fewer favourites each as the group grows, so the number of TMDb requests stays about the same
    const seedsEach = Math.max(2, Math.floor(12 / people.length));
    const data = await Promise.all(people.map(async (person) => {
        const [seeds, listed, watchlist] = await Promise.all([
            fetchTopFilms(person.firebase_uid, seedsEach, !person.me),
            fetchListedTmdbIds(person.firebase_uid),
            fetchUnwatchedWatchlist(person.firebase_uid, !person.me),
        ]);
        return { ...person, seeds, listed, watchlist };
    }));
    const listedByAnyone = new Set(data.flatMap((person) => [...person.listed]));
    const possessive = (person) => (person.me ? "your" : `${person.name}'s`);
    const wantedGenres = new Set(genres);
    const fits = async (movie) => (!wantedGenres.size || movie.genre_ids.some((id) => wantedGenres.has(id)))
        && (!hasFilters(filters) || await matchesFilters(movie, filters));

    // Films two or more of you want to watch and haven't seen
    const onWatchlists = new Map();
    for (const person of data) {
        for (const [id, row] of person.watchlist) {
            const entry = onWatchlists.get(id) ?? { row, count: 0 };
            entry.count++;
            onWatchlists.set(id, entry);
        }
    }
    const shared = [];
    for (const [id, { row, count: wanted }] of [...onWatchlists].filter(([, e]) => e.count >= 2).sort((a, b) => b[1].count - a[1].count)) {
        const movie = toDiscoverMovie({ ...row, id, release_date: String(row.release_date ?? "").slice(0, 10), poster_path: row.poster_path || null });
        if (!movie || !(await fits(movie))) continue;
        shared.push({ ...movie, reason: wanted === people.length
            ? (people.length === 2 ? "On both your watchlists, and neither of you has seen it yet" : "On all your watchlists, and none of you has seen it yet")
            : `On ${wanted} of your watchlists` });
        if (shared.length >= 3) break;
    }

    // Which people's favourites TMDb recommends each film from
    const params = { api_key: process.env.API_KEY, language: "en-US", page: 1 };
    // Movie night is for films, so shows in people's lists don't seed it
    const seeds = data.flatMap((person, index) => person.seeds.filter((seed) => !isTV(seed.tmdb_id)).map((seed) => ({ ...seed, person: index })));
    const outcomes = await Promise.allSettled(
        seeds.map((seed) => axios.get(`https://api.themoviedb.org/3/movie/${seed.tmdb_id}/recommendations`, { params, timeout: 15000 }))
    );
    const candidates = new Map();
    outcomes.forEach((outcome, i) => {
        if (outcome.status !== "fulfilled") return;
        for (const result of outcome.value.data.results ?? []) {
            const movie = toDiscoverMovie(result);
            if (!movie || (result.vote_count ?? 0) < MOVIE_NIGHT_MIN_VOTES || listedByAnyone.has(movie.id)) continue;
            const entry = candidates.get(movie.id) ?? { movie, from: new Map() };
            if (!entry.from.has(seeds[i].person)) entry.from.set(seeds[i].person, seeds[i].title);
            candidates.set(movie.id, entry);
        }
    });
    const ranked = [...candidates.values()].sort((a, b) =>
        (b.from.size - a.from.size) || (b.movie.vote_average - a.movie.vote_average));

    const reasonFor = (entry) => {
        const sources = [...entry.from].slice(0, 3).map(([index, title]) => `${possessive(data[index])} ${title}`);
        if (sources.length === 1) {
            const [index, title] = [...entry.from][0];
            return data[index].me ? `For fans of ${title}, one of your favourites` : `For fans of ${title}, one of ${data[index].name}'s favourites`;
        }
        return `Recommended from ${sources.slice(0, -1).join(", ")} and ${sources[sources.length - 1]}`;
    };
    const perSeed = new Map();
    const picks = [];
    for (const entry of ranked) {
        if (picks.length >= count * 2) break;
        const titles = [...entry.from.values()];
        if (titles.some((title) => (perSeed.get(title) ?? 0) >= MOVIE_NIGHT_PER_SEED)) continue;
        if (!(await fits(entry.movie))) continue;
        titles.forEach((title) => perSeed.set(title, (perSeed.get(title) ?? 0) + 1));
        picks.push({ ...entry.movie, reason: reasonFor(entry) });
    }
    const seen = new Set();
    return [...shared, ...picks].filter((movie) => !seen.has(movie.id) && seen.add(movie.id)).slice(0, count);
}

// Films the user and the people coming would all enjoy. Either a saved group ({ "group_id": 3 }) or people
// the user follows ({ "handles": ["sam", "ana"] }, or the older { "handle": "sam" }), with optional
// { "mode": "classic", "languages", "providers", "provider_names", "region", "genres": [ids], "genre_names" }.
// "ai" (the default) asks the AI and needs everyone, the user included, to allow AI; "classic" uses TMDb.
// With a group and "save": true, the picks replace the group's recommendations nobody has liked (leaving out
// anything already on its shortlist or turned down by everyone), and the reply is the group's whole shortlist
router.post("/movie-night", async (req, res) => {
    try {
        const body = req.body ?? {};
        const count = Math.min(Math.max(parseInt(body.count, 10) || 10, 1), 15);
        const filters = parseFilters(body);
        const genres = parseIds(Array.isArray(body.genres) ? body.genres.join(",") : "", 20);

        // Who's coming, besides the user
        let others;
        const me = (await pool.query("SELECT firebase_uid, username AS name, ai_allowed FROM users WHERE firebase_uid = $1", [req.user.uid])).rows[0];
        if (!me) return res.status(404).json({ error: "Account not found." });
        if (Number.isInteger(body.group_id)) {
            const everyone = await groupParticipants(req.user.uid, body.group_id);
            if (!everyone) return res.status(404).json({ error: "Group not found." });
            others = everyone.filter((person) => person.firebase_uid !== req.user.uid);
        } else {
            const handles = (Array.isArray(body.handles) ? body.handles : [body.handle])
                .map((h) => cleanText(h, 40).replace(/^@/, "").toLowerCase()).filter(Boolean).slice(0, MAX_GROUP_MEMBERS);
            if (!handles.length) return res.status(400).json({ error: "Pick who's coming." });
            const followed = await followedByHandle(req.user.uid, handles);
            if (followed.length < handles.length) {
                return res.status(403).json({ error: "You can only plan a movie night with people you follow.", reason: "not_following" });
            }
            others = (await pool.query("SELECT firebase_uid, handle, username AS name, ai_allowed FROM users WHERE firebase_uid = ANY($1)", [followed.map((f) => f.firebase_uid)])).rows;
        }
        if (!others.length) return res.status(400).json({ error: "Nobody else is in this group." });
        // Everyone else goes by their @handle, like everywhere else in the app (display names can be anything,
        // even "no name" from a Google sign-in)
        const people = [{ ...me, me: true }, ...others.map((p) => ({ ...p, name: p.handle ? `@${p.handle}` : p.name, me: false }))];
        const saving = body.save === true && Number.isInteger(body.group_id);
        const history = saving ? await pickHistory(body.group_id) : { exclude: new Set(), liked: [], dismissed: [], shortlist: [] };
        // Sends the picks, or saves them to the group's shortlist and sends that
        const reply = async (movies) => {
            const fresh = movies.filter((movie) => !history.exclude.has(movie.id)).slice(0, count);
            if (!saving) return res.json(fresh);
            await saveRecommendations(body.group_id, fresh);
            res.json(await fetchPicks(req.user.uid, body.group_id));
        };

        if (body.mode === "classic") {
            return await reply(await classicMovieNight(people, count + history.exclude.size, filters, genres));
        }
        // Everyone's lists go to the AI, so everyone has to have allowed it
        if (!me.ai_allowed) {
            return res.status(403).json({ error: "Turn on AI features in Settings to use AI Picks.", reason: "ai_off_self" });
        }
        const off = others.filter((p) => !p.ai_allowed);
        if (off.length) {
            return res.status(403).json({ error: `${off.map((p) => p.name).join(", ")} ${off.length === 1 ? "hasn't" : "haven't"} turned on AI features.`, reason: "ai_off_friend" });
        }

        const data = await Promise.all(people.map(async (person) => ({
            ...person,
            lists: await fetchListsForTaste(person.firebase_uid, !person.me),
            listed: await fetchListedTmdbIds(person.firebase_uid),
        })));
        const listedByAnyone = new Set(data.flatMap((person) => [...person.listed]));
        const constraints = {
            genres: cleanStrings(body.genre_names, 20),
            languages: filters.languages,
            services: cleanStrings(body.provider_names, 20),
            region: filters.region,
            liked: history.liked,
            dismissed: history.dismissed,
            shortlist: history.shortlist,
        };
        const wanted = new Set(genres);
        // Extra picks, since some turn out to be in someone's lists, can't be found or don't fit the filters
        const picks = await recommendForGroup(req.user.uid, data.map((p) => ({ name: p.me ? "you" : p.name, lists: p.lists })),
            count + (hasFilters(filters) || wanted.size ? 12 : 5), constraints);

        const found = await mapWithConcurrency(picks, async (pick) => {
            try {
                const movie = toDiscoverMovie(await findOnTmdb(pick.title, pick.year) ?? {});
                if (!movie || (wanted.size && !movie.genre_ids.some((id) => wanted.has(id)))) return null;
                if (hasFilters(filters) && !(await matchesFilters(movie, filters))) return null;
                return { ...movie, reason: cleanText(pick.reason, 200) };
            } catch (error) {
                return null;
            }
        });
        const seen = new Set();
        const fresh = found.filter((movie) => movie && !listedByAnyone.has(movie.id) && !seen.has(movie.id) && seen.add(movie.id));
        await reply(fresh);
    } catch (error) {
        if (error instanceof AIUnavailableError) {
            return res.status(503).json({ error: "AI recommendations aren't set up." });
        }
        if (error instanceof AILimitError) {
            return res.status(429).json({ error: error.message });
        }
        console.error("Error planning movie night:", error.message);
        res.status(502).json({ error: "Movie night recommendations failed." });
    }
});

// Streaming services available in a country, most popular first, for the Discover filters, e.g. ?region=CA
router.get("/streaming-services", async (req, res) => {
    try {
        res.json(await availableServices(parseFilters(req.query).region));
    } catch (error) {
        console.error("Error fetching streaming services:", error.message);
        res.status(502).json({ error: "Couldn't load streaming services." });
    }
});

router.post("/ai-discover", async (req, res) => {
    try {
        const body = req.body ?? {};
        // Hard filters: picks in other languages or not streaming on the chosen services are dropped
        const filters = parseFilters(body);
        // Recommend from some lists only, when the user picked them (list_id is from builds that allowed one)
        const fromLists = (Array.isArray(body.list_ids) ? body.list_ids : [body.list_id]).filter(Number.isInteger).slice(0, 20);
        const signals = {
            liked: cleanFilms(body.liked, 500),
            passed: cleanFilms(body.passed, 500),
            disliked: cleanFilms(body.disliked, 500),
            favoriteGenres: cleanStrings(body.favorite_genres, 10),
            avoidedGenres: cleanStrings(body.avoided_genres, 10),
            requiredGenres: cleanStrings(body.required_genres, 20),
            ageRange: cleanText(body.age_range, 20),
            // Builds from before pronouns replaced gender still send "gender"; translate it like the app does
            pronouns: cleanText(body.pronouns ?? LEGACY_GENDER_PRONOUNS[body.gender], 30),
            region: cleanText(body.region, 10),
            language: cleanText(body.language, 10),
            swipeCount: Math.max(parseInt(body.swipe_count, 10) || 0, 0),
            likeCount: Math.max(parseInt(body.like_count, 10) || 0, 0),
            alreadySuggested: cleanStrings(body.already_suggested, 400),
            languages: filters.languages,
            services: cleanStrings(body.provider_names, 20),
        };
        const count = Math.min(Math.max(parseInt(body.count, 10) || 20, 1), 30);
        const exclude = new Set(parseIds(Array.isArray(body.exclude_ids) ? body.exclude_ids.join(",") : "", 5000));

        const [allLists, listedIds] = await Promise.all([fetchListsForTaste(req.user.uid), fetchListedTmdbIds(req.user.uid)]);
        const chosenLists = allLists.filter((list) => fromLists.includes(list.id));
        const lists = chosenLists.length ? chosenLists : allLists;
        if (chosenLists.length) signals.basedOnLists = chosenLists.map((list) => list.name);
        const streaming = req.accepts(["application/json", "application/x-ndjson"]) === "application/x-ndjson";

        // Each pick is looked up on TMDb as soon as the AI writes it, so lookups overlap with the rest of the
        // answer. Films are sent in the AI's order (it balances close matches with adventurous picks): a film
        // waits only for the lookups of the picks before it
        const lookup = createLimiter(10);
        const found = [];
        const lookups = [];
        const seen = new Set();
        const fresh = [];
        let nextToSend = 0;
        const sendReady = () => {
            while (nextToSend < found.length && found[nextToSend] !== undefined) {
                const movie = found[nextToSend++];
                if (!movie || fresh.length >= count || listedIds.has(movie.id) || exclude.has(movie.id) || seen.has(movie.id)) continue;
                seen.add(movie.id);
                fresh.push(movie);
                if (streaming) {
                    if (!res.headersSent) {
                        res.status(200).set({ "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache" });
                    }
                    res.write(JSON.stringify(movie) + "\n");
                }
            }
        };

        // Ask for a few extra, since some picks turn out to be films the user already has or can't be found, and
        // more with filters, since some won't actually be in that language or on those services
        await recommendFilms(req.user.uid, lists, signals, count + (hasFilters(filters) ? 20 : 10), (pick) => {
            const index = found.push(undefined) - 1;
            lookups.push(lookup(async () => {
                try {
                    const movie = toDiscoverMovie(await findOnTmdb(pick.title, pick.year) ?? {});
                    const fits = movie && (!hasFilters(filters) || await matchesFilters(movie, filters));
                    found[index] = fits ? { ...movie, reason: cleanText(pick.reason, 200) } : null;
                } catch (error) {
                    found[index] = null;
                }
                sendReady();
            }));
        });
        await Promise.all(lookups);

        if (!streaming) {
            return res.json(fresh);
        }
        if (!res.headersSent) {
            res.status(200).set({ "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache" });
        }
        res.end();
    } catch (error) {
        // Once films have been streamed the status is already sent, so just end the stream
        if (res.headersSent) {
            console.error("AI recommendations failed partway:", error.message);
            return res.end();
        }
        if (error instanceof AIUnavailableError) {
            return res.status(503).json({ error: "AI recommendations aren't set up." });
        }
        if (error instanceof AILimitError) {
            return res.status(429).json({ error: error.message });
        }
        console.error("Error fetching AI recommendations:", error.message);
        res.status(502).json({ error: "AI recommendations failed." });
    }
});

router.post("/create", async (req, res) => {
    try {
        const { tmdb_id, title, release_date, overview, poster_path, original_language, popularity } = req.body;
        console.log(req.body)
        if (!tmdb_id || !title) {
            return res.status(400).json({ error: "tmdb ID and title are required." });
        }
        const newMovie = await createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity);
        res.status(201).json(newMovie);
    } catch (error) {
        console.error("Error creating movie:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Smart Placement: asks the AI where a film already in the user's list belongs, moves it there and marks it as
// placed by AI, e.g. { "list_id": 3, "movie_id": 120 } -> { rank, reason }. Needs the user to allow AI
router.post("/smart-place", editsBodyList, async (req, res) => {
    try {
        const listId = Number(req.body.list_id), movieId = Number(req.body.movie_id);
        if (!Number.isInteger(listId) || !Number.isInteger(movieId)) {
            return res.status(400).json({ error: "list_id and movie_id are required." });
        }
        const allowed = await pool.query("SELECT ai_allowed FROM users WHERE firebase_uid = $1", [req.user.uid]);
        if (!allowed.rows[0]?.ai_allowed) {
            return res.status(403).json({ error: "Allow AI features in Settings to use Smart Placement." });
        }
        const ranked = await pool.query("SELECT is_ranked FROM lists WHERE id = $1", [listId]);
        if (ranked.rows[0]?.is_ranked === false) {
            return res.status(400).json({ error: "This list is unranked, so films just go at the end." });
        }
        const rows = (await pool.query(
            `SELECT l.name, lm.movie_id, lm.rank, m.title, m.release_date
             FROM lists l JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
             WHERE l.id = $1 ORDER BY lm.rank`,
            [listId]
        )).rows;
        const film = rows.find((row) => row.movie_id === movieId);
        if (!film) return res.status(404).json({ error: "That film isn't in this list." });
        const others = rows.filter((row) => row.movie_id !== movieId)
            .map((row) => ({ title: row.title, year: String(row.release_date ?? "").slice(0, 4) }));
        const { rank, reason } = await placeInList(req.user.uid, film.name, others,
            { title: film.title, year: String(film.release_date ?? "").slice(0, 4) });
        await updateMovieRank(listId, movieId, rank, true);
        res.json({ rank, reason });
    } catch (error) {
        if (error instanceof AIUnavailableError) {
            return res.status(503).json({ error: "Smart Placement isn't set up." });
        }
        if (error instanceof AILimitError) {
            return res.status(429).json({ error: error.message });
        }
        console.error("Error placing film:", error.message);
        res.status(502).json({ error: "Smart Placement failed." });
    }
});

// Keeps a Smart Placement spot as if the user had chosen it, clearing its AI mark
router.put("/approve-placement", editsBodyList, async (req, res) => {
    try {
        const result = await pool.query(
            "UPDATE list_movies SET ai_placed = false WHERE list_id = $1 AND movie_id = $2",
            [Number(req.body.list_id), Number(req.body.movie_id)]
        );
        if (!result.rowCount) return res.status(404).json({ error: "That film isn't in this list." });
        res.json({ approved: true });
    } catch (error) {
        console.error("Error approving placement:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.put("/updateRank", editsBodyList, async (req, res) => {
    try {
        const { list_id, movie_id, rank } = req.body;
        const updatedMovie = await updateMovieRank(list_id, movie_id, rank);
        res.status(200).json(updatedMovie);
    } catch (error) {
        console.error("Error updating movie rank:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});
// US age rating ("G", "PG-13", "R", ...) from TMDb's release dates, preferring the theatrical release.
// Empty when the film was never rated in the US
function usCertification(releaseDates) {
    const us = (releaseDates?.results ?? []).find((country) => country.iso_3166_1 === "US");
    const rated = (us?.release_dates ?? []).filter((release) => release.certification?.trim());
    const theatrical = rated.find((release) => release.type === 3) ?? rated[0];
    return theatrical?.certification.trim() ?? "";
}

// Genres, US age rating, TMDb user score and length for up to 50 TMDb films at a time, e.g. ?ids=771 ->
// [{ id: 771, genre_ids: [35, 10751], certification: "PG", vote_average: 7.4, vote_count: 11000, runtime: 103,
// seasons: 0, episodes: 0 }]. runtime is in minutes (a show's typical episode), 0 when TMDb doesn't know it.
// Read-only: the app caches these to label films and filter its lists by genre. Films TMDb can't find are left out
router.get("/info", async (req, res) => {
    try {
        const ids = parseMediaIds(req.query.ids, 50);
        const films = await mapWithConcurrency(ids, async (id) => {
            try {
                const response = await axios.get(`https://api.themoviedb.org/3/${tmdbPath(id)}`, {
                    params: { api_key: process.env.API_KEY, append_to_response: isTV(id) ? "content_ratings" : "release_dates" },
                    timeout: 15000,
                });
                const film = response.data;
                const genreIds = (film.genres ?? []).map((genre) => genre.id);
                return {
                    id,
                    genre_ids: isTV(id) ? filmGenres(genreIds) : genreIds,
                    // Shows have TV ratings ("TV-MA", "TV-14") rather than film ones
                    certification: isTV(id)
                        ? ((film.content_ratings?.results ?? []).find((rating) => rating.iso_3166_1 === "US")?.rating ?? "")
                        : usCertification(film.release_dates),
                    vote_average: film.vote_average ?? 0,
                    vote_count: film.vote_count ?? 0,
                    runtime: (isTV(id) ? film.episode_run_time?.[0] ?? film.last_episode_to_air?.runtime : film.runtime) || 0,
                    seasons: film.number_of_seasons ?? 0,
                    episodes: film.number_of_episodes ?? 0,
                };
            } catch (error) {
                return null;
            }
        });
        res.json(films.filter(Boolean));
    } catch (error) {
        console.error("Error fetching film info:", error.message);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The IMDb id for a TMDb film, e.g. ?tmdb_id=771 -> { tmdb_id: 771, imdb_id: "tt0099785" }.
// imdb_id is null when TMDb doesn't know it
router.get("/imdb", async (req, res) => {
    const tmdbId = mediaId(req.query.tmdb_id);
    if (tmdbId === null) {
        return res.status(400).json({ error: "A tmdb_id is required." });
    }
    try {
        const response = await axios.get(`https://api.themoviedb.org/3/${tmdbPath(tmdbId)}/external_ids`, {
            params: { api_key: process.env.API_KEY },
            timeout: 15000,
        });
        res.json({ tmdb_id: tmdbId, imdb_id: response.data.imdb_id || null });
    } catch (error) {
        if (error.response?.status === 404) {
            return res.json({ tmdb_id: tmdbId, imdb_id: null });
        }
        console.error("Error fetching IMDb id:", error.message);
        res.status(500).json({ error: "Internal server error" });
    }
});

// A film's trailer on YouTube, from TMDb's videos, e.g. ?tmdb_id=27205 -> { key: "YoHD9XEInc0", name: "Official Trailer" },
// or { key: null } when it has none. It looks for the film's main trailer: official trailers over teasers and TV
// spots, ones named like a main trailer, and nothing that's a re-release, dub or home-video ad. The oldest wins
// ties, since a film's first full trailer is usually its main one and later uploads tend to be variants
const trailerCache = new Map();

router.get("/trailer", async (req, res) => {
    const tmdbId = mediaId(req.query.tmdb_id);
    if (tmdbId === null) {
        return res.status(400).json({ error: "A tmdb_id is required." });
    }
    const cached = trailerCache.get(tmdbId);
    if (cached && Date.now() - cached.at < 24 * 60 * 60 * 1000) return res.json(cached.trailer);
    try {
        const response = await axios.get(`https://api.themoviedb.org/3/${tmdbPath(tmdbId)}/videos`, {
            // English videos plus ones with no language, which TMDb leaves out unless asked
            params: { api_key: process.env.API_KEY, include_video_language: "en,null" },
            timeout: 15000,
        });
        const variant = /version|b&w|dubbed|blu-?ray|dvd|digital|on demand|re-?release|anniversary|4k|35mm|tv spot|now playing|own it/i;
        const main = /main trailer|^(official )?((us|international|int'l) )?trailer( \[[^\]]*\])?$/i;
        const score = (video) => (video.type === "Trailer" ? 4 : 0) + (video.official ? 2 : 0) + (video.iso_639_1 === "en" ? 1 : 0)
            + (main.test(video.name ?? "") ? 2 : 0) - (/teaser/i.test(video.name ?? "") ? 1 : 0) - (variant.test(video.name ?? "") ? 5 : 0);
        const best = (response.data.results ?? [])
            .filter((video) => video.site === "YouTube" && video.key && (video.type === "Trailer" || video.type === "Teaser"))
            .sort((a, b) => score(b) - score(a) || String(a.published_at).localeCompare(String(b.published_at)))[0];
        const trailer = best ? { key: best.key, name: best.name } : { key: null, name: null };
        trailerCache.set(tmdbId, { at: Date.now(), trailer });
        res.json(trailer);
    } catch (error) {
        if (error.response?.status === 404) return res.json({ key: null, name: null });
        console.error("Error fetching trailer:", error.message);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Where a film can be watched in one country, from TMDb (availability data by JustWatch), e.g.
// ?tmdb_id=771&region=CA -> { region: "CA", link, stream: [{ id, name, logo_path }], free: [...], rent: [...], buy: [...] }.
// Each group is in TMDb's display order; link is TMDb's watch page for the film. All empty when it isn't available there
router.get("/providers", async (req, res) => {
    const tmdbId = mediaId(req.query.tmdb_id);
    const region = String(req.query.region ?? "US").toUpperCase();
    if (tmdbId === null) {
        return res.status(400).json({ error: "A tmdb_id is required." });
    }
    if (!/^[A-Z]{2}$/.test(region)) {
        return res.status(400).json({ error: "region must be a two-letter country code." });
    }
    const providers = (items) => {
        const seen = new Set();
        return (items ?? [])
            .sort((a, b) => (a.display_priority ?? 0) - (b.display_priority ?? 0))
            .filter((item) => !seen.has(item.provider_id) && seen.add(item.provider_id))
            .map((item) => ({ id: item.provider_id, name: item.provider_name, logo_path: item.logo_path ?? null }));
    };
    try {
        const response = await axios.get(`https://api.themoviedb.org/3/${tmdbPath(tmdbId)}/watch/providers`, {
            params: { api_key: process.env.API_KEY },
            timeout: 15000,
        });
        const country = response.data.results?.[region] ?? {};
        res.json({
            region,
            link: country.link ?? null,
            stream: providers(country.flatrate),
            // Free with or without ads, e.g. Tubi or Pluto TV
            free: providers([...(country.free ?? []), ...(country.ads ?? [])]),
            rent: providers(country.rent),
            buy: providers(country.buy),
        });
    } catch (error) {
        if (error.response?.status === 404) {
            return res.json({ region, link: null, stream: [], free: [], rent: [], buy: [] });
        }
        console.error("Error fetching watch providers:", error.message);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Marks a film watched or unwatched for the signed-in user, in every list it appears in
router.put("/watched", async (req, res) => {
    try {
        const movieId = Number(req.body.movie_id);
        if (!Number.isInteger(movieId) || typeof req.body.watched !== "boolean") {
            return res.status(400).json({ error: "movie_id and a true/false watched are required." });
        }
        await setMovieWatched(req.user.uid, movieId, req.body.watched);
        res.status(200).json({ movie_id: movieId, watched: req.body.watched });
    } catch (error) {
        // 23503: the film doesn't exist
        if (error.code === "23503") {
            return res.status(404).json({ error: "Movie not found." });
        }
        console.error("Error updating watched status:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The signed-in user's watches, newest first; ?movie_id= limits it to one film
router.get("/diary", async (req, res) => {
    try {
        const movieId = req.query.movie_id === undefined ? null : Number(req.query.movie_id);
        if (movieId !== null && !Number.isInteger(movieId)) {
            return res.status(400).json({ error: "movie_id must be a number." });
        }
        res.json(await fetchDiary(req.user.uid, movieId));
    } catch (error) {
        console.error("Error fetching diary:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Logs a watch of a film, e.g. { "movie_id": 12, "watched_on": "2026-10-18" } (defaults to today).
// The first watch marks the film watched; later ones are rewatches
router.post("/watch", async (req, res) => {
    try {
        const movieId = Number(req.body.movie_id);
        const day = req.body.watched_on ?? new Date().toISOString().slice(0, 10);
        if (!Number.isInteger(movieId) || !/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(Date.parse(day))) {
            return res.status(400).json({ error: "movie_id and a YYYY-MM-DD watched_on are required." });
        }
        const kind = await logWatch(req.user.uid, movieId, day);
        res.status(201).json({ movie_id: movieId, watched_on: day, kind });
    } catch (error) {
        if (error.code === "23503") {
            return res.status(404).json({ error: "Movie not found." });
        }
        console.error("Error logging watch:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Removes one rewatch from the diary
router.delete("/watch/:id", async (req, res) => {
    try {
        const id = Number(req.params.id);
        if (!Number.isInteger(id)) {
            return res.status(400).json({ error: "A rewatch id is required." });
        }
        if (!(await deleteRewatch(req.user.uid, id))) {
            return res.status(404).json({ error: "Rewatch not found." });
        }
        res.status(204).end();
    } catch (error) {
        console.error("Error deleting rewatch:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Saves the signed-in user's note on a film, e.g. { "movie_id": 12, "note": "Rewatch with Sam" }.
// An empty note deletes it
router.put("/note", async (req, res) => {
    try {
        const movieId = Number(req.body.movie_id);
        const { note } = req.body;
        if (!Number.isInteger(movieId) || typeof note !== "string") {
            return res.status(400).json({ error: "movie_id and a note are required." });
        }
        if (note.length > 5000) {
            return res.status(400).json({ error: "A note can be at most 5000 characters." });
        }
        await setMovieNote(req.user.uid, movieId, note);
        res.status(200).json({ movie_id: movieId, note: note.trim() ? note : null });
    } catch (error) {
        // 23503: the film doesn't exist
        if (error.code === "23503") {
            return res.status(404).json({ error: "Movie not found." });
        }
        console.error("Error saving note:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/removeFromList/:list_id/:movie_id", requireListOwner.requireListEditor((req) => req.params.list_id), async (req, res) => {
    try {
        const { list_id, movie_id } = req.params;
        const removedMovie = await removeMovieFromList(list_id, movie_id);
        res.status(200).json(removedMovie);
    } catch (error) {
        console.error("Error removing movie from list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.post("/addToList", editsBodyList, async (req, res) => {
    try {
        const { list_id, movie_id, rank } = req.body;
        const newMovie = await addMovieToList(list_id, movie_id, rank, req.user.uid);
        res.status(201).json(newMovie);
    } catch (error) {
        console.error("Error adding movie to list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;