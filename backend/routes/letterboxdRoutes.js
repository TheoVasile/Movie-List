const express = require("express");
const { resolveFilms, mapWithConcurrency } = require("../services/letterboxdService");
const { createList, deleteList } = require("../models/listModel");
const { createMovie, addMovieToList } = require("../models/movieModel");
const { blockedField } = require("../services/moderation");

// What a list is called instead when moderation doesn't allow its name
const NEUTRAL_NAME = "Imported list";

const router = express.Router();

// Takes lists parsed from a Letterboxd data export and copies each into a new ranked list,
// keeping Letterboxd's order as the ranking. A name or description moderation doesn't allow is replaced (with
// "Imported list", or nothing), and the list's renamed_from_blocked says so for the import summary
router.post("/import", async (req, res) => {
    const user_id = req.user.uid;
    const { lists } = req.body;
    if (!Array.isArray(lists) || lists.length === 0) {
        return res.status(400).json({ error: "At least one list is required." });
    }

    const imported = [];
    try {
        for (const letterboxdList of lists) {
            const films = (letterboxdList.films ?? []).filter((film) => film.name);
            const { movies, skipped } = await resolveFilms(films);

            // The same TMDb movie can be matched twice, e.g. a remake listed alongside its original
            const uniqueMovies = movies.filter((movie, i) => movies.findIndex((m) => m.id === movie.id) === i);

            const name = (letterboxdList.name || "Letterboxd List").slice(0, 100);
            const overview = letterboxdList.overview ?? "";
            const nameBlocked = Boolean(blockedField({ list_name: name }));
            const list = await createList(user_id, nameBlocked ? NEUTRAL_NAME : name,
                blockedField({ list_description: overview }) ? "" : overview, true);
            try {
                list.movies = await mapWithConcurrency(uniqueMovies, async (tmdbMovie, index) => {
                    const movie = await createMovie(
                        tmdbMovie.id,
                        tmdbMovie.title,
                        tmdbMovie.release_date ?? "",
                        tmdbMovie.overview ?? "",
                        tmdbMovie.poster_path ?? "",
                        tmdbMovie.original_language ?? "",
                        tmdbMovie.popularity ?? 0
                    );
                    await addMovieToList(list.id, movie.id, index + 1);
                    return { ...movie, poster_path: movie.poster_path ?? "", rank: index + 1 };
                });
            } catch (error) {
                await deleteList(list.id);
                throw error;
            }

            list.skipped = skipped;
            list.renamed_from_blocked = nameBlocked;
            imported.push(list);
        }
        res.status(201).json(imported);
    } catch (error) {
        console.error("Error importing Letterboxd lists:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;
