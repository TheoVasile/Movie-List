const express = require("express");
const { fetchGroups, createGroup, leaveOrDeleteGroup } = require("../models/groupModel");
const { setStreamingPreferences, streamingPreferences } = require("../services/streamingAlerts");
const { availableServices } = require("../services/filmFilters");
const { saveDeviceToken, removeDeviceToken, setNotificationPreferences, notifyUser } = require("../services/pushService");
const { isHash, setPhoneHash, matchContacts, isValidHandle, getProfile, setAvatar, fetchAvatar, setDisplayName, setAIAllowed, setHandle, searchUsers, setFollowing, fetchFollowRequests, respondToFollowRequest, fetchConnections, fetchFollowing, fetchUserLists, fetchFollowedLists, fetchFriendsOnFilm, HandleTakenError } = require("../models/socialModel");

const router = express.Router();

// Every route acts as the signed-in user (server.js puts verifyToken in front of this router)

router.get("/me", async (req, res) => {
    try {
        const profile = await getProfile(req.user.uid);
        if (!profile) return res.status(404).json({ error: "Account not found." });
        res.json(profile);
    } catch (error) {
        console.error("Error fetching profile:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Profile pictures are small JPEGs the app has already cropped and shrunk; anything bigger is refused
const MAX_AVATAR_BYTES = 300 * 1024;

// Sets the user's profile picture: the body is the JPEG itself (Content-Type: image/jpeg)
router.put("/me/avatar", express.raw({ type: "image/jpeg", limit: "1mb" }), async (req, res) => {
    const jpeg = req.body;
    // JPEG files start with FF D8 FF
    if (!Buffer.isBuffer(jpeg) || jpeg.length < 3 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8 || jpeg[2] !== 0xff) {
        return res.status(400).json({ error: "Send the picture as a JPEG." });
    }
    if (jpeg.length > MAX_AVATAR_BYTES) {
        return res.status(413).json({ error: "That picture is too large." });
    }
    try {
        await setAvatar(req.user.uid, jpeg);
        const profile = await getProfile(req.user.uid);
        res.json({ avatar_version: profile?.avatar_version ?? null });
    } catch (error) {
        console.error("Error saving profile picture:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/me/avatar", async (req, res) => {
    try {
        await setAvatar(req.user.uid, null);
        res.status(204).end();
    } catch (error) {
        console.error("Error removing profile picture:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Profile pictures. The app asks for them with ?v=<avatar_version>, so a cached copy is only reused until it changes
async function sendAvatar(res, who) {
    try {
        const jpeg = await fetchAvatar(who);
        if (!jpeg) return res.status(404).json({ error: "No profile picture." });
        res.set({ "Content-Type": "image/jpeg", "Cache-Control": "private, max-age=31536000" }).send(jpeg);
    } catch (error) {
        console.error("Error fetching profile picture:", error);
        res.status(500).json({ error: "Internal server error" });
    }
}
router.get("/me/avatar", (req, res) => sendAvatar(res, { user_id: req.user.uid }));
router.get("/:handle/avatar", (req, res) => sendAvatar(res, { handle: req.params.handle.toLowerCase() }));

// Lets friends find the user from their contacts by phone number, e.g. { "phone_hash": "<sha256 hex>" }; the app
// hashes the number first. null removes it
router.put("/me/phone", async (req, res) => {
    const hash = req.body?.phone_hash;
    if (hash !== null && !isHash(hash)) {
        return res.status(400).json({ error: "phone_hash must be a SHA-256 hex string or null." });
    }
    try {
        await setPhoneHash(req.user.uid, hash);
        res.json({ has_phone: hash !== null });
    } catch (error) {
        console.error("Error saving phone:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Which of the user's contacts are on CineList: { "emails": [sha256...], "phones": [sha256...] }. Nothing sent
// here is stored
router.post("/contacts/match", async (req, res) => {
    const clean = (list) => (Array.isArray(list) ? list : []).filter(isHash).slice(0, 5000);
    const emails = clean(req.body?.emails), phones = clean(req.body?.phones);
    if (!emails.length && !phones.length) return res.json([]);
    try {
        res.json(await matchContacts(req.user.uid, emails, phones));
    } catch (error) {
        console.error("Error matching contacts:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Movie night groups the user owns or is in
router.get("/me/groups", async (req, res) => {
    try {
        res.json(await fetchGroups(req.user.uid));
    } catch (error) {
        console.error("Error fetching groups:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Makes a group from people the user follows, e.g. { "name": "Friday crew", "handles": ["sam", "ana"] }
router.post("/me/groups", async (req, res) => {
    const name = typeof req.body.name === "string" ? req.body.name.trim().slice(0, 60) : "";
    const handles = (Array.isArray(req.body.handles) ? req.body.handles : []).map((h) => String(h).toLowerCase()).slice(0, 20);
    if (!name || !handles.length) {
        return res.status(400).json({ error: "A group needs a name and at least one person." });
    }
    try {
        const id = await createGroup(req.user.uid, name, handles);
        if (!id) return res.status(403).json({ error: "You can only add people you follow." });
        res.status(201).json({ id });
    } catch (error) {
        console.error("Error creating group:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The owner deletes a group; anyone else leaves it
router.delete("/me/groups/:id", async (req, res) => {
    try {
        if (!(await leaveOrDeleteGroup(req.user.uid, Number(req.params.id)))) {
            return res.status(404).json({ error: "Group not found." });
        }
        res.status(204).end();
    } catch (error) {
        console.error("Error leaving group:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Changes the name shown to friends, e.g. { "name": "Jess Wilk" }
router.put("/me/name", async (req, res) => {
    const name = typeof req.body.name === "string" ? req.body.name.trim().replace(/\s+/g, " ") : "";
    if (!name || name.length > 40) {
        return res.status(400).json({ error: "Names are 1 to 40 characters." });
    }
    try {
        const saved = await setDisplayName(req.user.uid, name);
        if (!saved) return res.status(404).json({ error: "Account not found." });
        res.json({ name: saved });
    } catch (error) {
        console.error("Error saving name:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Registers this device for push notifications, e.g. { "token": "<FCM token>" }
router.put("/me/devices", async (req, res) => {
    const token = typeof req.body.token === "string" ? req.body.token.trim() : "";
    if (!token || token.length > 4096) {
        return res.status(400).json({ error: "A device token is required." });
    }
    try {
        await saveDeviceToken(req.user.uid, token);
        res.json({ registered: true });
    } catch (error) {
        console.error("Error saving device token:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Stops notifications to this device, when the user signs out on it
router.delete("/me/devices/:token", async (req, res) => {
    try {
        await removeDeviceToken(req.user.uid, req.params.token);
        res.status(204).end();
    } catch (error) {
        console.error("Error removing device token:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Which notifications the user wants, e.g. { "requests": true, "activity": false }
router.put("/me/notifications", async (req, res) => {
    const { requests, activity } = req.body ?? {};
    if (typeof requests !== "boolean" && typeof activity !== "boolean") {
        return res.status(400).json({ error: "requests and/or activity must be true or false." });
    }
    try {
        await setNotificationPreferences(req.user.uid, { requests, activity });
        res.json({ requests, activity });
    } catch (error) {
        console.error("Error saving notification settings:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The user's streaming services, their country, and whether they want "now streaming" alerts
router.get("/me/streaming", async (req, res) => {
    try {
        res.json(await streamingPreferences(req.user.uid));
    } catch (error) {
        console.error("Error fetching streaming settings:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Saves them, e.g. { "region": "CA", "services": [8, 337], "notify": true }. Any can be left out. Services have
// to be ones offered in that country
router.put("/me/streaming", async (req, res) => {
    const { notify } = req.body ?? {};
    const region = req.body?.region === undefined ? undefined : String(req.body.region).toUpperCase();
    if (region !== undefined && !/^[A-Z]{2}$/.test(region)) {
        return res.status(400).json({ error: "region must be a two-letter country code." });
    }
    if (notify !== undefined && typeof notify !== "boolean") {
        return res.status(400).json({ error: "notify must be true or false." });
    }
    try {
        let services;
        if (req.body?.services !== undefined) {
            if (!Array.isArray(req.body.services)) return res.status(400).json({ error: "services must be a list of ids." });
            const current = await streamingPreferences(req.user.uid);
            const offered = new Set((await availableServices(region ?? current?.region ?? "US")).map((s) => s.id));
            services = [...new Set(req.body.services.map(Number))].filter((id) => offered.has(id)).slice(0, 20);
        }
        await setStreamingPreferences(req.user.uid, { region, services, notify });
        res.json(await streamingPreferences(req.user.uid));
    } catch (error) {
        console.error("Error saving streaming settings:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Turns AI features on or off for the user, e.g. { "allowed": true }. The app sends this whenever the
// setting changes, and Movie Night checks it for both people
router.put("/me/ai", async (req, res) => {
    if (typeof req.body.allowed !== "boolean") {
        return res.status(400).json({ error: "A true/false allowed is required." });
    }
    try {
        await setAIAllowed(req.user.uid, req.body.allowed);
        res.json({ allowed: req.body.allowed });
    } catch (error) {
        console.error("Error saving AI setting:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Picks or changes the user's @username, e.g. { "handle": "theo.v" }. 409 when someone else has it
router.put("/me/handle", async (req, res) => {
    const handle = typeof req.body.handle === "string" ? req.body.handle.trim().toLowerCase() : "";
    if (!isValidHandle(handle)) {
        return res.status(400).json({ error: "Usernames are 3 to 20 letters, numbers, underscores or dots." });
    }
    try {
        await setHandle(req.user.uid, handle);
        res.json({ handle });
    } catch (error) {
        if (error instanceof HandleTakenError) {
            return res.status(409).json({ error: "That username is taken." });
        }
        console.error("Error setting username:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// People asking to follow the user, and the @usernames the user has asked to follow
router.get("/me/requests", async (req, res) => {
    try {
        res.json(await fetchFollowRequests(req.user.uid));
    } catch (error) {
        console.error("Error fetching follow requests:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.post("/me/requests/:handle/accept", (req, res) => respond(req, res, true));
router.delete("/me/requests/:handle", (req, res) => respond(req, res, false));

async function respond(req, res, accept) {
    try {
        const requester = await respondToFollowRequest(req.user.uid, req.params.handle.toLowerCase(), accept);
        if (!requester) return res.status(404).json({ error: "Request not found." });
        if (accept) {
            const me = await getProfile(req.user.uid);
            notifyUser(requester, "follow_accepted", {
                title: "Follow request accepted",
                body: `${me?.display_name ?? "Someone"} accepted your request. You can now see their lists.`,
                data: { handle: me?.handle ?? "" },
            });
        }
        res.json({ handle: req.params.handle.toLowerCase(), accepted: accept });
    } catch (error) {
        console.error("Error answering follow request:", error);
        res.status(500).json({ error: "Internal server error" });
    }
}

router.get("/me/following", async (req, res) => {
    try {
        res.json(await fetchFollowing(req.user.uid));
    } catch (error) {
        console.error("Error fetching follows:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Followers and following: the user's own, or someone else's once the user's follow is accepted
async function sendConnections(req, res, which, handle) {
    try {
        const result = await fetchConnections(req.user.uid, { handle, which });
        if (!result) return res.status(404).json({ error: "User not found." });
        if (result.hidden) return res.status(403).json({ error: "Follow them to see who they follow and who follows them." });
        res.json(result.people);
    } catch (error) {
        console.error(`Error fetching ${which}:`, error);
        res.status(500).json({ error: "Internal server error" });
    }
}
router.get("/me/followers", (req, res) => sendConnections(req, res, "followers"));

// Other people's lists the user follows
router.get("/me/followed-lists", async (req, res) => {
    try {
        res.json(await fetchFollowedLists(req.user.uid));
    } catch (error) {
        console.error("Error fetching followed lists:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});
router.get("/:handle/followers", (req, res) => sendConnections(req, res, "followers", req.params.handle.toLowerCase()));
router.get("/:handle/following", (req, res) => sendConnections(req, res, "following", req.params.handle.toLowerCase()));

// What the people the user follows think of a film: watched, note and best list placing, e.g. /me/following/films/771
router.get("/me/following/films/:tmdb_id", async (req, res) => {
    const tmdbId = Number(req.params.tmdb_id);
    if (!Number.isInteger(tmdbId) || tmdbId <= 0) {
        return res.status(400).json({ error: "A TMDb id is required." });
    }
    try {
        res.json(await fetchFriendsOnFilm(req.user.uid, tmdbId));
    } catch (error) {
        console.error("Error fetching friends on film:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// People whose @username starts with ?q=, which must be at least 2 characters
router.get("/search", async (req, res) => {
    const query = String(req.query.q ?? "").trim().toLowerCase().replace(/^@/, "");
    if (query.length < 2 || !/^[a-z0-9_.]+$/.test(query)) {
        return res.json([]);
    }
    try {
        res.json(await searchUsers(req.user.uid, query.slice(0, 20)));
    } catch (error) {
        console.error("Error searching users:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.post("/:handle/follow", (req, res) => follow(req, res, true));
router.delete("/:handle/follow", (req, res) => follow(req, res, false));

// Following sends a request that the other person has to accept; unfollowing also cancels a request
async function follow(req, res, follow) {
    try {
        const result = await setFollowing(req.user.uid, req.params.handle.toLowerCase(), follow);
        if (!result) return res.status(404).json({ error: "User not found." });
        if (result.isNewRequest) {
            const me = await getProfile(req.user.uid);
            notifyUser(result.followee_id, "follow_request", {
                title: "New follow request",
                body: `${me?.display_name ?? "Someone"}${me?.handle ? ` (@${me.handle})` : ""} wants to follow you`,
                data: { handle: me?.handle ?? "" },
            });
        }
        res.json({ handle: req.params.handle.toLowerCase(), following: result.following, requested: result.requested });
    } catch (error) {
        console.error("Error updating follow:", error);
        res.status(500).json({ error: "Internal server error" });
    }
}

// Someone's lists, rankings and watched films. Only people the user follows; otherwise lists is empty
router.get("/:handle/lists", async (req, res) => {
    try {
        const profile = await fetchUserLists(req.user.uid, req.params.handle.toLowerCase());
        if (!profile) return res.status(404).json({ error: "User not found." });
        res.json(profile);
    } catch (error) {
        console.error("Error fetching user's lists:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;
