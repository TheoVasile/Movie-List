const pool = require("../config/db");

// A user's private note on a film. Like watched, it's per user rather than per list, so the same note
// shows in every list the film is in. An empty note deletes it
async function setMovieNote(user_id, movie_id, note) {
    if (!note.trim()) {
        await pool.query("DELETE FROM movie_notes WHERE user_id = $1 AND movie_id = $2", [user_id, movie_id]);
        return;
    }
    await pool.query(
        `INSERT INTO movie_notes (user_id, movie_id, note) VALUES ($1, $2, $3)
         ON CONFLICT (user_id, movie_id) DO UPDATE SET note = EXCLUDED.note, updated_at = CURRENT_TIMESTAMP`,
        [user_id, movie_id, note]
    );
}

// movie_id -> note for every film the user has written about
async function fetchNotes(user_id) {
    const result = await pool.query("SELECT movie_id, note FROM movie_notes WHERE user_id = $1", [user_id]);
    return new Map(result.rows.map((row) => [row.movie_id, row.note]));
}

module.exports = { setMovieNote, fetchNotes };
