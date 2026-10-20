const pool = require("../config/db");

// Movie night groups: a name and some people, made by one user from people they follow. Everyone in a group
// can see it and plan a movie night for it

// The most people a group can have besides its owner, to keep a movie night's AI request affordable
const MAX_MEMBERS = 7;

const memberColumns = `u.handle, u.username AS display_name,
    FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version, u.ai_allowed`;

/// The account ids of people the user follows (accepted), by @handle. Unknown or unfollowed handles are left out
async function followedByHandle(user_id, handles) {
    const result = await pool.query(
        `SELECT u.firebase_uid, u.handle FROM users u
         JOIN follows f ON f.followee_id = u.firebase_uid AND f.follower_id = $1 AND f.accepted
         WHERE u.handle = ANY($2::text[])`,
        [user_id, handles]
    );
    return result.rows;
}

/// Every group the user owns or is in, with everyone in it (owner first), and whether all of them allow AI
async function fetchGroups(user_id) {
    const groups = await pool.query(
        `SELECT g.id, g.name, g.owner_id = $1 AS is_owner
         FROM watch_groups g
         WHERE g.owner_id = $1 OR EXISTS (SELECT 1 FROM watch_group_members m WHERE m.group_id = g.id AND m.user_id = $1)
         ORDER BY g.created_at DESC`,
        [user_id]
    );
    if (!groups.rows.length) return [];
    const people = await pool.query(
        `SELECT g.id AS group_id, u.firebase_uid = $1 AS is_me, u.firebase_uid = g.owner_id AS is_owner, ${memberColumns}
         FROM watch_groups g
         JOIN users u ON u.firebase_uid = g.owner_id OR u.firebase_uid IN (SELECT user_id FROM watch_group_members WHERE group_id = g.id)
         WHERE g.id = ANY($2::int[])
         ORDER BY (u.firebase_uid = g.owner_id) DESC, u.username`,
        [user_id, groups.rows.map((g) => g.id)]
    );
    return groups.rows.map((group) => {
        const members = people.rows.filter((p) => p.group_id === group.id);
        return {
            id: group.id,
            name: group.name,
            is_owner: group.is_owner,
            // Everyone else in the group, as the user sees them
            members: members.filter((p) => !p.is_me).map(({ handle, display_name, avatar_version, is_owner }) => ({ handle, display_name, avatar_version, is_owner, following: false })),
            ai_possible: members.every((p) => p.ai_allowed),
        };
    });
}

/// Creates a group from people the user follows. Returns null if none of the handles are people they follow
async function createGroup(user_id, name, handles) {
    const members = (await followedByHandle(user_id, handles)).slice(0, MAX_MEMBERS);
    if (!members.length) return null;
    const group = await pool.query("INSERT INTO watch_groups (owner_id, name) VALUES ($1, $2) RETURNING id", [user_id, name]);
    const id = group.rows[0].id;
    await pool.query(
        "INSERT INTO watch_group_members (group_id, user_id) SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING",
        [id, members.map((m) => m.firebase_uid)]
    );
    return id;
}

/// The owner deletes the group; anyone else leaves it. Returns false when the user isn't in it
async function leaveOrDeleteGroup(user_id, group_id) {
    const deleted = await pool.query("DELETE FROM watch_groups WHERE id = $1 AND owner_id = $2", [group_id, user_id]);
    if (deleted.rowCount) return true;
    const left = await pool.query("DELETE FROM watch_group_members WHERE group_id = $1 AND user_id = $2", [group_id, user_id]);
    return left.rowCount > 0;
}

/// Everyone in a group except the user, as { firebase_uid, handle, name, ai_allowed }, with the user's own
/// ai_allowed. null when the user isn't in the group
async function groupParticipants(user_id, group_id) {
    const result = await pool.query(
        `SELECT u.firebase_uid, u.handle, u.username AS name, u.ai_allowed
         FROM watch_groups g
         JOIN users u ON u.firebase_uid = g.owner_id OR u.firebase_uid IN (SELECT user_id FROM watch_group_members WHERE group_id = g.id)
         WHERE g.id = $1`,
        [group_id]
    );
    if (!result.rows.some((row) => row.firebase_uid === user_id)) return null;
    return result.rows;
}

module.exports = { MAX_MEMBERS, followedByHandle, fetchGroups, createGroup, leaveOrDeleteGroup, groupParticipants };
