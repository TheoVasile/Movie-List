const express = require("express");
const pool = require("../config/db");
const { matchFilms, describeFilm, mapWithConcurrency } = require("../services/letterboxdService");
const { MAX_BATCH, cleanFilms } = require("../services/spreadsheetImport");
const { createList, deleteList, canEditList } = require("../models/listModel");
const { createMovie, addMovieToList } = require("../models/movieModel");
const { setMovieWatched, markWatchedOn } = require("../models/watchedModel");
const { setMovieNote, fetchNotes } = require("../models/notesModel");
const { isPrivate } = require("../models/socialModel");

const router = express.Router();

// Adds one batch of films read from a spreadsheet (Excel or CSV) to the bottom of a list, in the sheet's order.
// The first batch passes a name to make a new list; later batches, or imports into an existing list, pass its
// list_id. Films are matched on TMDb the same way as Letterboxd imports, and films already in the list are left
// where they are. Watched dates and notes from the sheet are saved too, without overwriting ones the user has
router.post("/films", async (req, res) => {
    const user_id = req.user.uid;
    const { list_id, name } = req.body;
    if (!Array.isArray(req.body.films) || req.body.films.length === 0 || req.body.films.length > MAX_BATCH) {
        return res.status(400).json({ error: `Between 1 and ${MAX_BATCH} films are required.` });
    }
    if (list_id === undefined && !(typeof name === "string" && name.trim())) {
        return res.status(400).json({ error: "A list_id or a name for a new list is required." });
    }
    const films = cleanFilms(req.body.films);

    let listId = Number(list_id);
    let createdList = null;
    try {
        if (list_id !== undefined) {
            if (!Number.isInteger(listId) || !(await canEditList(listId, user_id))) {
                return res.status(404).json({ error: "List not found." });
            }
        } else {
            // Only followers can see a private profile's lists, so the new list starts followers-only there
            const visibility = (await isPrivate(user_id)) ? "followers" : "public";
            createdList = await createList(user_id, name.trim().slice(0, 100), "", true, visibility);
            listId = createdList.id;
        }

        try {
            const matched = await matchFilms(films);

            // One row per TMDb film, even when the sheet lists it twice
            const tmdbMovies = matched.filter((movie, i) => movie && matched.findIndex((m) => m?.id === movie.id) === i);
            const movies = await mapWithConcurrency(tmdbMovies, (tmdbMovie) => createMovie(
                tmdbMovie.id,
                tmdbMovie.title,
                tmdbMovie.release_date ?? "",
                tmdbMovie.overview ?? "",
                tmdbMovie.poster_path ?? "",
                tmdbMovie.original_language ?? "",
                tmdbMovie.popularity ?? 0
            ));
            const movieByTmdbId = new Map(tmdbMovies.map((tmdbMovie, i) => [tmdbMovie.id, movies[i]]));

            const existing = await pool.query(
                "SELECT movie_id, rank FROM list_movies WHERE list_id = $1", [listId]
            );
            const inList = new Set(existing.rows.map((row) => row.movie_id));
            const lastRank = existing.rows.reduce((max, row) => Math.max(max, row.rank ?? 0), 0);

            const newMovies = movies.filter((movie) => !inList.has(movie.id));
            await mapWithConcurrency(newMovies, (movie, index) => addMovieToList(listId, movie.id, lastRank + index + 1, user_id));

            // Watched dates and notes belong to the user rather than the list, so they apply to every matched row
            const notes = await fetchNotes(user_id);
            await mapWithConcurrency(films.map((film, i) => ({ film, movie: matched[i] && movieByTmdbId.get(matched[i].id) })), async ({ film, movie }) => {
                if (!movie) return;
                if (film.watched_on) {
                    await markWatchedOn(user_id, movie.id, film.watched_on);
                } else if (film.watched) {
                    await setMovieWatched(user_id, movie.id, true);
                }
                if (film.note && !notes.has(movie.id)) {
                    await setMovieNote(user_id, movie.id, film.note);
                }
            });

            res.status(201).json({
                list_id: listId,
                added: newMovies.length,
                already_in_list: movies.length - newMovies.length,
                skipped: films.filter((_, i) => !matched[i]).map(describeFilm),
            });
        } catch (error) {
            // A list made by this request shouldn't be left behind half-filled
            if (createdList) await deleteList(createdList.id);
            throw error;
        }
    } catch (error) {
        console.error("Error importing spreadsheet films:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;
