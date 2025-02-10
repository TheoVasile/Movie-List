const pool = require("../config/db");

async function createList(user_id, name, overview, is_ranked) {
    const result = await pool.query(
        "INSERT INTO lists (user_id, name, overview, is_ranked) VALUES ($1, $2, $3, $4) RETURNING *",
        [user_id, name, overview, is_ranked]
    );
    return result.rows[0];
}


module.exports = { createList };