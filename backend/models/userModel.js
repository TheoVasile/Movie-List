const pool = require("../config/db");
const admin = require("../config/firebase");

// The only account columns sign-in and sign-up send back. Everything else on the row (the picture's bytes, phone,
// birthday, email, the internal row id) stays on the server; the app reads the rest from GET /users/me
const ACCOUNT_COLUMNS = "firebase_uid, handle, username";

/// An account row as the auth routes send it: { firebase_uid, handle, name }
function accountJSON(user) {
    return { firebase_uid: user.firebase_uid, handle: user.handle ?? null, name: user.username ?? null };
}

async function getUserByFirebaseUID(firebase_uid) {
    const result = await pool.query(
        `SELECT ${ACCOUNT_COLUMNS} FROM users WHERE firebase_uid = $1`,
        [firebase_uid]
    );
    return result.rows[0];
}

// Permanently deletes an account: its row and everything that references it, then its Firebase sign-in. Every
// table holding someone's data (lists and their films, watched films and the diary, episodes, notes, follows,
// blocks, film recommendations sent and received, list editors and list follows, groups they own or are in, poll
// votes and pick reactions, device tokens and alerts sent) references users ON DELETE CASCADE, so deleting the row
// removes it all. Films they added to other people's lists and groups stay, with who added them cleared.
// The Firebase user is deleted before committing, so if that fails nothing is deleted and they can try again.
// Returns whether the account had a row
async function deleteUser(firebase_uid) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        const result = await client.query("DELETE FROM users WHERE firebase_uid = $1", [firebase_uid]);
        try {
            await admin.auth().deleteUser(firebase_uid);
        } catch (error) {
            // Already gone, e.g. a second try after the first one's commit failed
            if (error.code !== "auth/user-not-found") throw error;
        }
        await client.query("COMMIT");
        return result.rowCount > 0;
    } catch (error) {
        await client.query("ROLLBACK").catch(() => {});
        console.error("Error deleting user:", error);
        throw error;
    } finally {
        client.release();
    }
}

async function createUser(firebase_uid, email, username) {
    // Check if user already exists
    const existingUser = await pool.query(
        `SELECT ${ACCOUNT_COLUMNS} FROM users WHERE firebase_uid = $1`,
        [firebase_uid]
    );

    if (existingUser.rows.length > 0) {
        return existingUser.rows[0]; // Return existing user
    }

    // Insert new user if not exists. username is a display name, but it has to be unique, so a name already
    // in use (two people called Sam, or the "no name" placeholder) gets part of the account id added
    const insert = (name) => pool.query(
        `INSERT INTO users (firebase_uid, email, username) VALUES ($1, $2, $3) RETURNING ${ACCOUNT_COLUMNS}`,
        [firebase_uid, email, name]
    );
    try {
        return (await insert(username)).rows[0];
    } catch (error) {
        if (error.code !== "23505" || error.constraint !== "users_username_key") throw error;
        return (await insert(`${username} ${firebase_uid.slice(0, 6)}`.slice(0, 50))).rows[0];
    }
}

module.exports = { getUserByFirebaseUID, createUser, deleteUser, accountJSON };