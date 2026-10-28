const crypto = require("crypto");

// Invite links to movie night groups (/join/group/<token>). Anyone in a group can make one; anyone holding it can
// join the group until it expires, is revoked or is used up. The rules live in createInviteService, which works on
// a small store (sqlStore below, or an in-memory one in the tests)

// How long a new link works, and the longest a token can be
const INVITE_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;
// 24 random bytes as base64url: 32 characters, 192 bits
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{22,64}$/;

const newToken = () => crypto.randomBytes(24).toString("base64url");
const isToken = (token) => typeof token === "string" && TOKEN_PATTERN.test(token);

/// Whether an invite can still be used: "ok", "revoked", "expired" or "used_up"
function inviteState(invite, now = new Date()) {
    if (invite.revoked) return "revoked";
    if (new Date(invite.expires_at) <= now) return "expired";
    if (invite.max_uses != null && invite.uses >= invite.max_uses) return "used_up";
    return "ok";
}

/// What the app gets for a link
const inviteJSON = (invite) => ({ token: invite.token, group_id: invite.group_id, expires_at: invite.expires_at, max_uses: invite.max_uses ?? null, uses: invite.uses });

/// The invite rules over a store with: isMember(group, user), activeInvite(group, now), insertInvite(invite),
/// revokeInvite(group, token), findInvite(token), groupSummary(group) -> { id, name, owner_id, member_count },
/// handleOf(user), blockedEitherWay(a, b), useInvite(token, now) -> invite | null (counts a use only while it's
/// still valid), addMember(group, user), removeUse(token). maxMembers is the most people a group has besides its owner
function createInviteService(store, { maxMembers, now = () => new Date() } = {}) {
    return {
        /// The group's working link, made if there isn't one. null when the user isn't in the group
        async activeLink(user_id, group_id) {
            if (!(await store.isMember(group_id, user_id))) return null;
            const existing = await store.activeInvite(group_id, now());
            if (existing) return existing;
            return store.insertInvite({
                token: newToken(), group_id, created_by: user_id, created_at: now(),
                expires_at: new Date(now().getTime() + INVITE_DAYS * DAY_MS), max_uses: null, uses: 0, revoked: false,
            });
        },

        /// Turns a link off for good. false when the user isn't in the group or there's no such link in it
        async revoke(user_id, group_id, token) {
            if (!isToken(token) || !(await store.isMember(group_id, user_id))) return false;
            return store.revokeInvite(group_id, token);
        },

        /// What a link leads to: { group_name, member_count, inviter_handle }, or null when it doesn't work (no such
        /// link, expired, revoked, used up, or the group is gone)
        async preview(token) {
            if (!isToken(token)) return null;
            const invite = await store.findInvite(token);
            if (!invite || inviteState(invite, now()) !== "ok") return null;
            const group = await store.groupSummary(invite.group_id);
            if (!group) return null;
            return {
                group_id: group.id, group_name: group.name, member_count: group.member_count,
                inviter_handle: await store.handleOf(invite.created_by), expires_at: invite.expires_at,
            };
        },

        /// Joins the group a link is for. Joining a group the user is already in does nothing and succeeds.
        /// -> { status: "joined" | "already", group_id, group_name, inviter_id } or { error: "not_found" | "blocked" | "full" }
        async accept(user_id, token) {
            if (!isToken(token)) return { error: "not_found" };
            const invite = await store.findInvite(token);
            if (!invite || inviteState(invite, now()) !== "ok") return { error: "not_found" };
            const group = await store.groupSummary(invite.group_id);
            if (!group) return { error: "not_found" };
            const result = { group_id: group.id, group_name: group.name, inviter_id: invite.created_by };
            if (await store.isMember(group.id, user_id)) return { status: "already", ...result };
            // Nobody joins through someone they blocked or who blocked them, or into a group whose owner did
            for (const other of new Set([invite.created_by, group.owner_id])) {
                if (await store.blockedEitherWay(user_id, other)) return { error: "blocked" };
            }
            // member_count includes the owner
            if (maxMembers != null && group.member_count - 1 >= maxMembers) return { error: "full" };
            // Counted first, so a link with a use limit can't be used past it by people joining at once
            if (!(await store.useInvite(token, now()))) return { error: "not_found" };
            const added = await store.addMember(group.id, user_id);
            // Joined some other way in the meantime: the use isn't counted
            if (!added) {
                await store.removeUse(token);
                return { status: "already", ...result };
            }
            return { status: "joined", ...result };
        },
    };
}

/// The store backed by Postgres
function sqlStore(pool) {
    return {
        async isMember(group_id, user_id) {
            const result = await pool.query(
                `SELECT 1 FROM watch_groups g WHERE g.id = $1 AND (g.owner_id = $2
                 OR EXISTS (SELECT 1 FROM watch_group_members m WHERE m.group_id = g.id AND m.user_id = $2))`,
                [group_id, user_id]
            );
            return result.rowCount > 0;
        },
        // Times are the database's own (NOW() and the table's defaults), like every other timestamp, rather than
        // this server's clock, so they can't be shifted by its timezone
        async activeInvite(group_id) {
            const result = await pool.query(
                `SELECT * FROM group_invites WHERE group_id = $1 AND NOT revoked AND expires_at > NOW()
                 AND (max_uses IS NULL OR uses < max_uses) ORDER BY created_at DESC LIMIT 1`,
                [group_id]
            );
            return result.rows[0] ?? null;
        },
        async insertInvite(invite) {
            const result = await pool.query(
                `INSERT INTO group_invites (token, group_id, created_by, expires_at, max_uses)
                 VALUES ($1, $2, $3, NOW() + make_interval(days => $4), $5) RETURNING *`,
                [invite.token, invite.group_id, invite.created_by, INVITE_DAYS, invite.max_uses]
            );
            return result.rows[0];
        },
        async revokeInvite(group_id, token) {
            const result = await pool.query("UPDATE group_invites SET revoked = true WHERE group_id = $1 AND token = $2", [group_id, token]);
            return result.rowCount > 0;
        },
        async findInvite(token) {
            const result = await pool.query("SELECT * FROM group_invites WHERE token = $1", [token]);
            return result.rows[0] ?? null;
        },
        async groupSummary(group_id) {
            const result = await pool.query(
                `SELECT g.id, g.name, g.owner_id, 1 + (SELECT COUNT(*) FROM watch_group_members m WHERE m.group_id = g.id)::int AS member_count
                 FROM watch_groups g WHERE g.id = $1`,
                [group_id]
            );
            return result.rows[0] ?? null;
        },
        async handleOf(user_id) {
            const result = await pool.query("SELECT handle FROM users WHERE firebase_uid = $1", [user_id]);
            return result.rows[0]?.handle ?? null;
        },
        async blockedEitherWay(a, b) {
            const result = await pool.query(
                "SELECT 1 FROM blocks WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)",
                [a, b]
            );
            return result.rowCount > 0;
        },
        async useInvite(token) {
            const result = await pool.query(
                `UPDATE group_invites SET uses = uses + 1 WHERE token = $1 AND NOT revoked AND expires_at > NOW()
                 AND (max_uses IS NULL OR uses < max_uses) RETURNING *`,
                [token]
            );
            return result.rows[0] ?? null;
        },
        async addMember(group_id, user_id) {
            const result = await pool.query(
                "INSERT INTO watch_group_members (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                [group_id, user_id]
            );
            return result.rowCount > 0;
        },
        async removeUse(token) {
            await pool.query("UPDATE group_invites SET uses = GREATEST(uses - 1, 0) WHERE token = $1", [token]);
        },
    };
}

module.exports = { INVITE_DAYS, TOKEN_PATTERN, newToken, isToken, inviteState, inviteJSON, createInviteService, sqlStore };
