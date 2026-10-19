const express = require("express");
const { isValidHandle, getProfile, setDisplayName, setAIAllowed, setHandle, searchUsers, setFollowing, fetchFollowRequests, respondToFollowRequest, fetchFollowing, fetchUserLists, fetchFriendsOnFilm, HandleTakenError } = require("../models/socialModel");

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
