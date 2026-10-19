const pool = require("../config/db");

async function getUserByFirebaseUID(firebase_uid) {
    const result = await pool.query(
        "SELECT * FROM users WHERE firebase_uid = $1",
        [firebase_uid]
    );
    return result.rows[0];
}

async function deleteUser(firebase_uid) {
    const client = await pool.connect();
    try {
        const result = await pool.query(
            "DELETE FROM users WHERE firebase_uid = $1",
            [firebase_uid]
        );
        return result.rows[0];
    } catch (error) {
        console.error("Error deleting user:", error);
        throw error;
    } finally {
        client.release();
    }
}

async function createUser(firebase_uid, email, username) {
    // Check if user already exists
    const existingUser = await pool.query(
        "SELECT * FROM users WHERE firebase_uid = $1",
        [firebase_uid]
    );

    if (existingUser.rows.length > 0) {
        return existingUser.rows[0]; // Return existing user
    }

    // Insert new user if not exists. username is a display name, but it has to be unique, so a name already
    // in use (two people called Sam, or the "no name" placeholder) gets part of the account id added
    const insert = (name) => pool.query(
        "INSERT INTO users (firebase_uid, email, username) VALUES ($1, $2, $3) RETURNING *",
        [firebase_uid, email, name]
    );
    try {
        return (await insert(username)).rows[0];
    } catch (error) {
        if (error.code !== "23505" || error.constraint !== "users_username_key") throw error;
        return (await insert(`${username} ${firebase_uid.slice(0, 6)}`.slice(0, 50))).rows[0];
    }
}

module.exports = { getUserByFirebaseUID, createUser, deleteUser };