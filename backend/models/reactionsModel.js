const pool = require("../config/db");
const { notBlocked } = require("./listModel");
const { ensureMovie } = require("./movieModel");
const { mapWithConcurrency } = require("../services/letterboxdService");

// Discover reactions: films the user liked or disliked ("Not for Me") in Discover, one per film, so their taste
// profile follows them across devices and reinstalls and shapes recommendations on the server. Only ever shown to
// the user themselves. Deleted by Reset Taste Profile and, through ON DELETE CASCADE, with the account. Skips
// (Discover's Skip) are kept too, only to keep a film out of Discover for SKIP_DAYS; they say nothing about taste

const REACTIONS = ["like", "dislike", "skip"];
const MAX_BULK = 2000;
// A skip ("haven't seen it", "not sure") keeps a film out of Discover for this long; likes and dislikes for good
const SKIP_DAYS = 30;
// Films a page of the history can look up on TMDb at once, and how long it waits for them all
const HISTORY_LOOKUPS = 8;
const HISTORY_LOOKUP_MS = 8000;
// Films in each half of the AI's and placement's view of the user's reactions
const MAX_AI_REACTIONS = 120;
const MAX_PLACEMENT_REACTIONS = 100;

// Timestamps are stored in UTC without a zone
const utc = (date) => date.toISOString().replace("T", " ").replace("Z", "");
const ISO_UPDATED_AT = `to_char(updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')`;

/// Saves the user's reaction to a film, replacing any earlier one unless that one is newer than at (a Date, now when
/// left out). Saving the same reaction again keeps its time, so a retry doesn't reorder the history, except for a
/// skip, whose days start again. Returns the reaction saved now: { tmdb_id, reaction, updated_at (ISO) }
async function upsertReaction(user_id, tmdb_id, reaction, source = null, at = null) {
    const result = await pool.query(
        `WITH saved AS (
             INSERT INTO discover_reactions (user_id, tmdb_id, reaction, source, created_at, updated_at)
             VALUES ($1, $2, $3, $4, COALESCE($5::timestamp, CURRENT_TIMESTAMP), COALESCE($5::timestamp, CURRENT_TIMESTAMP))
             ON CONFLICT (user_id, tmdb_id) DO UPDATE
             SET reaction = EXCLUDED.reaction, source = EXCLUDED.source,
                 updated_at = CASE WHEN discover_reactions.reaction = EXCLUDED.reaction AND EXCLUDED.reaction <> 'skip'
                                   THEN discover_reactions.updated_at ELSE EXCLUDED.updated_at END
             WHERE discover_reactions.updated_at <= EXCLUDED.updated_at
             RETURNING tmdb_id, reaction, updated_at
         ), current AS (
             SELECT * FROM saved
             UNION ALL
             SELECT tmdb_id, reaction, updated_at FROM discover_reactions
             WHERE user_id = $1 AND tmdb_id = $2 AND NOT EXISTS (SELECT 1 FROM saved)
         )
         SELECT tmdb_id, reaction, ${ISO_UPDATED_AT} AS updated_at FROM current`,
        [user_id, tmdb_id, reaction, source, at && utc(at)]
    );
    const row = result.rows[0];
    return row ? { ...row, tmdb_id: Number(row.tmdb_id) } : null;
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
            rows.map((row) => utc(row.at)),
        ]
    );
    return result.rowCount;
}

/// The user's reactions, newest first: [{ tmdb_id, reaction, updated_at (ISO) }]
async function fetchReactions(user_id) {
    const result = await pool.query(
        `SELECT tmdb_id, reaction, ${ISO_UPDATED_AT} AS updated_at
         FROM discover_reactions WHERE user_id = $1 ORDER BY updated_at DESC`,
        [user_id]
    );
    return result.rows;
}

/// The user's reactions that still keep a film out of recommendations, as a Map tmdb_id -> reaction: every like
/// and dislike, and skips from the last SKIP_DAYS days
async function fetchReactionMap(user_id) {
    const result = await pool.query(
        `SELECT tmdb_id, reaction FROM discover_reactions
         WHERE user_id = $1 AND (reaction <> 'skip' OR updated_at > CURRENT_TIMESTAMP - make_interval(days => $2))`,
        [user_id, SKIP_DAYS]
    );
    return new Map(result.rows.map((row) => [Number(row.tmdb_id), row.reaction]));
}

/// A page of the films the user liked (or disliked), newest first, for the Liked & Not for Me screen. after is the
/// last page's next ({ at, tmdb_id }). Returns { items: [{ tmdb_id, reaction, reacted_at (ISO), movie }], next,
/// counts: { like, dislike } }, where movie is the film's saved row, or null when it isn't saved and TMDb can't be
/// reached, and next is null on the last page
async function fetchHistory(user_id, reaction, limit, after = null) {
    const [page, totals] = await Promise.all([
        pool.query(
            `SELECT r.tmdb_id, r.reaction, to_char(r.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS reacted_at,
                    r.updated_at::text AS at, m.id AS movie_id, m.title, m.release_date, m.overview, m.poster_path,
                    m.original_language, m.popularity
             FROM discover_reactions r LEFT JOIN movies m ON m.tmdb_id = r.tmdb_id::text
             WHERE r.user_id = $1 AND r.reaction = $2
               AND ($4::timestamp IS NULL OR (r.updated_at, r.tmdb_id) < ($4::timestamp, $5::int))
             ORDER BY r.updated_at DESC, r.tmdb_id DESC LIMIT $3`,
            [user_id, reaction, limit + 1, after?.at ?? null, after?.tmdb_id ?? null]
        ),
        pool.query(
            `SELECT reaction, COUNT(*)::int AS count FROM discover_reactions
             WHERE user_id = $1 AND reaction IN ('like', 'dislike') GROUP BY reaction`,
            [user_id]
        ),
    ]);
    const rows = page.rows.slice(0, limit);
    const last = rows[rows.length - 1];
    const movies = new Map(rows.filter((row) => row.movie_id !== null).map((row) => [row.tmdb_id, row]));
    const missing = rows.filter((row) => row.movie_id === null).map((row) => row.tmdb_id);
    if (missing.length) {
        let timer;
        // Films TMDb is slow about are left without details this time; they're saved for the next
        await Promise.race([
            mapWithConcurrency(missing, async (id) => {
                const movie = await ensureMovie(id).catch(() => null);
                if (movie) movies.set(id, movie);
            }, HISTORY_LOOKUPS),
            new Promise((resolve) => { timer = setTimeout(resolve, HISTORY_LOOKUP_MS); }),
        ]);
        clearTimeout(timer);
    }
    const count = (kind) => totals.rows.find((row) => row.reaction === kind)?.count ?? 0;
    return {
        items: rows.map((row) => ({
            tmdb_id: Number(row.tmdb_id),
            reaction: row.reaction,
            reacted_at: row.reacted_at,
            movie: movies.has(row.tmdb_id) ? historyMovie(row.tmdb_id, movies.get(row.tmdb_id)) : null,
        })),
        next: page.rows.length > limit ? { at: last.at, tmdb_id: Number(last.tmdb_id) } : null,
        counts: { like: count("like"), dislike: count("dislike") },
    };
}

// A movies row in the shape of a Discover film. The row has no genres
function historyMovie(tmdb_id, movie) {
    return {
        id: Number(tmdb_id),
        title: movie.title,
        release_date: movie.release_date ?? "",
        overview: movie.overview ?? "",
        poster_path: movie.poster_path || null,
        original_language: movie.original_language ?? "",
        popularity: Number(movie.popularity) || 0,
        genre_ids: null,
    };
}

/// The user's newest likes and newest dislikes, up to perKind of each: [{ tmdb_id, reaction }], newest first
async function fetchNewestReactions(user_id, perKind = MAX_PLACEMENT_REACTIONS) {
    const result = await pool.query(
        `SELECT tmdb_id, reaction FROM (
             SELECT tmdb_id, reaction, updated_at, ROW_NUMBER() OVER (PARTITION BY reaction ORDER BY updated_at DESC) AS n
             FROM discover_reactions WHERE user_id = $1 AND reaction IN ('like', 'dislike')
         ) newest WHERE n <= $2 ORDER BY updated_at DESC`,
        [user_id, perKind]
    );
    return result.rows.map((row) => ({ tmdb_id: Number(row.tmdb_id), reaction: row.reaction }));
}

/// Everyone's likes and dislikes of films (not shows), newest first, as a Map user_id -> { likes: [ids], dislikes:
/// [ids] }. Only for ranking a group's movie night picks: nobody is ever shown someone else's
async function fetchGroupReactions(user_ids) {
    const result = await pool.query(
        `SELECT user_id, tmdb_id, reaction FROM discover_reactions
         WHERE user_id = ANY($1) AND reaction IN ('like', 'dislike') AND tmdb_id > 0
         ORDER BY updated_at DESC`,
        [user_ids]
    );
    const byUser = new Map(user_ids.map((id) => [id, { likes: [], dislikes: [] }]));
    for (const row of result.rows) byUser.get(row.user_id)[row.reaction === "like" ? "likes" : "dislikes"].push(Number(row.tmdb_id));
    return byUser;
}

/// Films the user liked or disliked, newest first and up to perKind of each, with the title and year when the film
/// has been saved: { liked: [{ tmdb_id, title, year }], disliked: [...] }, for AI Picks. A few more than the AI is
/// told about, since the ones in ranked lists are left out
async function fetchReactedFilms(user_id, perKind = MAX_AI_REACTIONS * 2) {
    const result = await pool.query(
        `SELECT r.tmdb_id, r.reaction, m.title, m.release_date FROM (
             SELECT tmdb_id, reaction, updated_at, ROW_NUMBER() OVER (PARTITION BY reaction ORDER BY updated_at DESC) AS n
             FROM discover_reactions WHERE user_id = $1 AND reaction IN ('like', 'dislike')
         ) r LEFT JOIN movies m ON m.tmdb_id = r.tmdb_id::text
         WHERE r.n <= $2 ORDER BY r.updated_at DESC`,
        [user_id, perKind]
    );
    const films = (reaction) => result.rows
        .filter((row) => row.reaction === reaction)
        .map((row) => ({ tmdb_id: Number(row.tmdb_id), title: row.title ?? null, year: String(row.release_date ?? "").slice(0, 4) }));
    return { liked: films("like"), disliked: films("dislike") };
}

/// Deletes all the user's reactions (Reset Taste Profile), one film's (Undo, or Remove in the history) or all of one
/// kind (reaction "skip": Show Skipped Again, in older builds). Returns how many were deleted
async function deleteReactions(user_id, tmdb_id = null, reaction = null) {
    const conditions = ["user_id = $1"];
    const params = [user_id];
    if (tmdb_id !== null) {
        params.push(tmdb_id);
        conditions.push(`tmdb_id = $${params.length}`);
    }
    if (reaction !== null) {
        params.push(reaction);
        conditions.push(`reaction = $${params.length}`);
    }
    const result = await pool.query(`DELETE FROM discover_reactions WHERE ${conditions.join(" AND ")}`, params);
    return result.rowCount;
}

/// Films friends sent the user that they haven't watched, listed or disliked in Discover, newest first, once each
/// with whoever sent it most recently. Leaves out anyone either of them has blocked
async function fetchFriendPicks(user_id, limit = 20) {
    try {
        return await queryFriendPicks(user_id, limit, true);
    } catch (error) {
        // Before the discover_reactions table is created (npm run migrate), friends' picks still come, unfiltered
        if (error.code !== "42P01") throw error;
        return queryFriendPicks(user_id, limit, false);
    }
}

async function queryFriendPicks(user_id, limit, withReactions) {
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
               ${withReactions ? `AND NOT EXISTS (SELECT 1 FROM discover_reactions d
                               WHERE d.user_id = $1 AND d.tmdb_id = r.tmdb_id AND d.reaction = 'dislike')` : ""}
             ORDER BY r.tmdb_id, r.created_at DESC
         ) picks
         ORDER BY created_at DESC
         LIMIT $2`,
        [user_id, limit]
    );
    return result.rows.map((row) => ({ ...row, tmdb_id: Number(row.tmdb_id) }));
}

module.exports = {
    upsertReaction, upsertReactions, fetchReactions, fetchHistory, fetchNewestReactions, fetchGroupReactions, fetchReactionMap,
    fetchReactedFilms, deleteReactions, fetchFriendPicks, REACTIONS, MAX_BULK, SKIP_DAYS, MAX_AI_REACTIONS,
};
