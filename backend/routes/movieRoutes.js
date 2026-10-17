const express = require("express");
const axios = require("axios");
const { createMovie, addMovieToList, removeMovieFromList, updateMovieRank } = require("../models/movieModel");

const router = express.Router();

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

router.put("/updateRank", async (req, res) => {
    try {
        const { list_id, movie_id, rank } = req.body;
        const updatedMovie = await updateMovieRank(list_id, movie_id, rank);
        res.status(200).json(updatedMovie);
    } catch (error) {
        console.error("Error updating movie rank:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});
router.delete("/removeFromList/:list_id/:movie_id", async (req, res) => {
    try {
        const { list_id, movie_id } = req.params;
        const removedMovie = await removeMovieFromList(list_id, movie_id);
        res.status(200).json(removedMovie);
    } catch (error) {
        console.error("Error removing movie from list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.post("/addToList", async (req, res) => {
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