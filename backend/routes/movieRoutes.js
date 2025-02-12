const express = require("express");
const axios = require("axios");
const { createMovie, addMovieToList, removeMovieFromList, updateMovieRank } = require("../models/movieModel");

const router = express.Router();

router.get("/search", async (req, res) => {
    try {
        const API_KEY = process.env.API_KEY;
        const { name } = req.query;
        if (!name) {
            return res.status(400).json({ error: "Movie name is required" });
        }

        const url = `https://api.themoviedb.org/3/search/movie`;

        // 🔹 Query Parameters
        const params = {
            query: name,
            include_adult: false,
            language: "en-US",
            page: 1,
            api_key: API_KEY,
        };

        console.log("📡 Fetching movies from TMDb...");
        const response = await axios.get(url, { params });

        // 🔹 Sort by popularity (like Swift code)
        const sortedMovies = response.data.results.sort((a, b) => b.popularity - a.popularity);

        console.log("✅ Movies fetched successfully!");
        res.json(sortedMovies);
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