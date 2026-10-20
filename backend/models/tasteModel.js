const pool = require("../config/db");

// Every film in the user's lists, grouped by list (largest list first) and in rank order, with
// whether the user has marked it watched. Used to describe the user's taste to the AI
async function fetchListsForTaste(user_id) {
    const result = await pool.query(
        `SELECT l.id AS list_id, l.name AS list_name, m.title, m.release_date, m.original_language, lm.rank,
                (w.movie_id IS NOT NULL) AS watched
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         LEFT JOIN watched_movies w ON w.user_id = l.user_id AND w.movie_id = m.id
         WHERE l.user_id = $1
         ORDER BY l.id, lm.rank NULLS LAST`,
        [user_id]
    );
    const lists = new Map();
    for (const row of result.rows) {
        if (!lists.has(row.list_id)) {
            lists.set(row.list_id, { name: row.list_name, films: [] });
        }
        lists.get(row.list_id).films.push({
            title: row.title,
            year: String(row.release_date ?? "").slice(0, 4),
            language: row.original_language ?? "",
            watched: row.watched,
        });
    }
    return [...lists.values()].sort((a, b) => b.films.length - a.films.length);
}

// TMDb ids of every film in the user's lists, so recommendations can leave them out
async function fetchListedTmdbIds(user_id) {
    const result = await pool.query(
        `SELECT DISTINCT m.tmdb_id
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         WHERE l.user_id = $1`,
        [user_id]
    );
    return new Set(result.rows.map((row) => Number(row.tmdb_id)));
}

// The account behind a @handle, whether user_id follows it, and whether both of them allow AI features.
// Following is what lets a user see someone's lists, and both allowing AI is what lets their lists go to
// the AI together, so these decide whether they can plan a movie night. Null if no one has the handle
async function fetchFriend(user_id, handle) {
    const result = await pool.query(
        `SELECT u.firebase_uid, u.handle, u.username AS display_name, u.ai_allowed,
                EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.firebase_uid AND f.accepted) AS following,
                COALESCE((SELECT me.ai_allowed FROM users me WHERE me.firebase_uid = $1), false) AS my_ai_allowed
         FROM users u WHERE u.handle = $2`,
        [user_id, handle]
    );
    return result.rows[0] ?? null;
}

// The films that best show someone's taste: the top of their biggest list that isn't a watchlist
async function fetchTopFilms(user_id, limit) {
    const result = await pool.query(
        `SELECT m.tmdb_id, m.title
         FROM list_movies lm JOIN movies m ON m.id = lm.movie_id
         WHERE lm.list_id = (
             SELECT l.id FROM lists l JOIN list_movies c ON c.list_id = l.id
             WHERE l.user_id = $1 AND l.name NOT ILIKE '%watch%'
             GROUP BY l.id ORDER BY COUNT(*) DESC LIMIT 1
         )
         ORDER BY lm.rank NULLS LAST
         LIMIT $2`,
        [user_id, limit]
    );
    return result.rows.map((row) => ({ tmdb_id: Number(row.tmdb_id), title: row.title }));
}

// Films someone hasn't watched yet in their watchlists (lists with "watch" in the name), by TMDb id
async function fetchUnwatchedWatchlist(user_id) {
    const result = await pool.query(
        `SELECT DISTINCT m.tmdb_id, m.title, m.release_date, m.overview, m.poster_path, m.original_language, m.popularity
         FROM lists l JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
         WHERE l.user_id = $1 AND l.name ILIKE '%watch%'
           AND NOT EXISTS (SELECT 1 FROM watched_movies w WHERE w.user_id = $1 AND w.movie_id = m.id)`,
        [user_id]
    );
    return new Map(result.rows.map((row) => [Number(row.tmdb_id), row]));
}

module.exports = { fetchListsForTaste, fetchListedTmdbIds, fetchFriend, fetchTopFilms, fetchUnwatchedWatchlist };
