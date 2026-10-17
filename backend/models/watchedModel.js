const pool = require("../config/db");

async function setMovieWatched(user_id, movie_id, watched) {
    if (watched) {
        await pool.query(
            "INSERT INTO watched_movies (user_id, movie_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            [user_id, movie_id]
        );
    } else {
        await pool.query("DELETE FROM watched_movies WHERE user_id = $1 AND movie_id = $2", [user_id, movie_id]);
    }
}

// Marks every film in a list at once. Unmarking also clears those films in the user's other lists,
// since watched is tracked per user rather than per list
async function setListWatched(user_id, list_id, watched) {
    if (watched) {
        await pool.query(
            `INSERT INTO watched_movies (user_id, movie_id)
             SELECT $1, movie_id FROM list_movies WHERE list_id = $2
             ON CONFLICT DO NOTHING`,
            [user_id, list_id]
        );
    } else {
        await pool.query(
            "DELETE FROM watched_movies WHERE user_id = $1 AND movie_id IN (SELECT movie_id FROM list_movies WHERE list_id = $2)",
            [user_id, list_id]
        );
    }
}

module.exports = { setMovieWatched, setListWatched };
