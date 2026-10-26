const pool = require("../config/db");

async function setMovieWatched(user_id, movie_id, watched) {
    if (watched) {
        await pool.query(
            "INSERT INTO watched_movies (user_id, movie_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            [user_id, movie_id]
        );
    } else {
        // Never watched means no rewatches either
        await pool.query("DELETE FROM watched_movies WHERE user_id = $1 AND movie_id = $2", [user_id, movie_id]);
        await pool.query("DELETE FROM watch_log WHERE user_id = $1 AND movie_id = $2", [user_id, movie_id]);
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

// Records a watch on a given day (a "YYYY-MM-DD" string). The first watch marks the film watched;
// later ones go in the log as rewatches. Returns "first" or "rewatch"
async function logWatch(user_id, movie_id, watched_on) {
    const first = await pool.query(
        `INSERT INTO watched_movies (user_id, movie_id, watched_at) VALUES ($1, $2, $3::date)
         ON CONFLICT DO NOTHING RETURNING movie_id`,
        [user_id, movie_id, watched_on]
    );
    if (first.rowCount) return "first";
    await pool.query("INSERT INTO watch_log (user_id, movie_id, watched_on) VALUES ($1, $2, $3)", [user_id, movie_id, watched_on]);
    return "rewatch";
}

// Marks a film watched on the given day unless it's already watched. Unlike logWatch it never adds a rewatch,
// so importing the same spreadsheet twice doesn't double the diary
async function markWatchedOn(user_id, movie_id, watched_on) {
    await pool.query(
        "INSERT INTO watched_movies (user_id, movie_id, watched_at) VALUES ($1, $2, $3::date) ON CONFLICT DO NOTHING",
        [user_id, movie_id, watched_on]
    );
}

// Removes one rewatch. Returns whether it was the user's to remove
async function deleteRewatch(user_id, log_id) {
    const result = await pool.query("DELETE FROM watch_log WHERE id = $1 AND user_id = $2", [log_id, user_id]);
    return result.rowCount > 0;
}

// Imports and "mark list as watched" save many films at the same moment. That moment isn't when the
// films were seen, so those watches are flagged rather than dated
const BULK_WATCH_SIZE = 20;

// Every watch, newest first: first watches from watched_movies and rewatches from watch_log, each with
// the film's details. movie_id limits it to one film
async function fetchDiary(user_id, movie_id = null) {
    const result = await pool.query(
        `WITH bulk AS (
             SELECT date_trunc('second', watched_at) AS at FROM watched_movies
             WHERE user_id = $1 GROUP BY 1 HAVING COUNT(*) > ${BULK_WATCH_SIZE}
         ), watches AS (
             SELECT NULL::int AS id, w.movie_id, w.watched_at AS watched_at, 'first' AS kind,
                    date_trunc('second', w.watched_at) IN (SELECT at FROM bulk) AS bulk
             FROM watched_movies w WHERE w.user_id = $1
             UNION ALL
             SELECT l.id, l.movie_id, l.watched_on::timestamp, 'rewatch', false
             FROM watch_log l WHERE l.user_id = $1
         )
         SELECT watches.*, m.tmdb_id, m.title, m.poster_path, m.release_date
         FROM watches JOIN movies m ON m.id = watches.movie_id
         WHERE $2::int IS NULL OR watches.movie_id = $2
         ORDER BY watches.watched_at DESC, watches.id DESC NULLS LAST`,
        [user_id, movie_id]
    );
    return result.rows.map((row) => ({
        id: row.id,
        kind: row.kind,
        movie_id: row.movie_id,
        tmdb_id: Number(row.tmdb_id),
        title: row.title,
        poster_path: row.poster_path || null,
        release_date: row.release_date ?? "",
        watched_at: row.watched_at,
        bulk: row.bulk,
    }));
}

module.exports = { setMovieWatched, setListWatched, logWatch, markWatchedOn, deleteRewatch, fetchDiary };
