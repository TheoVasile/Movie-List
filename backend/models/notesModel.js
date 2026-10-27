const pool = require("../config/db");
const { reviewStatus } = require("../services/moderation");
const { reportFlagged } = require("./reportsModel");

// A user's note on a film, visible to them and to people who follow them. Like watched, it's per user
// rather than per list, so the same note shows in every list the film is in. An empty note deletes it.
// Every note is checked by automatic moderation: one it flags is saved, but only its author sees it until it's
// reviewed, and it's reported for review. Returns the note's moderation_status, or null when it was deleted
async function setMovieNote(user_id, movie_id, note) {
    if (!note.trim()) {
        await pool.query("DELETE FROM movie_notes WHERE user_id = $1 AND movie_id = $2", [user_id, movie_id]);
        return null;
    }
    const review = reviewStatus("note", note);
    await pool.query(
        `INSERT INTO movie_notes (user_id, movie_id, note, moderation_status) VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id, movie_id) DO UPDATE SET note = EXCLUDED.note, moderation_status = EXCLUDED.moderation_status,
             updated_at = CURRENT_TIMESTAMP`,
        [user_id, movie_id, note, review.status]
    );
    if (review.status === "flagged") {
        // Reported by TMDb id, like notes people report from the app
        const movie = await pool.query("SELECT tmdb_id FROM movies WHERE id = $1", [movie_id]);
        await reportFlagged(user_id, { content_type: "note", content_id: movie.rows[0]?.tmdb_id ?? String(movie_id), reason: review.reason, details: note });
    }
    return review.status;
}

// movie_id -> { note, moderation_status } for every film the user has written about
async function fetchNotes(user_id) {
    const result = await pool.query("SELECT movie_id, note, moderation_status FROM movie_notes WHERE user_id = $1", [user_id]);
    return new Map(result.rows.map((row) => [row.movie_id, { note: row.note, moderation_status: row.moderation_status }]));
}

module.exports = { setMovieNote, fetchNotes };
