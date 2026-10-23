const pool = require("../config/db");
const { groupParticipants } = require("./groupModel");

// A movie night group's shortlist: films recommended for the group (suggested_by null) and films people in it
// suggested, each liked or disliked by anyone in the group. A film everyone dislikes leaves the shortlist and is
// never recommended to the group again. Refreshing swaps every recommendation nobody has liked for new ones;
// suggestions stay until everyone dislikes them

// The shortlist, most liked first, with everyone's tallies, the user's own reaction and who liked each.
// null when the user isn't in the group
async function fetchPicks(user_id, group_id) {
    if (!(await groupParticipants(user_id, group_id))) return null;
    const result = await pool.query(
        `SELECT p.tmdb_id, p.title, p.poster_path, p.release_date, p.overview, p.original_language, p.popularity, p.reason,
                p.by_ai AS ai, s.handle AS suggested_by,
                COUNT(r.*) FILTER (WHERE r.reaction = 1)::int AS likes,
                COUNT(r.*) FILTER (WHERE r.reaction = -1)::int AS dislikes,
                COALESCE(MAX(r.reaction) FILTER (WHERE r.user_id = $2), 0)::int AS my_reaction,
                COALESCE(ARRAY_AGG(u.handle ORDER BY r.reacted_at) FILTER (WHERE r.reaction = 1 AND u.handle IS NOT NULL), '{}') AS liked_by
         FROM group_picks p
         LEFT JOIN users s ON s.firebase_uid = p.suggested_by
         LEFT JOIN group_pick_reactions r ON r.group_id = p.group_id AND r.tmdb_id = p.tmdb_id
         LEFT JOIN users u ON u.firebase_uid = r.user_id
         WHERE p.group_id = $1
         GROUP BY p.group_id, p.tmdb_id, s.handle
         ORDER BY likes DESC, (p.suggested_by IS NOT NULL) DESC, p.added_at, p.position`,
        [group_id, user_id]
    );
    return result.rows;
}

/// What a refresh should know: films already on the shortlist or turned down by everyone (never to recommend
/// again), and the titles the group liked and turned down, to steer the next picks
async function pickHistory(group_id) {
    const result = await pool.query(
        `SELECT p.tmdb_id, p.title, false AS dismissed,
                EXISTS (SELECT 1 FROM group_pick_reactions r WHERE r.group_id = p.group_id AND r.tmdb_id = p.tmdb_id AND r.reaction = 1) AS liked
         FROM group_picks p WHERE p.group_id = $1
         UNION ALL
         SELECT d.tmdb_id, d.title, true, false FROM group_dismissed d WHERE d.group_id = $1`,
        [group_id]
    );
    return {
        exclude: new Set(result.rows.map((row) => Number(row.tmdb_id))),
        liked: result.rows.filter((row) => row.liked).map((row) => row.title),
        dismissed: result.rows.filter((row) => row.dismissed).map((row) => row.title).filter(Boolean),
        shortlist: result.rows.filter((row) => !row.dismissed).map((row) => row.title),
    };
}

/// Swaps the group's recommendations that nobody has liked for new ones. movies are discover movies with a reason,
/// and ai: true when the AI picked them
async function saveRecommendations(group_id, movies) {
    await pool.query(
        `DELETE FROM group_picks p
         WHERE p.group_id = $1 AND p.suggested_by IS NULL AND NOT EXISTS (
             SELECT 1 FROM group_pick_reactions r WHERE r.group_id = p.group_id AND r.tmdb_id = p.tmdb_id AND r.reaction = 1)`,
        [group_id]
    );
    for (const [position, movie] of movies.entries()) {
        await pool.query(
            // Never a film everyone in the group turned down
            `INSERT INTO group_picks (group_id, tmdb_id, title, poster_path, release_date, overview, original_language, popularity, reason, position, by_ai)
             SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
             WHERE NOT EXISTS (SELECT 1 FROM group_dismissed WHERE group_id = $1 AND tmdb_id = $2)
             ON CONFLICT DO NOTHING`,
            [group_id, movie.id, String(movie.title).slice(0, 255), movie.poster_path || null, String(movie.release_date ?? "").slice(0, 20),
             movie.overview ?? "", movie.original_language ?? "", movie.popularity ?? 0, movie.reason ?? null, position, movie.ai === true]
        );
    }
}

/// Someone in the group suggests a film, which counts as their like. Returns false when they aren't in the group
async function suggestPick(user_id, group_id, film) {
    if (!(await groupParticipants(user_id, group_id))) return false;
    await pool.query(
        `INSERT INTO group_picks (group_id, tmdb_id, title, poster_path, release_date, overview, original_language, popularity, suggested_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         ON CONFLICT (group_id, tmdb_id) DO UPDATE SET suggested_by = COALESCE(group_picks.suggested_by, EXCLUDED.suggested_by)`,
        [group_id, film.tmdb_id, film.title, film.poster_path, film.release_date, film.overview, film.original_language, film.popularity, user_id]
    );
    // Suggesting a film everyone once turned down brings it back
    await pool.query("DELETE FROM group_dismissed WHERE group_id = $1 AND tmdb_id = $2", [group_id, film.tmdb_id]);
    await setReaction(group_id, film.tmdb_id, user_id, 1);
    return true;
}

async function setReaction(group_id, tmdb_id, user_id, reaction) {
    if (reaction === 0) {
        await pool.query("DELETE FROM group_pick_reactions WHERE group_id = $1 AND tmdb_id = $2 AND user_id = $3", [group_id, tmdb_id, user_id]);
    } else {
        await pool.query(
            `INSERT INTO group_pick_reactions (group_id, tmdb_id, user_id, reaction) VALUES ($1, $2, $3, $4)
             ON CONFLICT (group_id, tmdb_id, user_id) DO UPDATE SET reaction = $4, reacted_at = CURRENT_TIMESTAMP`,
            [group_id, tmdb_id, user_id, reaction]
        );
    }
}

/// Likes (1) or dislikes (-1) a film on the shortlist, or takes it back (0). Once everyone in the group has
/// disliked it, it leaves the shortlist for good. Returns null when the user isn't in the group, false when the
/// film isn't on the shortlist
async function reactToPick(user_id, group_id, tmdb_id, reaction) {
    const everyone = await groupParticipants(user_id, group_id);
    if (!everyone) return null;
    const pick = await pool.query("SELECT title FROM group_picks WHERE group_id = $1 AND tmdb_id = $2", [group_id, tmdb_id]);
    if (!pick.rowCount) return false;
    await setReaction(group_id, tmdb_id, user_id, reaction);
    if (reaction === -1) {
        const dislikes = await pool.query(
            "SELECT COUNT(*)::int AS n FROM group_pick_reactions WHERE group_id = $1 AND tmdb_id = $2 AND reaction = -1",
            [group_id, tmdb_id]
        );
        if (dislikes.rows[0].n >= everyone.length) {
            await pool.query(
                "INSERT INTO group_dismissed (group_id, tmdb_id, title) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                [group_id, tmdb_id, pick.rows[0].title]
            );
            await pool.query("DELETE FROM group_picks WHERE group_id = $1 AND tmdb_id = $2", [group_id, tmdb_id]);
        }
    }
    return true;
}

/// Takes a suggestion off the shortlist: the person who suggested it or the group's owner. Returns false when
/// they can't, or it isn't there
async function removePick(user_id, group_id, tmdb_id) {
    const result = await pool.query(
        `DELETE FROM group_picks p USING watch_groups g
         WHERE p.group_id = g.id AND g.id = $1 AND p.tmdb_id = $2 AND (p.suggested_by = $3 OR g.owner_id = $3)`,
        [group_id, tmdb_id, user_id]
    );
    return result.rowCount > 0;
}

/// The liked films, most liked first, for a vote. Each is { tmdb_id, title, poster_path, release_date, reason }
async function likedPicks(group_id, limit) {
    const result = await pool.query(
        `SELECT p.tmdb_id, p.title, p.poster_path, p.release_date, p.reason, COUNT(*) AS likes
         FROM group_picks p JOIN group_pick_reactions r ON r.group_id = p.group_id AND r.tmdb_id = p.tmdb_id AND r.reaction = 1
         WHERE p.group_id = $1
         GROUP BY p.group_id, p.tmdb_id
         ORDER BY likes DESC, p.added_at
         LIMIT $2`,
        [group_id, limit]
    );
    return result.rows;
}

module.exports = { fetchPicks, pickHistory, saveRecommendations, suggestPick, reactToPick, removePick, likedPicks };
