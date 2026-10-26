const pool = require("../config/db");
const { notBlocked } = require("./socialModel");
const { reviewStatus } = require("../services/moderation");
const { reportFlagged } = require("./reportsModel");

// Films people send each other: "you should see this", with an optional note. Anyone can send a film to someone
// who follows them or whom they follow, unless either has blocked the other

const MAX_RECIPIENTS = 20;

/// Sends a film to people by @handle. film is { tmdb_id, title, poster_path, release_date, overview,
/// original_language, popularity }. Sending the same film to someone again brings it back to the top with the new
/// note. A note moderation flags is held back from the people it's sent to until it's reviewed, and reported.
/// Returns who it went to, as [{ firebase_uid, handle }] (handles the user can't send to are left out), and the
/// note's moderation_status
async function sendRecommendation(user_id, handles, film, note) {
    const recipients = await pool.query(
        `SELECT u.firebase_uid, u.handle FROM users u
         WHERE u.handle = ANY($2::text[]) AND u.firebase_uid <> $1 AND ${notBlocked("$1", "u.firebase_uid")}
           AND EXISTS (SELECT 1 FROM follows f WHERE f.accepted
                       AND ((f.follower_id = $1 AND f.followee_id = u.firebase_uid) OR (f.follower_id = u.firebase_uid AND f.followee_id = $1)))`,
        [user_id, handles.slice(0, MAX_RECIPIENTS)]
    );
    const review = reviewStatus("recommendation_note", note);
    const ids = [];
    for (const { firebase_uid: recipient_id } of recipients.rows) {
        const saved = await pool.query(
            `INSERT INTO film_recommendations (sender_id, recipient_id, tmdb_id, title, poster_path, release_date, overview, original_language, popularity, note, moderation_status)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
             ON CONFLICT (sender_id, recipient_id, tmdb_id)
             DO UPDATE SET note = EXCLUDED.note, moderation_status = EXCLUDED.moderation_status, created_at = CURRENT_TIMESTAMP, seen = false
             RETURNING id`,
            [user_id, recipient_id, film.tmdb_id, film.title, film.poster_path, film.release_date, film.overview,
             film.original_language, film.popularity, note, review.status]
        );
        ids.push(saved.rows[0].id);
    }
    if (review.status === "flagged" && ids.length) {
        await reportFlagged(user_id, { content_type: "recommendation", content_id: ids.join(",").slice(0, 64), reason: review.reason, details: note });
    }
    return { sentTo: recipients.rows, status: review.status };
}

/// Films sent to the user, newest first, with who sent each. Leaves out anyone the user has since blocked, and
/// notes moderation is holding for review
async function fetchReceived(user_id) {
    const result = await pool.query(
        `SELECT r.id, r.tmdb_id, r.title, r.poster_path, r.release_date, r.overview, r.original_language, r.popularity,
                CASE WHEN r.moderation_status = 'ok' THEN r.note END AS note, r.seen, to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS sent_at,
                u.handle AS sender_handle, u.username AS sender_name,
                FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS sender_avatar_version
         FROM film_recommendations r JOIN users u ON u.firebase_uid = r.sender_id
         WHERE r.recipient_id = $1 AND u.handle IS NOT NULL AND ${notBlocked("$1", "u.firebase_uid")}
         ORDER BY r.created_at DESC
         LIMIT 200`,
        [user_id]
    );
    return result.rows;
}

async function markSeen(user_id) {
    await pool.query("UPDATE film_recommendations SET seen = true WHERE recipient_id = $1 AND NOT seen", [user_id]);
}

/// Removes a film someone sent the user. Returns false when there's no such recommendation for them
async function removeReceived(user_id, id) {
    const result = await pool.query("DELETE FROM film_recommendations WHERE id = $1 AND recipient_id = $2", [id, user_id]);
    return result.rowCount > 0;
}

module.exports = { MAX_RECIPIENTS, sendRecommendation, fetchReceived, markSeen, removeReceived };
