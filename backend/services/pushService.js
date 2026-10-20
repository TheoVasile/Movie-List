const admin = require("../config/firebase");
const pool = require("../config/db");

// Which preference column each kind of notification checks
const PREFERENCE = {
    follow_request: "notify_requests",
    follow_accepted: "notify_requests",
    activity: "notify_activity",
    streaming: "notify_streaming",
};

/// Saves the token for a device the user is signed in on. A token moves to whoever signed in on it last
async function saveDeviceToken(user_id, token) {
    await pool.query(
        `INSERT INTO device_tokens (token, user_id) VALUES ($1, $2)
         ON CONFLICT (token) DO UPDATE SET user_id = $2, updated_at = CURRENT_TIMESTAMP`,
        [token, user_id]
    );
}

async function removeDeviceToken(user_id, token) {
    await pool.query("DELETE FROM device_tokens WHERE token = $1 AND user_id = $2", [token, user_id]);
}

async function setNotificationPreferences(user_id, { requests, activity }) {
    await pool.query(
        `UPDATE users SET notify_requests = COALESCE($2, notify_requests), notify_activity = COALESCE($3, notify_activity)
         WHERE firebase_uid = $1`,
        [user_id, typeof requests === "boolean" ? requests : null, typeof activity === "boolean" ? activity : null]
    );
}

/// Sends a push notification to every device the user is signed in on, if they want this kind.
/// data values must be strings. Tokens Firebase says are no longer valid are removed. Never throws: a
/// notification that can't be sent shouldn't fail the request that caused it. Returns how many were sent
async function notifyUser(user_id, kind, { title, body, data = {} }) {
    try {
        const column = PREFERENCE[kind];
        const result = await pool.query(
            `SELECT t.token FROM device_tokens t JOIN users u ON u.firebase_uid = t.user_id
             WHERE t.user_id = $1 ${column ? `AND u.${column}` : ""}`,
            [user_id]
        );
        const tokens = result.rows.map((row) => row.token);
        if (!tokens.length) return 0;

        const response = await admin.messaging().sendEachForMulticast({
            tokens,
            notification: { title, body },
            data: { type: kind, ...data },
            apns: { payload: { aps: { sound: "default" } } },
        });
        const stale = response.responses
            .map((r, i) => (!r.success && ["messaging/registration-token-not-registered", "messaging/invalid-registration-token", "messaging/invalid-argument"].includes(r.error?.code) ? tokens[i] : null))
            .filter(Boolean);
        if (stale.length) {
            await pool.query("DELETE FROM device_tokens WHERE token = ANY($1)", [stale]);
        }
        return response.successCount;
    } catch (error) {
        console.error(`Couldn't send ${kind} notification:`, error.message);
        return 0;
    }
}

module.exports = { saveDeviceToken, removeDeviceToken, setNotificationPreferences, notifyUser };
