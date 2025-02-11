const pool = require("../config/db");

async function createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity) {
    const result = await pool.query(
        "INSERT INTO movies (tmdb_id, title, release_date, overview, poster_path, original_language, popularity) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (tmdb_id) DO NOTHING RETURNING *;",
        [tmdb_id, title, release_date, overview, poster_path, original_language, popularity]
    );
    // ✅ If the movie was inserted, return the newly created row
    if (result.rows.length > 0) {
        return result.rows[0];
    }

    // ✅ If no row was inserted, fetch the existing row
    const existingMovie = await pool.query(
        `SELECT * FROM movies WHERE tmdb_id = $1;`,
        [tmdb_id]
    );

    return existingMovie.rows[0];
}

async function addMovieToList(list_id, movie_id) {
    try {
        const result = await pool.query(
            "INSERT INTO list_movies (list_id, movie_id) VALUES ($1, $2)",
            [list_id, movie_id]
        );
        return result.rows[0];
    } catch (error) {
        console.error("Error adding movie to list:", error);
        throw error;
    }
}

async function getMovieByTmdbId(tmdb_id) {
    const result = await pool.query(
        "SELECT * FROM movies WHERE tmdb_id = $1",
        [tmdb_id]
    );
    return result.rows[0];
}

module.exports = { createMovie, addMovieToList, getMovieByTmdbId };