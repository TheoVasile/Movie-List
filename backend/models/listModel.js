const getPool = require("../config/db");

async function createList(user_id, name, overview, is_ranked) {
    const pool = getPool();
    const result = await pool.query(
        "INSERT INTO users (user_id, name, overview, is_ranked) VALUES ($1, $2, $3, $4) RETURNING *",
        [user_id, name, overview, is_ranked]
    );
    await pool.end();
    return result.rows[0];
}


module.exports = { createList };