const pool = require("../config/db");
const { visibleTo, notBlocked } = require("./listModel");
const tmdbCache = require("../services/tmdbCache");
const { isTV, tmdbPath, filmGenres } = require("../services/tmdbMedia");
const { computeTasteMatch, placesFrom } = require("../services/tasteMatch");

// Films from each person's ranked lists whose genres are looked up: the top of their rankings, which say the most
const GENRE_FILMS_PER_PERSON = 40;
const GENRE_LOOKUPS_AT_ONCE = 10;

// Every film in owner_id's ranked lists that viewer_id can see (all of them when they're the same person), with its
// position in its list (1 = top) and the list's size. Watchlists and unranked lists are left out, since their order
// isn't a ranking
async function fetchRankedFilms(viewer_id, owner_id) {
    const result = await pool.query(
        `SELECT m.tmdb_id, m.title, m.poster_path, m.release_date, l.id AS list_id,
                ROW_NUMBER() OVER (PARTITION BY l.id ORDER BY lm.rank NULLS LAST, lm.id) AS position,
                COUNT(*) OVER (PARTITION BY l.id) AS list_size
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         WHERE l.user_id = $2 AND l.is_ranked AND l.name NOT ILIKE '%watch%' AND ${visibleTo("$1")}`,
        [viewer_id, owner_id]
    );
    return result.rows;
}

// A film's TMDb genre ids (shows' as the closest film genres), kept for a month. null when TMDb can't say
async function genresFor(tmdb_id) {
    try {
        return await tmdbCache.cached(`genres:${tmdb_id}`, 30 * tmdbCache.DAY, async () => {
            const details = await tmdbCache.fetchTmdb(tmdbPath(tmdb_id));
            const ids = (details.genres ?? []).map((genre) => genre.id);
            return isTV(tmdb_id) ? filmGenres(ids) : ids;
        });
    } catch {
        return null;
    }
}

async function lookUpGenres(ids) {
    const genres = new Map();
    for (let i = 0; i < ids.length; i += GENRE_LOOKUPS_AT_ONCE) {
        const batch = ids.slice(i, i + GENRE_LOOKUPS_AT_ONCE);
        const found = await Promise.all(batch.map(genresFor));
        batch.forEach((id, index) => genres.set(id, found[index]));
    }
    return genres;
}

const personOf = (row) => ({ handle: row.handle, display_name: row.display_name, avatar_version: row.avatar_version });

/// The Taste Match between the signed-in user and the person with this @handle, from the user's own ranked lists
/// and the other person's ranked lists the user is allowed to see. null when there's no such person, or one of them
/// has blocked the other. Throws a SelfMatchError for the user's own handle
async function tasteMatch(user_id, handle) {
    const result = await pool.query(
        `SELECT u.firebase_uid, u.handle, u.username AS display_name,
                FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version
         FROM users u
         WHERE u.firebase_uid = $1 OR (u.handle = $2 AND ${notBlocked("$1", "u.firebase_uid")})`,
        [user_id, handle]
    );
    const me = result.rows.find((row) => row.firebase_uid === user_id);
    const them = result.rows.find((row) => row.firebase_uid !== user_id);
    if (me?.handle === handle) throw new SelfMatchError();
    if (!me || !them) return null;

    const [myRows, theirRows] = await Promise.all([fetchRankedFilms(user_id, user_id), fetchRankedFilms(user_id, them.firebase_uid)]);
    const mine = placesFrom(myRows), theirs = placesFrom(theirRows);

    const top = (films) => [...films.values()].sort((a, b) => a.place - b.place).slice(0, GENRE_FILMS_PER_PERSON).map((film) => film.tmdb_id);
    const shared = [...mine.keys()].filter((id) => theirs.has(id));
    const genres = await lookUpGenres([...new Set([...top(mine), ...top(theirs), ...shared.slice(0, GENRE_FILMS_PER_PERSON)])]);

    return { me: personOf(me), them: personOf(them), ...computeTasteMatch(mine, theirs, (id) => genres.get(id)) };
}

class SelfMatchError extends Error {}

module.exports = { tasteMatch, SelfMatchError };
