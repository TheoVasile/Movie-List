const express = require("express");
const { inviteJSON } = require("../models/inviteModel");
const { links } = require("../config/publicLinks");

// Invite links to movie night groups, as the signed-in user (server.js puts verifyToken in front):
//   POST   /groups/:id/invites          the group's working link, made if needed (anyone in the group)
//   DELETE /groups/:id/invites/:token   turns a link off (anyone in the group)
//   GET    /invites/:token              what the link leads to
//   POST   /invites/:token/accept       joins the group (doing it again does nothing)

/// { groups, invites }: the two routers, working through the invite service (models/inviteModel.js) and telling
/// the person who made the link when someone joins with it
function createInviteRouters({ invites, notifyJoined = async () => {} }) {
    const groups = express.Router();
    const invitesRouter = express.Router();

    groups.post("/:id/invites", async (req, res) => {
        const groupId = Number(req.params.id);
        if (!Number.isInteger(groupId)) return res.status(400).json({ error: "That isn't a group." });
        try {
            const invite = await invites.activeLink(req.user.uid, groupId);
            if (!invite) return res.status(403).json({ error: "Only people in the group can invite others." });
            res.status(201).json({ ...inviteJSON(invite), url: links.groupInvite(invite.token) });
        } catch (error) {
            console.error("Error making group invite:", error);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    groups.delete("/:id/invites/:token", async (req, res) => {
        const groupId = Number(req.params.id);
        if (!Number.isInteger(groupId)) return res.status(400).json({ error: "That isn't a group." });
        try {
            if (!(await invites.revoke(req.user.uid, groupId, req.params.token))) {
                return res.status(404).json({ error: "That invite link wasn't found." });
            }
            res.json({ revoked: true });
        } catch (error) {
            console.error("Error revoking group invite:", error);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    invitesRouter.get("/:token", async (req, res) => {
        try {
            const preview = await invites.preview(req.params.token);
            if (!preview) return res.status(404).json({ error: "This invite link has expired or been turned off." });
            res.json(preview);
        } catch (error) {
            console.error("Error reading group invite:", error);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    invitesRouter.post("/:token/accept", async (req, res) => {
        try {
            const result = await invites.accept(req.user.uid, req.params.token);
            if (result.error === "not_found") return res.status(404).json({ error: "This invite link has expired or been turned off." });
            if (result.error === "blocked") return res.status(403).json({ error: "You can't join this group." });
            if (result.error === "full") return res.status(409).json({ error: "This group is full." });
            if (result.status === "joined") notifyJoined(req.user.uid, result).catch(() => {});
            res.json({ joined: result.status === "joined", already_member: result.status === "already", group_id: result.group_id, group_name: result.group_name });
        } catch (error) {
            console.error("Error accepting group invite:", error);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    return { groups, invites: invitesRouter };
}

/// Tells whoever made the link "@x joined <group>", over the existing push notifications
async function notifyJoinedByPush(user_id, { inviter_id, group_id, group_name }) {
    const pool = require("../config/db");
    const { notifyUser } = require("../services/pushService");
    if (!inviter_id || inviter_id === user_id) return;
    const me = await pool.query("SELECT handle, username FROM users WHERE firebase_uid = $1", [user_id]);
    const who = me.rows[0]?.handle ? `@${me.rows[0].handle}` : me.rows[0]?.username ?? "Someone";
    await notifyUser(inviter_id, "group_joined", {
        title: group_name ?? "Movie night",
        body: `${who} joined ${group_name ?? "your group"}`,
        data: { group_id: String(group_id) },
    });
}

module.exports = { createInviteRouters, notifyJoinedByPush };
