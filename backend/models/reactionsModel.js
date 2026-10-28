const pool = require("../config/db");
const { notBlocked } = require("./listModel");

// Discover reactions: films the user liked, disliked ("Not for Me") or skipped in Discover, one per film, so their
// taste profile follows them across devices and reinstalls and shapes recommendations on the server. Deleted by
// Reset Taste Profile and, through ON DELETE CASCADE, with the account

const REACTIONS = ["like", "dislike", "skip"];
const MAX_BULK = 2000;

/// Saves the user's reaction to a film, replacing any earlier one
async function upsertReaction(user_id, tmdb_id, reaction, source = null) {
    await pool.query(
        `INSERT INTO discover_reactions (user_id, tmdb_id, reaction, source) VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id, tmdb_id) DO UPDATE
         SET reaction = EXCLUDED.reaction, source = EXCLUDED.source, updated_at = CURRENT_TIMESTAMP`,
        [user_id, tmdb_id, reaction, source]
    );
}

/// Saves many reactions at once (a device's history), [{ tmdb_id, reaction, at: Date }], keeping whichever reaction
/// to a film is newest, here or already saved. Returns how many were saved
async function upsertReactions(user_id, reactions) {
    // One row per film, the newest, since a statement can't update the same row twice
    const newest = new Map();
    for (const reaction of reactions) {
        const current = newest.get(reaction.tmdb_id);
        if (!current || reaction.at > current.at) newest.set(reaction.tmdb_id, reaction);
    }
    const rows = [...newest.values()];
    if (!rows.length) return 0;
    const result = await pool.query(
        `INSERT INTO discover_reactions (user_id, tmdb_id, reaction, source, created_at, updated_at)
         SELECT $1, r.tmdb_id, r.reaction, 'migration', r.at, r.at
         FROM unnest($2::int[], $3::text[], $4::timestamp[]) AS r(tmdb_id, reaction, at)
         ON CONFLICT (user_id, tmdb_id) DO UPDATE
         SET reaction = EXCLUDED.reaction, updated_at = EXCLUDED.updated_at
         WHERE discover_reactions.updated_at <= EXCLUDED.updated_at`,
        [
            user_id,
            rows.map((row) => row.tmdb_id),
            rows.map((row) => row.reaction),
            // Timestamps are stored in UTC without a zone
            rows.map((row) => row.at.toISOString().replace("T", " ").replace("Z", "")),
        ]
    );
    return result.rowCount;
}

/// The user's reactions, newest first: [{ tmdb_id, reaction, updated_at (ISO) }]
async function fetchReactions(user_id) {
    const result = await pool.query(
        `SELECT tmdb_id, reaction, to_char(updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at
         FROM discover_reactions WHERE user_id = $1 ORDER BY updated_at DESC`,
        [user_id]
    );
    return result.rows;
}

/// The user's reactions as a Map tmdb_id -> reaction
async function fetchReactionMap(user_id) {
    const result = await pool.query("SELECT tmdb_id, reaction FROM discover_reactions WHERE user_id = $1", [user_id]);
    return new Map(result.rows.map((row) => [Number(row.tmdb_id), row.reaction]));
}

/// Films the user liked or disliked, newest first, with the title and year when the film has been saved:
/// { liked: [{ tmdb_id, title, year }], disliked: [...] }, for AI Picks
async function fetchReactedFilms(user_id, limit = 300) {
    const result = await pool.query(
        `SELECT r.tmdb_id, r.reaction, m.title, m.release_date
         FROM discover_reactions r LEFT JOIN movies m ON m.tmdb_id = r.tmdb_id::text
         WHERE r.user_id = $1 AND r.reaction IN ('like', 'dislike')
         ORDER BY r.updated_at DESC LIMIT $2`,
        [user_id, limit]
    );
    const films = (reaction) => result.rows
        .filter((row) => row.reaction === reaction)
        .map((row) => ({ tmdb_id: Number(row.tmdb_id), title: row.title ?? null, year: String(row.release_date ?? "").slice(0, 4) }));
    return { liked: films("like"), disliked: films("dislike") };
}

/// Deletes all the user's reactions (Reset Taste Profile), or one film's (Undo). Returns how many were deleted
async function deleteReactions(user_id, tmdb_id = null) {
    const result = tmdb_id === null
        ? await pool.query("DELETE FROM discover_reactions WHERE user_id = $1", [user_id])
        : await pool.query("DELETE FROM discover_reactions WHERE user_id = $1 AND tmdb_id = $2", [user_id, tmdb_id]);
    return result.rowCount;
}

/// Films friends sent the user that they haven't watched, listed or disliked in Discover, newest first, once each
/// with whoever sent it most recently. Leaves out anyone either of them has blocked
async function fetchFriendPicks(user_id, limit = 20) {
    const result = await pool.query(
        `SELECT * FROM (
             SELECT DISTINCT ON (r.tmdb_id) r.tmdb_id, r.title, r.poster_path, r.release_date, r.overview,
                    r.original_language, r.popularity, r.created_at, u.handle, u.username AS display_name
             FROM film_recommendations r JOIN users u ON u.firebase_uid = r.sender_id
             WHERE r.recipient_id = $1 AND u.handle IS NOT NULL AND ${notBlocked("$1", "u.firebase_uid")}
               AND NOT EXISTS (SELECT 1 FROM lists l JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
                               WHERE l.user_id = $1 AND m.tmdb_id = r.tmdb_id::text)
               AND NOT EXISTS (SELECT 1 FROM watched_movies w JOIN movies m ON m.id = w.movie_id
                               WHERE w.user_id = $1 AND m.tmdb_id = r.tmdb_id::text)
               AND NOT EXISTS (SELECT 1 FROM discover_reactions d
                               WHERE d.user_id = $1 AND d.tmdb_id = r.tmdb_id AND d.reaction = 'dislike')
             ORDER BY r.tmdb_id, r.created_at DESC
         ) picks
         ORDER BY created_at DESC
         LIMIT $2`,
        [user_id, limit]
    );
    return result.rows.map((row) => ({ ...row, tmdb_id: Number(row.tmdb_id) }));
}

module.exports = {
    upsertReaction, upsertReactions, fetchReactions, fetchReactionMap, fetchReactedFilms, deleteReactions,
    fetchFriendPicks, REACTIONS, MAX_BULK,
};
