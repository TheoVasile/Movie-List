const pool = require("../config/db");

async function createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity) {
    const result = await pool.query(
        "INSERT INTO movies (tmdb_id, title, release_date, overview, poster_path, original_language, popularity) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *",
        [tmdb_id, title, release_date, overview, poster_path, original_language, popularity]
    );
    return result.rows[0];
}

async function getMovieByTmdbId(tmdb_id) {
    const result = await pool.query(
        "SELECT * FROM movies WHERE tmdb_id = $1",
        [tmdb_id]
    );
    return result.rows[0];
}

module.exports = { createMovie, getMovieByTmdbId };