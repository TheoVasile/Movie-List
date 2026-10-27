const pool = require("../config/db");
const { visibleTo, notBlocked } = require("./listModel");

// @usernames: 3-20 lowercase letters, digits, underscores and dots, not starting or ending with a dot
// and without two dots in a row
const HANDLE_PATTERN = /^(?!\.)(?!.*\.\.)(?!.*\.$)[a-z0-9_.]{3,20}$/;

class HandleTakenError extends Error {}

function isValidHandle(handle) {
    return typeof handle === "string" && HANDLE_PATTERN.test(handle);
}

// The signed-in user's @username (null until they pick one), display name and follow counts. Only ever for the
// user themselves: it includes their birthday and phone number
async function getProfile(user_id) {
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, u.ai_allowed, u.notify_requests, u.notify_activity,
                u.phone IS NOT NULL AS has_phone, u.phone, u.is_private, u.terms_version,
                TO_CHAR(u.birthday, 'YYYY-MM-DD') AS birthday,
                (SELECT COUNT(*) FROM follows WHERE followee_id = u.firebase_uid AND accepted)::int AS followers,
                (SELECT COUNT(*) FROM follows WHERE follower_id = u.firebase_uid AND accepted)::int AS following,
                (SELECT COUNT(*) FROM follows WHERE followee_id = u.firebase_uid AND NOT accepted)::int AS requests,
                (SELECT COUNT(*) FROM film_recommendations r WHERE r.recipient_id = u.firebase_uid AND NOT r.seen
                   AND ${notBlocked("u.firebase_uid", "r.sender_id")})::int AS recommendations_unseen
         FROM users u WHERE u.firebase_uid = $1`,
        [user_id]
    );
    return result.rows[0] ?? null;
}

// Changes the user's display name. It has to be unique, so a name someone else already has gets part of the
// account id added, the same way as at sign-up. Returns the name that was saved
async function setDisplayName(user_id, name) {
    const update = (value) => pool.query("UPDATE users SET username = $2 WHERE firebase_uid = $1 RETURNING username", [user_id, value]);
    try {
        return (await update(name)).rows[0]?.username ?? null;
    } catch (error) {
        if (error.code !== "23505" || error.constraint !== "users_username_key") throw error;
        return (await update(`${name} ${user_id.slice(0, 6)}`.slice(0, 50))).rows[0]?.username ?? null;
    }
}

// Contact matching works on SHA-256 hashes made on the phone of the user's contacts: of an email, lowercased and
// trimmed; of a phone number, its last 10 digits (so numbers saved with or without a country code match).
// Hashes sent for matching are compared and never stored
const isHash = (value) => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);

/// Saves the user's verified phone number (international format, from their Firebase account), or removes it
/// with null
async function setPhone(user_id, phone) {
    await pool.query("UPDATE users SET phone = $2 WHERE firebase_uid = $1", [user_id, phone]);
}

// People on Marquee whose email or phone hash is among the user's contacts', with whether the user follows
// them or has asked to. Only people with a @username, since that's how they're shown
async function matchContacts(user_id, emailHashes, phoneHashes) {
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND f.accepted) AS following,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND NOT f.accepted) AS requested
         FROM users u
         WHERE u.firebase_uid <> $1 AND u.handle IS NOT NULL AND ${notBlocked("$1", "u.firebase_uid")}
           AND (encode(sha256(lower(trim(u.email))::bytea), 'hex') = ANY($2::text[]) OR encode(sha256(right(regexp_replace(u.phone, '\\D', '', 'g'), 10)::bytea), 'hex') = ANY($3::text[]))
         ORDER BY u.username
         LIMIT 200`,
        [user_id, emailHashes, phoneHashes]
    );
    return result.rows;
}

// The user's profile picture: a small JPEG the app has already cropped and shrunk. null removes it
async function setAvatar(user_id, jpeg) {
    await pool.query(
        "UPDATE users SET avatar = $2, avatar_updated_at = CASE WHEN $2::bytea IS NULL THEN NULL ELSE NOW() END WHERE firebase_uid = $1",
        [user_id, jpeg]
    );
}

// The profile picture of the user (user_id), or of @handle as viewer_id sees it, null when there isn't one. None
// when either has blocked the other, like their profile. A private account's picture is still shown, as it is
// next to their name in search and follow requests, so people can tell who they're asking to follow
async function fetchAvatar({ user_id, handle, viewer_id }) {
    const result = user_id
        ? await pool.query("SELECT avatar FROM users WHERE firebase_uid = $1", [user_id])
        : await pool.query(`SELECT avatar FROM users u WHERE u.handle = $1 AND ${notBlocked("$2", "u.firebase_uid")}`, [handle, viewer_id]);
    return result.rows[0]?.avatar ?? null;
}

async function setAIAllowed(user_id, allowed) {
    await pool.query("UPDATE users SET ai_allowed = $2 WHERE firebase_uid = $1", [user_id, allowed]);
}

// Saves the user's birthday as "yyyy-MM-dd", or removes it with null
async function setBirthday(user_id, birthday) {
    const result = await pool.query(
        "UPDATE users SET birthday = $2 WHERE firebase_uid = $1 RETURNING TO_CHAR(birthday, 'YYYY-MM-DD') AS birthday",
        [user_id, birthday]
    );
    return result.rowCount ? { birthday: result.rows[0].birthday } : null;
}

async function setHandle(user_id, handle) {
    try {
        await pool.query("UPDATE users SET handle = $2 WHERE firebase_uid = $1", [user_id, handle]);
    } catch (error) {
        // 23505: unique violation, someone else has it
        if (error.code === "23505") throw new HandleTakenError(handle);
        throw error;
    }
}

// People whose @username starts with the query, with whether the user follows them or has asked to
async function searchUsers(user_id, query) {
    // "_" is a LIKE wildcard, so it's escaped to match only itself
    const prefix = query.replace(/_/g, "\\_");
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND f.accepted) AS following,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND NOT f.accepted) AS requested
         FROM users u
         WHERE u.handle LIKE $2 || '%' ESCAPE '\\' AND u.firebase_uid <> $1 AND ${notBlocked("$1", "u.firebase_uid")}
         ORDER BY u.handle
         LIMIT 20`,
        [user_id, prefix]
    );
    return result.rows;
}

// Following a public profile is immediate; following a private one sends a request. Unfollowing also cancels a
// request. Returns null when there's no one with that @username (or it's the user's own), otherwise
// { followee_id, following, requested, isNewRequest, isNewFollow }
async function setFollowing(user_id, handle, follow) {
    const target = await pool.query(
        `SELECT firebase_uid, is_private FROM users u WHERE handle = $1 AND firebase_uid <> $2 AND ${notBlocked("$2", "u.firebase_uid")}`,
        [handle, user_id]
    );
    if (!target.rows.length) return null;
    const followee_id = target.rows[0].firebase_uid;
    if (!follow) {
        await pool.query("DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2", [user_id, followee_id]);
        return { followee_id, following: false, requested: false, isNewRequest: false, isNewFollow: false };
    }
    const inserted = await pool.query(
        `INSERT INTO follows (follower_id, followee_id, accepted) VALUES ($1, $2, $3)
         ON CONFLICT DO NOTHING RETURNING accepted`,
        [user_id, followee_id, !target.rows[0].is_private]
    );
    const row = inserted.rows[0] ?? (await pool.query(
        "SELECT accepted FROM follows WHERE follower_id = $1 AND followee_id = $2", [user_id, followee_id]
    )).rows[0];
    const isNew = inserted.rowCount > 0;
    return { followee_id, following: row.accepted, requested: !row.accepted, isNewRequest: isNew && !row.accepted, isNewFollow: isNew && row.accepted };
}

// Makes the user's profile private or public. Going public accepts everyone waiting (returned as account ids, to
// tell them); going private makes their public lists followers-only, since only followers can see a private
// profile's lists
async function setPrivate(user_id, isPrivate) {
    await pool.query("UPDATE users SET is_private = $2 WHERE firebase_uid = $1", [user_id, isPrivate]);
    if (isPrivate) {
        await pool.query("UPDATE lists SET visibility = 'followers' WHERE user_id = $1 AND visibility = 'public'", [user_id]);
        return [];
    }
    const accepted = await pool.query(
        "UPDATE follows SET accepted = true WHERE followee_id = $1 AND NOT accepted RETURNING follower_id",
        [user_id]
    );
    return accepted.rows.map((row) => row.follower_id);
}

/// Whether the user's profile is private
async function isPrivate(user_id) {
    const result = await pool.query("SELECT is_private FROM users WHERE firebase_uid = $1", [user_id]);
    return result.rows[0]?.is_private === true;
}

// People asking to follow the user (newest first), and the @usernames of people the user has asked to follow
async function fetchFollowRequests(user_id) {
    const incoming = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, false AS following
         FROM follows f JOIN users u ON u.firebase_uid = f.follower_id
         WHERE f.followee_id = $1 AND NOT f.accepted AND u.handle IS NOT NULL
         ORDER BY f.created_at DESC`,
        [user_id]
    );
    const outgoing = await pool.query(
        `SELECT u.handle FROM follows f JOIN users u ON u.firebase_uid = f.followee_id
         WHERE f.follower_id = $1 AND NOT f.accepted AND u.handle IS NOT NULL`,
        [user_id]
    );
    return { incoming: incoming.rows, outgoing: outgoing.rows.map((row) => row.handle) };
}

// Accepts or declines @handle's request to follow the user. Returns the requester's account id, or null when
// there's no such request
async function respondToFollowRequest(user_id, handle, accept) {
    const requester = await pool.query("SELECT firebase_uid FROM users WHERE handle = $1", [handle]);
    const follower_id = requester.rows[0]?.firebase_uid;
    if (!follower_id) return null;
    const result = accept
        ? await pool.query("UPDATE follows SET accepted = true WHERE follower_id = $1 AND followee_id = $2 AND NOT accepted", [follower_id, user_id])
        : await pool.query("DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2 AND NOT accepted", [follower_id, user_id]);
    return result.rowCount ? follower_id : null;
}

// Everyone the user follows, newest first, with how many lists and films each has
async function fetchFollowing(user_id) {
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, TRUE AS following,
                (SELECT COUNT(*) FROM lists l WHERE l.user_id = u.firebase_uid)::int AS list_count,
                (SELECT COUNT(*) FROM lists l JOIN list_movies lm ON lm.list_id = l.id WHERE l.user_id = u.firebase_uid)::int AS film_count
         FROM follows f JOIN users u ON u.firebase_uid = f.followee_id
         WHERE f.follower_id = $1 AND f.accepted
         ORDER BY f.created_at DESC`,
        [user_id]
    );
    return result.rows;
}

// Someone's followers or the people they follow, newest first, each with whether the viewer follows them or
// has asked to. Anyone can see their own; other people's only once the viewer's follow is accepted. Returns
// null when there's no such user, and { hidden: true } when the viewer isn't allowed to see them
async function fetchConnections(viewer_id, { handle, which }) {
    let target_id = viewer_id;
    if (handle) {
        const target = await pool.query(
            `SELECT u.firebase_uid,
                    EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND f.accepted) AS following
             FROM users u WHERE u.handle = $2 AND ${notBlocked("$1", "u.firebase_uid")}`,
            [viewer_id, handle]
        );
        const person = target.rows[0];
        if (!person) return null;
        if (person.firebase_uid !== viewer_id && !person.following) return { hidden: true };
        target_id = person.firebase_uid;
    }
    // followers: people who follow the target; following: people the target follows
    const [personColumn, targetColumn] = which === "followers" ? ["follower_id", "followee_id"] : ["followee_id", "follower_id"];
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version,
                EXISTS (SELECT 1 FROM follows v WHERE v.follower_id = $2 AND v.followee_id = u.firebase_uid AND v.accepted) AS following,
                EXISTS (SELECT 1 FROM follows v WHERE v.follower_id = $2 AND v.followee_id = u.firebase_uid AND NOT v.accepted) AS requested,
                u.firebase_uid = $2 AS is_me
         FROM follows f JOIN users u ON u.firebase_uid = f.${personColumn}
         WHERE f.${targetColumn} = $1 AND f.accepted AND u.handle IS NOT NULL AND ${notBlocked("$2", "u.firebase_uid")}
         ORDER BY f.created_at DESC`,
        [target_id, viewer_id]
    );
    return { people: result.rows };
}

// Someone's lists with their films in rank order and which they've watched, for a user who follows them.
// Notes are shown per film on its info screen instead (fetchFriendsOnFilm). null when there's no such user; { following: false } when the
// user doesn't follow them
async function fetchUserLists(user_id, handle) {
    const target = await pool.query(
        `SELECT u.firebase_uid, u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, u.ai_allowed, u.is_private,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND f.accepted) AS following,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND NOT f.accepted) AS requested,
                (SELECT COUNT(*) FROM follows f WHERE f.followee_id = u.firebase_uid AND f.accepted)::int AS follower_count,
                (SELECT COUNT(*) FROM follows f WHERE f.follower_id = u.firebase_uid AND f.accepted)::int AS following_count
         FROM users u WHERE u.handle = $2 AND ${notBlocked("$1", "u.firebase_uid")}`,
        [user_id, handle]
    );
    const person = target.rows[0];
    if (!person) return null;
    const profile = { handle: person.handle, display_name: person.display_name, avatar_version: person.avatar_version, following: person.following, requested: person.requested,
                      is_private: person.is_private,
                      follower_count: person.follower_count, following_count: person.following_count, lists: [] };
    // Only followers learn whether someone allows AI, since it decides whether they can plan a Movie Night
    if (person.following) profile.ai_allowed = person.ai_allowed;
    // Followers see public and followers-only lists; anyone else sees only public ones
    profile.lists = await fetchListsWithFilms(user_id, "l.user_id = $2", [person.firebase_uid]);
    return profile;
}

// Lists matching a condition that the viewer ($1) can see, each with its films in rank order, which the owner
// has watched (with each film's overview, for its info screen), its visibility, how many follow it and whether the viewer does. $2 onwards are params
async function fetchListsWithFilms(viewer_id, condition, params) {
    const rows = await pool.query(
        `SELECT l.id AS list_id, l.name, l.overview, l.visibility, l.is_ranked, o.handle AS owner_handle, o.username AS owner_name,
                EXISTS (SELECT 1 FROM list_follows lf WHERE lf.user_id = $1 AND lf.list_id = l.id) AS followed,
                (SELECT COUNT(*) FROM list_follows lf WHERE lf.list_id = l.id)::int AS follower_count,
                m.tmdb_id, m.title, m.release_date, m.poster_path, lm.rank,
                m.overview AS film_overview, m.original_language, m.popularity,
                (w.movie_id IS NOT NULL) AS watched
         FROM lists l
         JOIN users o ON o.firebase_uid = l.user_id
         LEFT JOIN list_movies lm ON lm.list_id = l.id
         LEFT JOIN movies m ON m.id = lm.movie_id
         LEFT JOIN watched_movies w ON w.user_id = l.user_id AND w.movie_id = m.id
         WHERE ${condition} AND ${visibleTo("$1")}
         ORDER BY l.id, lm.rank NULLS LAST`,
        [viewer_id, ...params]
    );
    const lists = new Map();
    for (const row of rows.rows) {
        if (!lists.has(row.list_id)) {
            lists.set(row.list_id, {
                id: row.list_id, name: row.name, overview: row.overview ?? "", visibility: row.visibility, is_ranked: row.is_ranked !== false,
                owner_handle: row.owner_handle, owner_name: row.owner_name,
                followed: row.followed, follower_count: row.follower_count, movies: [],
            });
        }
        if (row.tmdb_id) {
            lists.get(row.list_id).movies.push({
                tmdb_id: Number(row.tmdb_id),
                title: row.title,
                release_date: row.release_date ?? "",
                poster_path: row.poster_path || null,
                rank: row.rank,
                watched: row.watched,
                // For the film info screen
                overview: row.film_overview ?? "",
                original_language: row.original_language ?? "",
                popularity: row.popularity ?? 0,
            });
        }
    }
    return [...lists.values()];
}

// Other people's lists the user follows and can still see, most recently followed first
async function fetchFollowedLists(user_id) {
    const lists = await fetchListsWithFilms(user_id, "l.id IN (SELECT list_id FROM list_follows WHERE user_id = $1) AND l.user_id <> $1", []);
    return lists;
}

// What the people the user follows have to say about one film: whether they've watched it, their note (unless
// moderation is holding it for review), and their best placing of it in a list. Only people with at least one of
// those are returned, people with a note first
async function fetchFriendsOnFilm(user_id, tmdb_id) {
    const result = await pool.query(
        `WITH film AS (SELECT id FROM movies WHERE tmdb_id = $2::text)
         SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version,
                EXISTS (SELECT 1 FROM watched_movies w WHERE w.user_id = u.firebase_uid AND w.movie_id IN (SELECT id FROM film)) AS watched,
                (SELECT n.note FROM movie_notes n WHERE n.user_id = u.firebase_uid AND n.movie_id IN (SELECT id FROM film)
                   AND n.moderation_status = 'ok') AS note,
                (SELECT json_build_object('list_name', l.name, 'rank', lm.rank, 'list_size', (SELECT COUNT(*) FROM list_movies c WHERE c.list_id = l.id))
                 FROM lists l JOIN list_movies lm ON lm.list_id = l.id
                 WHERE l.user_id = u.firebase_uid AND lm.movie_id IN (SELECT id FROM film) AND l.visibility <> 'private' AND l.is_ranked
                 ORDER BY lm.rank LIMIT 1) AS ranking
         FROM follows f JOIN users u ON u.firebase_uid = f.followee_id
         WHERE f.follower_id = $1 AND f.accepted`,
        [user_id, String(tmdb_id)]
    );
    return result.rows
        .filter((row) => row.watched || row.note || row.ranking)
        .sort((a, b) => Number(Boolean(b.note)) - Number(Boolean(a.note)) || a.handle.localeCompare(b.handle));
}

/// Blocks whoever has @handle: unfollows both ways (and drops requests), takes each off the other's lists as an
/// editor and follower, out of each other's movie night groups, and deletes the films they sent each other. Returns false when there's no such person
async function blockUser(user_id, handle) {
    const target = await pool.query("SELECT firebase_uid FROM users WHERE handle = $1 AND firebase_uid <> $2", [handle, user_id]);
    const other_id = target.rows[0]?.firebase_uid;
    if (!other_id) return false;
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        await client.query("INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", [user_id, other_id]);
        await client.query(
            "DELETE FROM follows WHERE (follower_id = $1 AND followee_id = $2) OR (follower_id = $2 AND followee_id = $1)",
            [user_id, other_id]
        );
        for (const [owner, other] of [[user_id, other_id], [other_id, user_id]]) {
            await client.query("DELETE FROM list_editors WHERE user_id = $2 AND list_id IN (SELECT id FROM lists WHERE user_id = $1)", [owner, other]);
            await client.query("DELETE FROM list_follows WHERE user_id = $2 AND list_id IN (SELECT id FROM lists WHERE user_id = $1)", [owner, other]);
            await client.query(
                "DELETE FROM watch_group_members WHERE user_id = $2 AND group_id IN (SELECT id FROM watch_groups WHERE owner_id = $1)",
                [owner, other]
            );
            await client.query("DELETE FROM film_recommendations WHERE sender_id = $1 AND recipient_id = $2", [owner, other]);
        }
        await client.query("COMMIT");
        return true;
    } catch (error) {
        await client.query("ROLLBACK");
        throw error;
    } finally {
        client.release();
    }
}

/// Unblocks whoever has @handle. They don't come back as followers; either can follow again
async function unblockUser(user_id, handle) {
    const result = await pool.query(
        "DELETE FROM blocks b USING users u WHERE b.blocker_id = $1 AND b.blocked_id = u.firebase_uid AND u.handle = $2",
        [user_id, handle]
    );
    return result.rowCount > 0;
}

/// Everyone the user has blocked, most recent first
async function fetchBlocked(user_id) {
    const result = await pool.query(
        `SELECT u.handle, u.username AS display_name, FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, false AS following
         FROM blocks b JOIN users u ON u.firebase_uid = b.blocked_id
         WHERE b.blocker_id = $1 AND u.handle IS NOT NULL
         ORDER BY b.created_at DESC`,
        [user_id]
    );
    return result.rows;
}

module.exports = { notBlocked, blockUser, unblockUser, fetchBlocked, setPrivate, isPrivate, isHash, setPhone, matchContacts, isValidHandle, getProfile, setAvatar, fetchAvatar, setDisplayName, setAIAllowed, setBirthday, setHandle, searchUsers, setFollowing, fetchFollowRequests, respondToFollowRequest, fetchConnections, fetchFollowing, fetchUserLists, fetchFollowedLists, fetchFriendsOnFilm, HandleTakenError };
