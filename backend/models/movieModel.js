const getPool = require("../config/db");

async function createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity) {
    const pool = getPool();
    const result = await pool.query(
        "INSERT INTO users (tmdb_id, title, release_date, overview, poster_path, original_language, popularity) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *",
        [tmdb_id, title, release_date, overview, poster_path, original_language, popularity]
    );
    await pool.end();
    return result.rows[0];
}

async function getMovieByTmdbId(tmdb_id) {
    const pool = getPool();
    const result = await pool.query(
        "SELECT * FROM movies WHERE tmdb_id = $1",
        [tmdb_id]
    );
    await pool.end();
    return result.rows[0];
}

module.exports = { createMovie, getMovieByTmdbId };