const getPool = require("../config/db");

async function getUserByFirebaseUID(firebase_uid) {
    const pool = getPool();
    const result = await pool.query(
        "SELECT * FROM users WHERE firebase_uid = $1",
        [firebase_uid]
    );
    await pool.end();
    return result.rows[0];
}

async function createUser(firebase_uid, email, username) {
    const pool = getPool();
    const result = await pool.query(
        "INSERT INTO users (firebase_uid, email, username) VALUES ($1, $2, $3) RETURNING *",
        [firebase_uid, email, username]
    );
    await pool.end();
    return result.rows[0];
}

module.exports = { getUserByFirebaseUID, createUser };