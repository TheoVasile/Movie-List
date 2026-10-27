const pool = require("../config/db");
// Called through the module (tmdbCache.fetchTmdb) rather than destructured, so tests can stand in for TMDb
const tmdbCache = require("../services/tmdbCache");
const { tmdbPath } = require("../services/tmdbMedia");

// The movies table is the app's own copy of each film's title, poster and overview, shared by everyone. Everything
// that shows a film reads it from there; TMDb is only asked the first time a film is saved (ensureMovie), so the
// copy comes from TMDb rather than from whichever app happened to save the film first

// Longest title and overview kept, and what a poster path from TMDb looks like ("/abc123.jpg")
const MAX_TITLE = 255; // movies.title is VARCHAR(255)
const MAX_OVERVIEW = 2000;
const POSTER_PATH = /^\/[A-Za-z0-9_.-]+$/;

/// A film's id as the movies table and TMDb know it: a whole number, negative for a TV show (services/tmdbMedia.js).
/// null when it isn't one
function parseTmdbId(value) {
    const id = typeof value === "string" && /^-?\d+$/.test(value.trim()) ? Number(value) : value;
    return Number.isSafeInteger(id) && id !== 0 && Math.abs(id) < 1e9 ? id : null;
}

const text = (value, max) => (typeof value === "string" ? value.trim().slice(0, max) : "");

/// The fields the movies table keeps, checked and cut to size. Used for TMDb's answers and, when TMDb is down,
/// the app's copy. Missing text is "" rather than null, since the app decodes these as plain strings when it
/// fetches its lists. null without a title
function movieFields(film) {
    const title = text(film.title, MAX_TITLE);
    if (!title) return null;
    const poster = text(film.poster_path, 255);
    const date = text(film.release_date, 20);
    const language = text(film.original_language, 10);
    const popularity = Number(film.popularity);
    return {
        title,
        release_date: /^\d{4}(-\d{2}(-\d{2})?)?$/.test(date) ? date : "",
        overview: text(film.overview, MAX_OVERVIEW),
        poster_path: POSTER_PATH.test(poster) ? poster : "",
        original_language: /^[A-Za-z-]{2,10}$/.test(language) ? language : "",
        popularity: Number.isFinite(popularity) && popularity >= 0 ? popularity : 0,
    };
}

/// A film or show's details from TMDb, in movieFields' shape. A show's name and first air date stand in for title
/// and release date. Cached briefly, so a burst of people saving the same new film asks TMDb once
function fetchMovieFields(id) {
    return tmdbCache.cached(`movie-row:${id}`, tmdbCache.DAY, async () => {
        const film = await tmdbCache.fetchTmdb(tmdbPath(id));
        return movieFields({ ...film, title: film.title ?? film.name, release_date: film.release_date ?? film.first_air_date });
    });
}

async function getMovieByTmdbId(tmdb_id) {
    const result = await pool.query(
        "SELECT * FROM movies WHERE tmdb_id = $1",
        [String(tmdb_id)]
    );
    return result.rows[0];
}

// Saves a film's row unless it's already there, then returns the row: two people saving the same new film at
// once both get the one row
async function insertMovie(tmdb_id, film, source) {
    const result = await pool.query(
        `INSERT INTO movies (tmdb_id, title, release_date, overview, poster_path, original_language, popularity, metadata_source)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (tmdb_id) DO NOTHING RETURNING *`,
        [String(tmdb_id), film.title, film.release_date, film.overview, film.poster_path, film.original_language, film.popularity, source]
    );
    return result.rows[0] ?? getMovieByTmdbId(tmdb_id);
}

/// The movies row for a TMDb id (negative for a show), saving it first if it isn't there. A film already saved
/// never calls TMDb. A new one is fetched from TMDb once; only when TMDb can't be reached is the app's copy
/// (fallback: { title, poster_path, overview, ... }) used, checked and cut to size, and marked
/// metadata_source 'client' for scripts/refreshMovies.js to repair. Returns null for an id that isn't one or
/// that TMDb says doesn't exist. Throws when TMDb is down and there's no usable fallback
async function ensureMovie(tmdb_id, fallback = null) {
    const id = parseTmdbId(tmdb_id);
    if (id === null) return null;
    const existing = await getMovieByTmdbId(id);
    if (existing) return existing;
    let film;
    try {
        film = await fetchMovieFields(id);
    } catch (error) {
        if (error.response?.status === 404) return null;
        const copy = fallback && movieFields(fallback);
        if (!copy) throw error;
        console.warn(`TMDb couldn't be reached for ${tmdbPath(id)} (${error.message}); saving the app's copy for now`);
        return insertMovie(id, copy, "client");
    }
    if (!film) return null;
    return insertMovie(id, film, "tmdb");
}

/// A movies row as the app's MovieResponse decodes it, with blanks rather than nulls
function movieJSON(movie) {
    return {
        id: movie.id,
        tmdb_id: String(movie.tmdb_id),
        title: movie.title,
        release_date: movie.release_date ?? "",
        overview: movie.overview ?? "",
        poster_path: movie.poster_path ?? "",
        original_language: movie.original_language ?? "",
        popularity: movie.popularity ?? 0,
        created_at: movie.created_at,
    };
}

// Saves films matched on TMDb by the server itself (Letterboxd and spreadsheet imports), so their details are
// TMDb's. Returns the row, which keeps what it had if the film was already saved
async function createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity) {
    const film = movieFields({ title, release_date, overview, poster_path, original_language, popularity });
    if (!film) throw new Error(`TMDb film ${tmdb_id} has no title`);
    return insertMovie(tmdb_id, film, "tmdb");
}

async function removeMovieFromList(list_id, movie_id) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN"); // Start transaction

        // Delete the movie and return the deleted row
        const result = await client.query(
            `DELETE FROM list_movies WHERE list_id = $1 AND movie_id = $2 RETURNING *`,
            [list_id, movie_id]
        );

        if (result.rowCount === 0) {
            await client.query("COMMIT"); // Commit even if nothing is deleted
            return { message: "No matching movie found, but operation successful." };
        }

        // Reorder rankings after deletion
        await client.query(
            `UPDATE list_movies
             SET rank = new_rank
             FROM (
                 SELECT movie_id, ROW_NUMBER() OVER (ORDER BY rank) AS new_rank
                 FROM list_movies
                 WHERE list_id = $1
             ) AS ranked
             WHERE list_movies.list_id = $1 AND list_movies.movie_id = ranked.movie_id`,
            [list_id]
        );

        await client.query("COMMIT"); // Commit transaction
        return result.rows[0]; // Return the deleted movie
    } catch (error) {
        await client.query("ROLLBACK"); // Rollback on error
        console.error("Error removing movie from list:", error);
        throw error;
    } finally {
        client.release(); // Release the client
    }
}

// added_by is who added it, which shared lists show. rank is chosen by the server (imports number films in the
// order they came); films added from the app go through appendMovieToList instead
async function addMovieToList(list_id, movie_id, rank, added_by = null) {
    try {
        const result = await pool.query(
            "INSERT INTO list_movies (list_id, movie_id, rank, added_by) VALUES ($1, $2, $3, $4)",
            [list_id, movie_id, rank, added_by]
        );
        // date_modified tracks when a film was last added, so the app can offer recently used lists first
        await pool.query("UPDATE lists SET date_modified = CURRENT_TIMESTAMP WHERE id = $1", [list_id]);
        return result.rows[0];
    } catch (error) {
        console.error("Error adding movie to list:", error);
        throw error;
    }
}

/// Adds a film to the end of a list, after its last film, and returns { movie_id, rank, added }. The list's row is
/// locked while the rank is worked out, so two films added at once don't get the same rank. Adding a film that's
/// already in the list changes nothing and returns where it is, with added false
async function appendMovieToList(list_id, movie_id, added_by = null) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        await client.query("SELECT 1 FROM lists WHERE id = $1 FOR UPDATE", [list_id]);
        const inserted = await client.query(
            `INSERT INTO list_movies (list_id, movie_id, rank, added_by)
             SELECT $1, $2, COALESCE(MAX(rank), 0) + 1, $3 FROM list_movies WHERE list_id = $1
             ON CONFLICT (list_id, movie_id) DO NOTHING
             RETURNING movie_id, rank`,
            [list_id, movie_id, added_by]
        );
        let row = inserted.rows[0];
        if (row) {
            // date_modified tracks when a film was last added, so the app can offer recently used lists first
            await client.query("UPDATE lists SET date_modified = CURRENT_TIMESTAMP WHERE id = $1", [list_id]);
        } else {
            row = (await client.query("SELECT movie_id, rank FROM list_movies WHERE list_id = $1 AND movie_id = $2", [list_id, movie_id])).rows[0];
        }
        await client.query("COMMIT");
        return { movie_id: row.movie_id, rank: row.rank, added: Boolean(inserted.rows[0]) };
    } catch (error) {
        await client.query("ROLLBACK").catch(() => {});
        throw error;
    } finally {
        client.release();
    }
}

// Moves a film to new_rank, shifting the films in between. A move by the user marks the film as hand-placed;
// aiPlaced marks it as placed by Smart Placement instead. The rank is kept within 1 to the number of films in the
// list. Returns null when the film isn't in the list
async function updateMovieRank(list_id, movie_id, requested_rank, aiPlaced = false) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN"); // Start transaction
        // Locked like appendMovieToList, so a film added meanwhile can't change the count under us
        await client.query("SELECT 1 FROM lists WHERE id = $1 FOR UPDATE", [list_id]);

        // Get the current rank of the movie, and how many films the list has
        const { rows } = await client.query(
            `SELECT rank, (SELECT COUNT(*) FROM list_movies WHERE list_id = $1)::int AS count
             FROM list_movies WHERE list_id = $1 AND movie_id = $2`,
            [list_id, movie_id]
        );

        if (rows.length === 0) {
            await client.query("ROLLBACK");
            return null;
        }

        const old_rank = rows[0].rank;
        const new_rank = Math.min(Math.max(requested_rank, 1), rows[0].count);
        if (old_rank === new_rank) {
            const unchanged = await client.query(
                "UPDATE list_movies SET ai_placed = $3 WHERE list_id = $1 AND movie_id = $2 RETURNING *",
                [list_id, movie_id, aiPlaced]
            );
            await client.query("COMMIT");
            return unchanged.rows[0];
        }
        // Shift affected movies up or down
        await client.query(
            `UPDATE list_movies
             SET rank = CASE
                 WHEN CAST($1 AS INTEGER) < CAST($2 AS INTEGER) THEN rank - 1
                 WHEN CAST($1 AS INTEGER) > CAST($2 AS INTEGER) THEN rank + 1
                 ELSE rank
             END
             WHERE list_id = CAST($3 AS INTEGER)
             AND rank BETWEEN LEAST(CAST($1 AS INTEGER), CAST($2 AS INTEGER))
                         AND GREATEST(CAST($1 AS INTEGER), CAST($2 AS INTEGER))
             AND movie_id != CAST($4 AS INTEGER)`,
            [old_rank, new_rank, list_id, movie_id]
        );

        // Update the movie's rank
        const result = await client.query(
            "UPDATE list_movies SET rank = $1, ai_placed = $4 WHERE list_id = $2 AND movie_id = $3 RETURNING *",
            [new_rank, list_id, movie_id, aiPlaced]
        );
        await client.query("COMMIT"); // Commit transaction
        return result.rows[0];

    } catch (error) {
        await client.query("ROLLBACK"); // Rollback in case of error
        console.error("Error updating movie rank:", error);
        throw error;
    } finally {
        client.release(); // Release DB connection
    }
}


// Puts every film in a list in the given order at once, e.g. when the user sorts it by TMDb rating.
// movieIds must hold exactly the list's films; returns false when it doesn't (the list changed meanwhile)
async function setListOrder(listId, movieIds) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        const { rows } = await client.query("SELECT movie_id FROM list_movies WHERE list_id = $1 FOR UPDATE", [listId]);
        const current = new Set(rows.map((row) => row.movie_id));
        if (current.size !== movieIds.length || !movieIds.every((id) => current.has(id))) {
            await client.query("ROLLBACK");
            return false;
        }
        await client.query(
            `UPDATE list_movies SET rank = o.ord, ai_placed = false
             FROM unnest($2::int[]) WITH ORDINALITY AS o(movie_id, ord)
             WHERE list_movies.list_id = $1 AND list_movies.movie_id = o.movie_id`,
            [listId, movieIds]
        );
        await client.query("COMMIT");
        return true;
    } catch (error) {
        await client.query("ROLLBACK");
        throw error;
    } finally {
        client.release();
    }
}

module.exports = {
    ensureMovie, movieJSON, movieFields, parseTmdbId, createMovie, addMovieToList, appendMovieToList, getMovieByTmdbId,
    removeMovieFromList, updateMovieRank, setListOrder, MAX_TITLE, MAX_OVERVIEW,
};