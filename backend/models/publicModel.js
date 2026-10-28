const pool = require("../config/db");
const { getMovieByTmdbId, fetchMovieFields, parseTmdbId } = require("./movieModel");
const { createInviteService, sqlStore } = require("./inviteModel");
const { MAX_MEMBERS } = require("./groupModel");

// What the public web pages (/l, /u, /f, /i, /join) show to anyone with the link, signed in or not. Only public
// lists of profiles that aren't private, and profiles that aren't private, are ever read here; never emails,
// birthdays, phone numbers or anything else private. routes/publicRoutes.js checks the same rules again
// (canShowList, canShowProfile) before showing anything

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HANDLE = /^[a-z0-9._]{1,20}$/;
// Films shown on a list's page, and lists on a profile's
const LIST_FILMS = 25;
const PROFILE_LISTS = 3;

const isPublicId = (value) => typeof value === "string" && UUID.test(value);
const normalHandle = (value) => (typeof value === "string" && HANDLE.test(value.toLowerCase()) ? value.toLowerCase() : null);

/// A public list by its public id, with its owner and first films: { public_id, name, overview, visibility,
/// is_ranked, owner_handle, owner_name, owner_private, film_count, films: [{ tmdb_id, title, release_date,
/// poster_path, rank }] }, or null
async function publicList(publicId) {
    if (!isPublicId(publicId)) return null;
    const list = await pool.query(
        `SELECT l.id, l.public_id, l.name, l.overview, l.visibility, l.is_ranked, o.handle AS owner_handle,
                o.username AS owner_name, o.is_private AS owner_private,
                (SELECT COUNT(*) FROM list_movies lm WHERE lm.list_id = l.id)::int AS film_count
         FROM lists l JOIN users o ON o.firebase_uid = l.user_id
         WHERE l.public_id = $1 AND l.visibility = 'public' AND NOT o.is_private AND o.handle IS NOT NULL`,
        [publicId]
    );
    const row = list.rows[0];
    if (!row) return null;
    const films = await pool.query(
        `SELECT m.tmdb_id, m.title, m.release_date, m.poster_path, lm.rank
         FROM list_movies lm JOIN movies m ON m.id = lm.movie_id
         WHERE lm.list_id = $1 ORDER BY lm.rank NULLS LAST, lm.id LIMIT $2`,
        [row.id, LIST_FILMS]
    );
    const { id, ...rest } = row;
    return { ...rest, films: films.rows };
}

/// A profile that isn't private: { handle, display_name, is_private, has_avatar, avatar_version, followers,
/// following, list_count, lists: [{ public_id, name, film_count, posters: [path] }] }, or null
async function publicProfile(handle) {
    const h = normalHandle(handle);
    if (!h) return null;
    const user = await pool.query(
        `SELECT u.firebase_uid, u.handle, u.username AS display_name, u.is_private, u.avatar_updated_at IS NOT NULL AS has_avatar,
                FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version,
                (SELECT COUNT(*) FROM follows f WHERE f.followee_id = u.firebase_uid AND f.accepted)::int AS followers,
                (SELECT COUNT(*) FROM follows f WHERE f.follower_id = u.firebase_uid AND f.accepted)::int AS following,
                (SELECT COUNT(*) FROM lists l WHERE l.user_id = u.firebase_uid AND l.visibility = 'public')::int AS list_count
         FROM users u WHERE u.handle = $1 AND NOT u.is_private`,
        [h]
    );
    const row = user.rows[0];
    if (!row) return null;
    const lists = await pool.query(
        `SELECT l.public_id, l.name,
                (SELECT COUNT(*) FROM list_movies lm WHERE lm.list_id = l.id)::int AS film_count,
                ARRAY(SELECT m.poster_path FROM list_movies lm JOIN movies m ON m.id = lm.movie_id
                      WHERE lm.list_id = l.id AND m.poster_path <> '' ORDER BY lm.rank NULLS LAST, lm.id LIMIT 4) AS posters
         FROM lists l WHERE l.user_id = $1 AND l.visibility = 'public'
         ORDER BY film_count DESC, l.date_modified DESC NULLS LAST LIMIT $2`,
        [row.firebase_uid, PROFILE_LISTS]
    );
    const { firebase_uid, ...rest } = row;
    return { ...rest, lists: lists.rows };
}

/// A profile picture (JPEG bytes) for a profile that isn't private, or null
async function publicAvatar(handle) {
    const h = normalHandle(handle);
    if (!h) return null;
    const result = await pool.query("SELECT avatar FROM users WHERE handle = $1 AND NOT is_private", [h]);
    return result.rows[0]?.avatar ?? null;
}

/// Who a personal invite (/i/<handle>) is from: { handle, display_name, is_private }, or null. A private profile's
/// invite shows only its @handle
async function invitingUser(handle) {
    const h = normalHandle(handle);
    if (!h) return null;
    const result = await pool.query("SELECT handle, username AS display_name, is_private FROM users WHERE handle = $1", [h]);
    return result.rows[0] ?? null;
}

/// A film or show by TMDb id: { tmdb_id, title, release_date, overview, poster_path }, from the saved copy or
/// TMDb. Nothing is saved for a film nobody has added. null when there's no such film
async function publicFilm(tmdbId) {
    const id = parseTmdbId(tmdbId);
    if (id === null) return null;
    const saved = await getMovieByTmdbId(id);
    if (saved) return { tmdb_id: id, title: saved.title, release_date: saved.release_date, overview: saved.overview, poster_path: saved.poster_path };
    try {
        const film = await fetchMovieFields(id);
        return film ? { tmdb_id: id, ...film } : null;
    } catch (error) {
        if (error.response?.status === 404) return null;
        throw error;
    }
}

const invites = createInviteService(sqlStore(pool), { maxMembers: MAX_MEMBERS });

/// What a group invite link leads to, or null when it doesn't work
const groupInvite = (token) => invites.preview(token);

module.exports = { isPublicId, normalHandle, publicList, publicProfile, publicAvatar, invitingUser, publicFilm, groupInvite, invites };
