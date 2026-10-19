const express = require("express");
const axios = require("axios");
const { setMovieNote } = require("../models/notesModel");
const { createMovie, addMovieToList, removeMovieFromList, updateMovieRank } = require("../models/movieModel");

const requireListOwner = require("../middleware/listOwnership");
const { setMovieWatched, logWatch, deleteRewatch, fetchDiary } = require("../models/watchedModel");
const { mapWithConcurrency, createLimiter } = require("../services/letterboxdService");
const { fetchListsForTaste, fetchListedTmdbIds, fetchFriend, fetchTopFilms, fetchUnwatchedWatchlist } = require("../models/tasteModel");
const { recommendFilms, recommendForTwo, AIUnavailableError, AILimitError } = require("../services/aiDiscoverService");

const router = express.Router();
const ownsBodyList = requireListOwner((req) => req.body.list_id);

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

        const url = `https://api.themoviedb.org/3/search/movie`;
        const params = {
            query: name,
            include_adult: false,
            language: "en-US",
            api_key: API_KEY,
        };

        // Two pages, since the film being looked for can sit past TMDb's first 20 results
        console.log("📡 Fetching movies from TMDb...");
        const pages = await Promise.all([1, 2].map((page) => axios.get(url, { params: { ...params, page } })));
        const seen = new Set();
        const movies = pages
            .flatMap((response) => response.data.results)
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

// Films for the Discover tab: TMDb recommendations for the given films (seeds: the user's top-ranked
// and recently liked films) plus well-rated films in their favourite genres (genres), interleaved so
// no single source dominates, followed by this week's trending films. avoid_genres keeps disliked
// genres out of the genre feed. only_genres=1 means the user picked these genres themselves: then every
// film returned has at least one of them. The app filters out films already in a list and orders by taste
router.get("/discover", async (req, res) => {
    try {
        const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
        const seeds = parseIds(req.query.seeds, 8);
        const onlyGenres = req.query.only_genres === "1";
        const genres = parseIds(req.query.genres, onlyGenres ? 20 : 3);
        const avoidGenres = parseIds(req.query.avoid_genres, 3);
        const params = { api_key: process.env.API_KEY, language: "en-US", page };

        // Films in any of the favourite genres ("|" means or), skipping obscure titles
        const genreFeed = genres.length
            ? [axios.get("https://api.themoviedb.org/3/discover/movie", {
                params: {
                    ...params,
                    with_genres: genres.join("|"),
                    without_genres: avoidGenres.join(","),
                    sort_by: "popularity.desc",
                    "vote_count.gte": 200,
                    include_adult: false,
                },
            })]
            : [];

        // allSettled so one seed TMDb doesn't know about can't fail the whole request
        const [trending, ...recommendations] = await Promise.allSettled([
            axios.get("https://api.themoviedb.org/3/trending/movie/week", { params }),
            // The app sends different seeds for every batch, so each seed's best (first page) recommendations are used
            ...seeds.map((id) => axios.get(`https://api.themoviedb.org/3/movie/${id}/recommendations`, { params: { ...params, page: 1 } })),
            ...genreFeed,
        ]);
        const resultsOf = (outcome) => (outcome.status === "fulfilled" ? outcome.value.data.results : []);

        const recommendationLists = recommendations.map(resultsOf);
        const interleaved = [];
        for (let i = 0; i < Math.max(0, ...recommendationLists.map((list) => list.length)); i++) {
            recommendationLists.forEach((list) => list[i] && interleaved.push(list[i]));
        }

        const seen = new Set(seeds);
        const wanted = new Set(genres);
        const movies = [...interleaved, ...resultsOf(trending)]
            .map(toDiscoverMovie)
            .filter((movie) => movie && !seen.has(movie.id) && seen.add(movie.id))
            .filter((movie) => !onlyGenres || movie.genre_ids.some((id) => wanted.has(id)));

        res.json(movies);
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

// Films for the Discover tab chosen by Claude from everything in the user's lists, plus their Discover
// swipes and anything they chose to share (age range, pronouns) for when their lists are empty.
// Answers 503 when AI isn't set up and 429 at the daily limit, so the app can fall back to /discover.
// With "Accept: application/x-ndjson" the films stream back one JSON object per line as Claude picks them,
// so the first card shows in seconds; otherwise (builds from before streaming) they come as one array
// How many of each person's favourites seed Classic movie night picks, how many picks can come from any one
// favourite (so one shared love doesn't fill the list), and how many TMDb votes a pick needs
const MOVIE_NIGHT_SEEDS = 6;
const MOVIE_NIGHT_PER_SEED = 2;
const MOVIE_NIGHT_MIN_VOTES = 100;

/// Movie night picks without AI: films on both people's watchlists first, then films TMDb recommends from
/// both people's favourites, preferring ones recommended from each side, each with a reason naming the
/// favourites it came from. Returns [{ ...discover movie, reason }]
async function classicMovieNight(user_id, friend, friendName, count) {
    const [mySeeds, friendSeeds, myIds, friendIds, myWatchlist, friendWatchlist] = await Promise.all([
        fetchTopFilms(user_id, MOVIE_NIGHT_SEEDS),
        fetchTopFilms(friend.firebase_uid, MOVIE_NIGHT_SEEDS),
        fetchListedTmdbIds(user_id),
        fetchListedTmdbIds(friend.firebase_uid),
        fetchUnwatchedWatchlist(user_id),
        fetchUnwatchedWatchlist(friend.firebase_uid),
    ]);

    // Films you both want to watch
    const shared = [...myWatchlist.keys()].filter((id) => friendWatchlist.has(id)).slice(0, 3).map((id) => {
        const row = myWatchlist.get(id);
        return {
            ...toDiscoverMovie({ ...row, id, release_date: String(row.release_date ?? "").slice(0, 10), poster_path: row.poster_path || null }),
            reason: `On both your watchlists, and neither of you has seen it yet`,
        };
    }).filter((movie) => movie.id);

    // Which of each person's favourites TMDb recommends each film from
    const params = { api_key: process.env.API_KEY, language: "en-US", page: 1 };
    const seeds = [...mySeeds.map((seed) => ({ ...seed, mine: true })), ...friendSeeds.map((seed) => ({ ...seed, mine: false }))];
    const outcomes = await Promise.allSettled(
        seeds.map((seed) => axios.get(`https://api.themoviedb.org/3/movie/${seed.tmdb_id}/recommendations`, { params, timeout: 15000 }))
    );
    const candidates = new Map();
    outcomes.forEach((outcome, i) => {
        if (outcome.status !== "fulfilled") return;
        for (const result of outcome.value.data.results ?? []) {
            const movie = toDiscoverMovie(result);
            if (!movie || (result.vote_count ?? 0) < MOVIE_NIGHT_MIN_VOTES || myIds.has(movie.id) || friendIds.has(movie.id)) continue;
            const entry = candidates.get(movie.id) ?? { movie, mine: [], theirs: [] };
            (seeds[i].mine ? entry.mine : entry.theirs).push(seeds[i].title);
            candidates.set(movie.id, entry);
        }
    });

    const score = (entry) => (entry.mine.length && entry.theirs.length ? 100 : 0) + (entry.mine.length + entry.theirs.length) * 10 + entry.movie.vote_average;
    const ranked = [...candidates.values()].sort((a, b) => score(b) - score(a));
    // Too few films come from both sides, so the rest alternate between each person's favourites
    const both = ranked.filter((entry) => entry.mine.length && entry.theirs.length);
    const mineOnly = ranked.filter((entry) => !entry.theirs.length);
    const theirsOnly = ranked.filter((entry) => !entry.mine.length);
    const ordered = [...both];
    for (let i = 0; i < Math.max(mineOnly.length, theirsOnly.length); i++) {
        if (theirsOnly[i]) ordered.push(theirsOnly[i]);
        if (mineOnly[i]) ordered.push(mineOnly[i]);
    }

    const reasonFor = (entry) => entry.mine.length && entry.theirs.length
        ? `Recommended from your ${entry.mine[0]} and ${friendName}'s ${entry.theirs[0]}`
        : entry.mine.length
            ? `For fans of ${entry.mine[0]}, one of your favourites`
            : `For fans of ${entry.theirs[0]}, one of ${friendName}'s favourites`;
    // Each favourite leads to at most a couple of picks, so the list covers more of both people's tastes
    const perSeed = new Map();
    const picks = [];
    for (const entry of ordered) {
        const sources = [...entry.mine.slice(0, 1), ...entry.theirs.slice(0, 1)];
        if (sources.some((title) => (perSeed.get(title) ?? 0) >= MOVIE_NIGHT_PER_SEED)) continue;
        sources.forEach((title) => perSeed.set(title, (perSeed.get(title) ?? 0) + 1));
        picks.push({ ...entry.movie, reason: reasonFor(entry) });
    }
    const seen = new Set();
    return [...shared, ...picks].filter((movie) => !seen.has(movie.id) && seen.add(movie.id)).slice(0, count);
}

// Films the signed-in user and a friend they follow would both enjoy, e.g. { "handle": "sam", "count": 10,
// "mode": "ai" } -> [{ ...discover movie, reason }]. "ai" (the default) asks Claude and needs both people to allow
// AI; "classic" uses TMDb's recommendations from both people's favourites and needs nothing more than following
router.post("/movie-night", async (req, res) => {
    try {
        const handle = cleanText(req.body?.handle, 40).replace(/^@/, "").toLowerCase();
        if (!handle) {
            return res.status(400).json({ error: "A friend's @username is required." });
        }
        const count = Math.min(Math.max(parseInt(req.body?.count, 10) || 10, 1), 15);
        const friend = await fetchFriend(req.user.uid, handle);
        if (!friend || friend.firebase_uid === req.user.uid) {
            return res.status(404).json({ error: "User not found." });
        }
        if (!friend.following) {
            return res.status(403).json({ error: "Follow them to plan a movie night together.", reason: "not_following" });
        }
        const friendName = friend.display_name || `@${friend.handle}`;
        if (req.body?.mode === "classic") {
            return res.json(await classicMovieNight(req.user.uid, friend, friendName, count));
        }
        // Both people's lists go to the AI, so both have to have allowed it
        if (!friend.my_ai_allowed) {
            return res.status(403).json({ error: "Turn on AI features in Settings to plan a movie night.", reason: "ai_off_self" });
        }
        if (!friend.ai_allowed) {
            return res.status(403).json({ error: "They haven't turned on AI features.", reason: "ai_off_friend" });
        }

        const [myLists, friendLists, myIds, friendIds] = await Promise.all([
            fetchListsForTaste(req.user.uid),
            fetchListsForTaste(friend.firebase_uid),
            fetchListedTmdbIds(req.user.uid),
            fetchListedTmdbIds(friend.firebase_uid),
        ]);
        // A few extra, since some picks turn out to be in someone's lists or can't be found
        const picks = await recommendForTwo(req.user.uid, myLists, friendLists, friendName, count + 5);

        const found = await mapWithConcurrency(picks, async (pick) => {
            try {
                const movie = toDiscoverMovie(await findOnTmdb(pick.title, pick.year) ?? {});
                return movie && { ...movie, reason: cleanText(pick.reason, 200) };
            } catch (error) {
                return null;
            }
        });
        const seen = new Set();
        const fresh = found.filter((movie) => movie && !myIds.has(movie.id) && !friendIds.has(movie.id) && !seen.has(movie.id) && seen.add(movie.id));
        res.json(fresh.slice(0, count));
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

router.post("/ai-discover", async (req, res) => {
    try {
        const body = req.body ?? {};
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
        };
        const count = Math.min(Math.max(parseInt(body.count, 10) || 20, 1), 30);
        const exclude = new Set(parseIds(Array.isArray(body.exclude_ids) ? body.exclude_ids.join(",") : "", 5000));

        const [lists, listedIds] = await Promise.all([fetchListsForTaste(req.user.uid), fetchListedTmdbIds(req.user.uid)]);
        const streaming = req.accepts(["application/json", "application/x-ndjson"]) === "application/x-ndjson";

        // Each pick is looked up on TMDb as soon as Claude writes it, so lookups overlap with the rest of the
        // answer. Films are sent in Claude's order (it balances close matches with adventurous picks): a film
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

        // Ask for a few extra, since some picks turn out to be films the user already has or can't be found
        await recommendFilms(req.user.uid, lists, signals, count + 10, (pick) => {
            const index = found.push(undefined) - 1;
            lookups.push(lookup(async () => {
                try {
                    const movie = toDiscoverMovie(await findOnTmdb(pick.title, pick.year) ?? {});
                    found[index] = movie && { ...movie, reason: cleanText(pick.reason, 200) };
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

router.put("/updateRank", ownsBodyList, async (req, res) => {
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

// Genres, US age rating and TMDb user score for up to 50 TMDb films at a time, e.g. ?ids=771 ->
// [{ id: 771, genre_ids: [35, 10751], certification: "PG", vote_average: 7.4, vote_count: 11000 }].
// Read-only: the app caches these to label films and filter its lists by genre. Films TMDb can't find are left out
router.get("/info", async (req, res) => {
    try {
        const ids = parseIds(req.query.ids, 50);
        const films = await mapWithConcurrency(ids, async (id) => {
            try {
                const response = await axios.get(`https://api.themoviedb.org/3/movie/${id}`, {
                    params: { api_key: process.env.API_KEY, append_to_response: "release_dates" },
                    timeout: 15000,
                });
                const film = response.data;
                return {
                    id,
                    genre_ids: (film.genres ?? []).map((genre) => genre.id),
                    certification: usCertification(film.release_dates),
                    vote_average: film.vote_average ?? 0,
                    vote_count: film.vote_count ?? 0,
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
    const tmdbId = Number(req.query.tmdb_id);
    if (!Number.isInteger(tmdbId) || tmdbId <= 0) {
        return res.status(400).json({ error: "A tmdb_id is required." });
    }
    try {
        const response = await axios.get(`https://api.themoviedb.org/3/movie/${tmdbId}/external_ids`, {
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

// Where a film can be watched in one country, from TMDb (availability data by JustWatch), e.g.
// ?tmdb_id=771&region=CA -> { region: "CA", link, stream: [{ id, name, logo_path }], free: [...], rent: [...], buy: [...] }.
// Each group is in TMDb's display order; link is TMDb's watch page for the film. All empty when it isn't available there
router.get("/providers", async (req, res) => {
    const tmdbId = Number(req.query.tmdb_id);
    const region = String(req.query.region ?? "US").toUpperCase();
    if (!Number.isInteger(tmdbId) || tmdbId <= 0) {
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
        const response = await axios.get(`https://api.themoviedb.org/3/movie/${tmdbId}/watch/providers`, {
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

router.delete("/removeFromList/:list_id/:movie_id", requireListOwner((req) => req.params.list_id), async (req, res) => {
    try {
        const { list_id, movie_id } = req.params;
        const removedMovie = await removeMovieFromList(list_id, movie_id);
        res.status(200).json(removedMovie);
    } catch (error) {
        console.error("Error removing movie from list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.post("/addToList", ownsBodyList, async (req, res) => {
    try {
        const { list_id, movie_id, rank } = req.body;
        const newMovie = await addMovieToList(list_id, movie_id, rank);
        res.status(201).json(newMovie);
    } catch (error) {
        console.error("Error adding movie to list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;