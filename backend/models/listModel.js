const pool = require("../config/db");
const { fetchNotes } = require("./notesModel");

async function createList(user_id, name, overview, is_ranked) {
    const result = await pool.query(
        "INSERT INTO lists (user_id, name, overview, is_ranked) VALUES ($1, $2, $3, $4) RETURNING *",
        [user_id, name, overview, is_ranked]
    );
    return result.rows[0];
}

// SQL condition: the list aliased l is one the user whose id is the given parameter owns or edits
const editableBy = (param) => `(l.user_id = ${param} OR EXISTS (
    SELECT 1 FROM list_editors le WHERE le.list_id = l.id AND le.user_id = ${param}))`;

// Every list the user owns or edits, each with its films (plus rank, watched, note and who added it). Shared
// lists also say whether the user owns them, and who owns and edits them. A handful of queries in total, rather
// than one per film, which took over a minute for lists with hundreds of films
async function fetchLists(user_id) {
    // One after another, so a single database connection is enough
    const lists = await pool.query(
        `SELECT l.*, l.user_id = $1 AS is_owner FROM lists l WHERE ${editableBy("$1")} ORDER BY l.id`,
        [user_id]
    );
    const films = await pool.query(
        `SELECT lm.list_id, lm.rank, lm.ai_placed, m.*, (w.movie_id IS NOT NULL) AS watched,
                CASE WHEN lm.added_by IS NOT NULL AND lm.added_by <> $1 THEN COALESCE(adder.username, adder.handle) END AS added_by_name
         FROM lists l
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         LEFT JOIN watched_movies w ON w.user_id = $1 AND w.movie_id = m.id
         LEFT JOIN users adder ON adder.firebase_uid = lm.added_by
         WHERE ${editableBy("$1")}
         ORDER BY lm.list_id, lm.rank`,
        [user_id]
    );
    // Everyone on each shared list, owner first
    const people = await pool.query(
        `SELECT p.list_id, p.is_owner, u.firebase_uid = $1 AS is_me, u.handle, COALESCE(u.username, u.handle) AS display_name,
                FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version
         FROM (SELECT l.id AS list_id, l.user_id, true AS is_owner, 0 AS sort, l.creation_date AS since FROM lists l
               WHERE ${editableBy("$1")} AND EXISTS (SELECT 1 FROM list_editors x WHERE x.list_id = l.id)
               UNION ALL
               SELECT le.list_id, le.user_id, false, 1, le.added_at FROM list_editors le
               JOIN lists l ON l.id = le.list_id WHERE ${editableBy("$1")}) p
         JOIN users u ON u.firebase_uid = p.user_id
         ORDER BY p.list_id, p.sort, p.since`,
        [user_id]
    );
    const notes = await fetchNotes(user_id);

    const byList = new Map(lists.rows.map((list) => [list.id, { ...list, movies: [], members: [] }]));
    for (const { list_id, ...film } of films.rows) {
        film.note = notes.get(film.id) ?? null;
        byList.get(list_id)?.movies.push(film);
    }
    for (const { list_id, ...person } of people.rows) {
        byList.get(list_id)?.members.push(person);
    }
    return [...byList.values()];
}

// Whether the user owns the list or was invited to edit it
async function canEditList(list_id, user_id) {
    const result = await pool.query(`SELECT 1 FROM lists l WHERE l.id = $1 AND ${editableBy("$2")}`, [list_id, user_id]);
    return result.rowCount > 0;
}

const MAX_EDITORS = 10;

// Invites someone the owner follows to edit their list. Returns the editor's id and the list's name, or a
// reason it can't: "not_found" (not the owner's list), "not_following", "full" or "already"
async function addListEditor(owner_id, list_id, handle) {
    const list = await pool.query("SELECT name FROM lists WHERE id = $1 AND user_id = $2", [list_id, owner_id]);
    if (!list.rows.length) return { error: "not_found" };
    const person = await pool.query(
        `SELECT u.firebase_uid FROM users u
         JOIN follows f ON f.followee_id = u.firebase_uid AND f.follower_id = $1 AND f.accepted
         WHERE u.handle = $2`,
        [owner_id, handle]
    );
    if (!person.rows.length) return { error: "not_following" };
    const count = await pool.query("SELECT COUNT(*)::int AS n FROM list_editors WHERE list_id = $1", [list_id]);
    if (count.rows[0].n >= MAX_EDITORS) return { error: "full" };
    const added = await pool.query(
        "INSERT INTO list_editors (list_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [list_id, person.rows[0].firebase_uid]
    );
    if (!added.rowCount) return { error: "already" };
    return { editor_id: person.rows[0].firebase_uid, list_name: list.rows[0].name };
}

// Takes an editor off a list: the owner can remove anyone, and an editor can remove themselves (leave).
// handle is null to mean the user themselves. Returns false when there was nothing they could remove
async function removeListEditor(user_id, list_id, handle) {
    const result = await pool.query(
        `DELETE FROM list_editors le USING users u, lists l
         WHERE le.list_id = $1 AND le.user_id = u.firebase_uid AND l.id = le.list_id
           AND (($3::text IS NULL AND le.user_id = $2) OR ($3::text IS NOT NULL AND u.handle = $3 AND (l.user_id = $2 OR le.user_id = $2)))`,
        [list_id, user_id, handle]
    );
    return result.rowCount > 0;
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
const VISIBILITIES = ["public", "followers", "private"];

async function updateList(list_id, { name, overview, visibility }) {
    const result = await pool.query(
        `UPDATE lists
         SET name = COALESCE($2, name), overview = COALESCE($3, overview), visibility = COALESCE($4, visibility),
             date_modified = CURRENT_TIMESTAMP
         WHERE id = $1
         RETURNING *`,
        [list_id, name ?? null, overview ?? null, visibility ?? null]
    );
    return result.rows[0];
}

// SQL condition: the list aliased l can be seen by the user whose id is the given parameter. Owners see all
// their lists; others see public ones, and followers-only ones once their follow is accepted. A private
// profile's lists are only ever for followers, even one still marked public
const visibleTo = (param) => `(l.user_id = ${param}
    OR (l.visibility = 'public' AND NOT EXISTS (SELECT 1 FROM users vo WHERE vo.firebase_uid = l.user_id AND vo.is_private))
    OR (l.visibility IN ('followers', 'public') AND EXISTS (
        SELECT 1 FROM follows vf WHERE vf.follower_id = ${param} AND vf.followee_id = l.user_id AND vf.accepted)))`;

// Follows or unfollows someone else's list the user can see. Returns false when there's no such list,
// it's the user's own, or they can't see it
async function setListFollowed(user_id, list_id, follow) {
    const list = await pool.query(`SELECT l.user_id FROM lists l WHERE l.id = $1 AND ${visibleTo("$2")}`, [list_id, user_id]);
    if (!list.rows.length || list.rows[0].user_id === user_id) return false;
    if (follow) {
        await pool.query("INSERT INTO list_follows (user_id, list_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", [user_id, list_id]);
    } else {
        await pool.query("DELETE FROM list_follows WHERE user_id = $1 AND list_id = $2", [user_id, list_id]);
    }
    return true;
}

async function isListOwner(list_id, user_id) {
    const result = await pool.query(
        "SELECT 1 FROM lists WHERE id = $1 AND user_id = $2",
        [list_id, user_id]
    );
    return result.rowCount > 0;
}

module.exports = {
    createList, deleteList, fetchLists, isListOwner, canEditList, addListEditor, removeListEditor, updateList,
    setListFollowed, visibleTo, VISIBILITIES, MAX_EDITORS,
};