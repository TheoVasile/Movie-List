const pool = require("../config/db");
const { fetchNotes } = require("./notesModel");

async function createList(user_id, name, overview, is_ranked) {
    const result = await pool.query(
        "INSERT INTO lists (user_id, name, overview, is_ranked) VALUES ($1, $2, $3, $4) RETURNING *",
        [user_id, name, overview, is_ranked]
    );
    return result.rows[0];
}

// Every list the user owns, each with its films (plus rank, watched and note). Two queries in total,
// rather than one per film, which took over a minute for lists with hundreds of films
async function fetchLists(user_id) {
    // One after another, so a single database connection is enough
    const lists = await pool.query("SELECT * FROM lists WHERE user_id = $1 ORDER BY id", [user_id]);
    const films = await pool.query(
        `SELECT lm.list_id, lm.rank, m.*, (w.movie_id IS NOT NULL) AS watched
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         LEFT JOIN watched_movies w ON w.user_id = l.user_id AND w.movie_id = m.id
         WHERE l.user_id = $1
         ORDER BY lm.list_id, lm.rank`,
        [user_id]
    );
    const notes = await fetchNotes(user_id);

    const byList = new Map(lists.rows.map((list) => [list.id, { ...list, movies: [] }]));
    for (const { list_id, ...film } of films.rows) {
        film.note = notes.get(film.id) ?? null;
        byList.get(list_id)?.movies.push(film);
    }
    return [...byList.values()];
}

async function deleteList(list_id) {
    try {
        await pool.query("BEGIN");
        await pool.query("DELETE FROM list_movies WHERE list_id = $1", [list_id]);
        const result = await pool.query(
            "DELETE FROM lists WHERE id = $1",
            [list_id]
        );
        await pool.query("COMMIT");
        return result.rows[0];
    } catch (error) {
        await pool.query("ROLLBACK");
        throw error;
    }
}

// Renames a list and/or changes its description. Fields left undefined keep their current value
async function updateList(list_id, { name, overview }) {
    const result = await pool.query(
        `UPDATE lists
         SET name = COALESCE($2, name), overview = COALESCE($3, overview), date_modified = CURRENT_TIMESTAMP
         WHERE id = $1
         RETURNING *`,
        [list_id, name ?? null, overview ?? null]
    );
    return result.rows[0];
}

async function isListOwner(list_id, user_id) {
    const result = await pool.query(
        "SELECT 1 FROM lists WHERE id = $1 AND user_id = $2",
        [list_id, user_id]
    );
    return result.rowCount > 0;
}

module.exports = { createList, deleteList, fetchLists, isListOwner, updateList };