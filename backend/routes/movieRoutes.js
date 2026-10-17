const express = require("express");
const axios = require("axios");
const { createMovie, addMovieToList, removeMovieFromList, updateMovieRank } = require("../models/movieModel");

const requireListOwner = require("../middleware/listOwnership");
const { setMovieWatched } = require("../models/watchedModel");
const { mapWithConcurrency } = require("../services/letterboxdService");

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
// genres out of the genre feed. The app filters out films already in a list and orders by taste
router.get("/discover", async (req, res) => {
    try {
        const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
        const seeds = parseIds(req.query.seeds, 8);
        const genres = parseIds(req.query.genres, 3);
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
        const movies = [...interleaved, ...resultsOf(trending)]
            .map(toDiscoverMovie)
            .filter((movie) => movie && !seen.has(movie.id) && seen.add(movie.id));

        res.json(movies);
    } catch (error) {
        console.error("Error fetching discover movies:", error.message);
        res.status(500).json({ error: "Internal server error" });
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