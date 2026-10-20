const pool = require("../config/db");
const { notifyUser } = require("./pushService");
const { visibleTo } = require("../models/listModel");

// Watches or list additions saved more than this many to the second were done in bulk (an import, or
// marking a whole list watched), not one by one, so they aren't news
const BULK_WATCH_SIZE = 20;

const yearOf = (date) => String(date ?? "").slice(0, 4);
const filmLabel = (row) => (yearOf(row.release_date) ? `${row.title} (${yearOf(row.release_date)})` : row.title);

/// What the people a user follows did in the last day: films they watched and films they added to a list,
/// with whether each film is in one of the user's own lists (and if so whether it's their watchlist)
async function fetchFriendActivity(user_id) {
    const result = await pool.query(
        `WITH friends AS (
             SELECT f.followee_id AS id, u.username AS name, u.handle
             FROM follows f JOIN users u ON u.firebase_uid = f.followee_id
             WHERE f.follower_id = $1 AND f.accepted
         ), bulk AS (
             SELECT user_id, date_trunc('second', watched_at) AS at FROM watched_movies
             WHERE user_id IN (SELECT id FROM friends)
             GROUP BY 1, 2 HAVING COUNT(*) > ${BULK_WATCH_SIZE}
         ), bulk_added AS (
             SELECT l.user_id, date_trunc('second', lm.added_at) AS at
             FROM list_movies lm JOIN lists l ON l.id = lm.list_id
             WHERE l.user_id IN (SELECT id FROM friends) AND lm.added_at > NOW() - INTERVAL '24 hours'
             GROUP BY 1, 2 HAVING COUNT(*) > ${BULK_WATCH_SIZE}
         ), events AS (
             SELECT w.user_id, w.movie_id, 'watched' AS kind, w.watched_at AS at, NULL::int AS rank, NULL AS list_name
             FROM watched_movies w
             WHERE w.user_id IN (SELECT id FROM friends) AND w.watched_at > NOW() - INTERVAL '24 hours'
               AND (w.user_id, date_trunc('second', w.watched_at)) NOT IN (SELECT user_id, at FROM bulk)
             UNION ALL
             SELECT wl.user_id, wl.movie_id, 'rewatched', wl.created_at, NULL, NULL
             FROM watch_log wl
             WHERE wl.user_id IN (SELECT id FROM friends) AND wl.created_at > NOW() - INTERVAL '24 hours'
             UNION ALL
             SELECT l.user_id, lm.movie_id, 'ranked', lm.added_at, lm.rank, l.name
             FROM list_movies lm JOIN lists l ON l.id = lm.list_id
             WHERE l.user_id IN (SELECT id FROM friends) AND lm.added_at > NOW() - INTERVAL '24 hours'
               AND l.visibility <> 'private'
               AND (l.user_id, date_trunc('second', lm.added_at)) NOT IN (SELECT user_id, at FROM bulk_added)
         )
         SELECT e.kind, e.rank, e.list_name, e.at, fr.name AS friend, fr.handle, m.title, m.release_date,
                (SELECT ml.name FROM lists ml JOIN list_movies mlm ON mlm.list_id = ml.id
                 WHERE ml.user_id = $1 AND mlm.movie_id = e.movie_id
                 ORDER BY (ml.name ILIKE '%watch%') DESC LIMIT 1) AS my_list
         FROM events e JOIN friends fr ON fr.id = e.user_id JOIN movies m ON m.id = e.movie_id
         ORDER BY e.at DESC`,
        [user_id]
    );
    return result.rows;
}

/// Films added in the last day to other people's lists the user follows and can still see, one row per list
/// with how many were added and the most recent one. Bulk additions (imports) are left out
async function fetchFollowedListUpdates(user_id) {
    const result = await pool.query(
        `WITH followed AS (
             SELECT l.id, l.name, l.user_id, o.username AS owner, o.handle
             FROM list_follows lf JOIN lists l ON l.id = lf.list_id JOIN users o ON o.firebase_uid = l.user_id
             WHERE lf.user_id = $1 AND l.user_id <> $1 AND ${visibleTo("$1")}
         ), added AS (
             SELECT lm.list_id, lm.added_at, m.title, m.release_date,
                    COUNT(*) OVER (PARTITION BY lm.list_id, date_trunc('second', lm.added_at)) AS same_second
             FROM list_movies lm JOIN movies m ON m.id = lm.movie_id
             WHERE lm.list_id IN (SELECT id FROM followed) AND lm.added_at > NOW() - INTERVAL '24 hours'
         )
         SELECT f.name AS list_name, f.owner, f.handle, COUNT(*)::int AS added,
                (ARRAY_AGG(a.title ORDER BY a.added_at DESC))[1] AS title,
                (ARRAY_AGG(a.release_date ORDER BY a.added_at DESC))[1] AS release_date
         FROM added a JOIN followed f ON f.id = a.list_id
         WHERE a.same_second <= ${BULK_WATCH_SIZE}
         GROUP BY f.name, f.owner, f.handle
         ORDER BY added DESC`,
        [user_id]
    );
    return result.rows.map((row) => ({ kind: "list_update", friend: row.owner, handle: row.handle, ...row }));
}

// How interesting an event is to this user: a film on their watchlist matters most, then a friend's new
// top-10 placing, then a film the user already has, then anything else
function score(event) {
    // Someone chose to follow this list, so its updates come first
    if (event.kind === "list_update") return 80 + event.added;
    let points = 0;
    if (event.my_list && /watch/i.test(event.my_list)) points += 100;
    else if (event.my_list) points += 30;
    if (event.kind === "ranked" && event.rank && event.rank <= 10) points += 50 - event.rank;
    if (event.kind === "watched") points += 10;
    return points;
}

function describe(event) {
    const film = filmLabel(event);
    const onWatchlist = event.my_list && /watch/i.test(event.my_list);
    switch (event.kind) {
        case "list_update": {
            const more = event.added - 1;
            return `${event.friend} added ${film}${more ? ` and ${more} more` : ""} to ${event.list_name}`;
        }
        case "ranked":
            if (onWatchlist) return `${event.friend} added ${film}, which is on your watchlist`;
            if (event.rank && event.rank <= 10) return `${event.friend} ranked ${film} #${event.rank} in ${event.list_name}`;
            return `${event.friend} added ${film} to ${event.list_name}`;
        case "rewatched":
            return `${event.friend} rewatched ${film}${onWatchlist ? ", which is on your watchlist" : ""}`;
        default:
            return `${event.friend} watched ${film}${onWatchlist ? ", which is on your watchlist" : ""}`;
    }
}

/// Builds today's digest for one user, or null when their friends did nothing worth a notification
async function buildDigest(user_id) {
    const events = [...await fetchFollowedListUpdates(user_id), ...await fetchFriendActivity(user_id)];
    if (!events.length) return null;
    const best = [...events].sort((a, b) => score(b) - score(a))[0];
    // The same film can show up more than once (added to a followed list and ranked), so count each friend's
    // film once; a followed list update counts as however many films were added
    const key = (e) => `${e.friend}|${e.title}`;
    const distinct = new Set(events.map(key));
    const extraFromList = best.kind === "list_update" ? best.added - 1 : 0;
    const others = Math.max(distinct.size - 1 - extraFromList, 0);
    const friends = new Set(events.map((e) => e.friend)).size;
    return {
        title: friends > 1 ? `${friends} friends were busy today` : "From your friends",
        body: others ? `${describe(best)}, and ${others} more` : describe(best),
        data: { handle: best.handle ?? "" },
    };
}

/// Sends the daily digest to everyone who wants it, has a device and hasn't had one in the last 20 hours.
/// Returns how many people were sent one
async function sendDailyDigests() {
    const people = await pool.query(
        `SELECT DISTINCT u.firebase_uid FROM users u JOIN device_tokens t ON t.user_id = u.firebase_uid
         WHERE u.notify_activity AND (u.last_digest_at IS NULL OR u.last_digest_at < NOW() - INTERVAL '20 hours')
           AND (EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = u.firebase_uid AND f.accepted)
                OR EXISTS (SELECT 1 FROM list_follows lf WHERE lf.user_id = u.firebase_uid))`
    );
    let sent = 0;
    for (const { firebase_uid } of people.rows) {
        try {
            const digest = await buildDigest(firebase_uid);
            if (!digest) continue;
            if (await notifyUser(firebase_uid, "activity", digest)) {
                sent++;
                await pool.query("UPDATE users SET last_digest_at = NOW() WHERE firebase_uid = $1", [firebase_uid]);
            }
        } catch (error) {
            console.error("Couldn't build a digest:", error.message);
        }
    }
    return { candidates: people.rows.length, sent };
}

module.exports = { sendDailyDigests, buildDigest, fetchFriendActivity, fetchFollowedListUpdates, describe };
