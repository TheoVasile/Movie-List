const pool = require("../config/db");

async function getUserByFirebaseUID(firebase_uid) {
    const result = await pool.query(
        "SELECT * FROM users WHERE firebase_uid = $1",
        [firebase_uid]
    );
    return result.rows[0];
}

async function createUser(firebase_uid, email, username) {
    const result = await pool.query(
        "INSERT INTO users (firebase_uid, email, username) VALUES ($1, $2, $3) RETURNING *",
        [firebase_uid, email, username]
    );
    return result.rows[0];
}

module.exports = { getUserByFirebaseUID, createUser };