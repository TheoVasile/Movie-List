const pool = require("../config/db");

// Every film in the user's lists, grouped by list (largest list first) and in rank order, with
// whether the user has marked it watched. Used to describe the user's taste to the AI
async function fetchListsForTaste(user_id) {
    const result = await pool.query(
        `SELECT l.id AS list_id, l.name AS list_name, m.title, m.release_date, lm.rank,
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

module.exports = { fetchListsForTaste, fetchListedTmdbIds };
