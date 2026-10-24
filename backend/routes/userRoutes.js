const express = require("express");
const { fetchGroups, createGroup, leaveOrDeleteGroup, addGroupMembers, removeGroupMember, groupParticipants } = require("../models/groupModel");
const { fetchPicks, suggestPick, reactToPick, removePick, likedPicks } = require("../models/groupPicksModel");
const { yearReview } = require("../models/yearReviewModel");
const { fetchFriendActivity } = require("../services/digestService");
const { watchedEpisodes, setEpisodesWatched } = require("../services/tvEpisodes");
const { MAX_RECIPIENTS, sendRecommendation, fetchReceived, markSeen, removeReceived } = require("../models/recommendationsModel");
const { setStreamingPreferences, streamingPreferences } = require("../services/streamingAlerts");
const { availableServices } = require("../services/filmFilters");
const { MIN_FILMS, MAX_FILMS, startPoll, currentPoll, vote, scheduleOpenPolls } = require("../models/pollModel");
const { saveDeviceToken, removeDeviceToken, setNotificationPreferences, notifyUser } = require("../services/pushService");
const admin = require("../config/firebase");
const pool = require("../config/db");
const { TERMS_VERSION } = require("../config/terms");
const { REPORT_REASONS, REPORT_CONTENT_TYPES, MAX_DETAILS, createReport, notifyOperator, fetchOpenReports } = require("../models/reportsModel");
const { setPrivate, isHash, setPhone, matchContacts, isValidHandle, getProfile, setAvatar, fetchAvatar, setDisplayName, setAIAllowed, setHandle, searchUsers, setFollowing, fetchFollowRequests, respondToFollowRequest, fetchConnections, fetchFollowing, fetchUserLists, fetchFollowedLists, fetchFriendsOnFilm, blockUser, unblockUser, fetchBlocked, HandleTakenError } = require("../models/socialModel");

const router = express.Router();

// Every route acts as the signed-in user (server.js puts verifyToken in front of this router)

router.get("/me", async (req, res) => {
    try {
        const profile = await getProfile(req.user.uid);
        if (!profile) return res.status(404).json({ error: "Account not found." });
        // terms_version is what the user last accepted; the app asks them to accept again when it isn't current
        res.json({ ...profile, current_terms_version: TERMS_VERSION });
    } catch (error) {
        console.error("Error fetching profile:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Records that the user accepted the Terms of Service, e.g. { "version": "2026-10-24" }. Only the current
// version can be accepted -> { "terms_version": "2026-10-24" }
router.post("/terms/accept", async (req, res) => {
    if (req.body?.version !== TERMS_VERSION) {
        return res.status(400).json({ error: "Those aren't the current Terms of Service." });
    }
    try {
        const result = await pool.query(
            "UPDATE users SET terms_version = $2, terms_accepted_at = NOW() WHERE firebase_uid = $1 RETURNING terms_version",
            [req.user.uid, TERMS_VERSION]
        );
        if (result.rowCount === 0) return res.status(404).json({ error: "Account not found." });
        res.json({ terms_version: result.rows[0].terms_version });
    } catch (error) {
        console.error("Error accepting terms:", error);
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

// Saves the phone number the user just verified, so friends can find them from their contacts. The app verifies it
// with Firebase (a code sent by text) and adds it to the user's Firebase account; the number is read from there,
// never from the request, so only verified numbers are saved -> { has_phone, phone }
router.post("/me/phone/verified", async (req, res) => {
    try {
        const { phoneNumber } = await admin.auth().getUser(req.user.uid);
        if (!phoneNumber) {
            return res.status(400).json({ error: "Verify your phone number first." });
        }
        await setPhone(req.user.uid, phoneNumber);
        res.json({ has_phone: true, phone: phoneNumber });
    } catch (error) {
        if (error.code === "23505") {
            return res.status(409).json({ error: "That number is already on another account." });
        }
        console.error("Error saving phone:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Removes the user's phone number, here and from their Firebase account
router.delete("/me/phone", async (req, res) => {
    try {
        await admin.auth().updateUser(req.user.uid, { phoneNumber: null });
        await setPhone(req.user.uid, null);
        res.json({ has_phone: false, phone: null });
    } catch (error) {
        console.error("Error removing phone:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// App versions from before verification sent an unverified, hashed number here. Those aren't accepted any more;
// removing still works
router.put("/me/phone", async (req, res) => {
    if (req.body?.phone_hash !== null) {
        return res.status(410).json({ error: "Update CineList to add your phone number." });
    }
    try {
        await setPhone(req.user.uid, null);
        res.json({ has_phone: false });
    } catch (error) {
        console.error("Error removing phone:", error);
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

// The user's Year in Review, e.g. ?year=2026 (this year when left out): films watched, months, favourites and
// their closest friend in taste
router.get("/me/year-review", async (req, res) => {
    const year = req.query.year === undefined ? new Date().getUTCFullYear() : Number(req.query.year);
    if (!Number.isInteger(year) || year < 1900 || year > 3000) {
        return res.status(400).json({ error: "year must be a year, e.g. 2026." });
    }
    try {
        res.json(await yearReview(req.user.uid, year));
    } catch (error) {
        console.error("Error building year review:", error);
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

// The group's owner adds people they follow, e.g. { "handles": ["lee"] }. Each one gets a push
router.post("/me/groups/:id/members", async (req, res) => {
    const groupId = Number(req.params.id);
    const handles = (Array.isArray(req.body.handles) ? req.body.handles : []).map((h) => String(h).toLowerCase()).slice(0, 20);
    if (!Number.isInteger(groupId) || !handles.length) {
        return res.status(400).json({ error: "Pick at least one person to add." });
    }
    try {
        const added = await addGroupMembers(req.user.uid, groupId, handles);
        if (!added) return res.status(403).json({ error: "Only the person who made the group can add people." });
        if (added.length) {
            const me = await getProfile(req.user.uid);
            const group = (await fetchGroups(req.user.uid)).find((g) => g.id === groupId);
            for (const uid of added) {
                notifyUser(uid, "group_added", {
                    title: "You're in a movie night group",
                    body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} added you to ${group?.name ?? "their group"}`,
                    data: { group_id: String(groupId) },
                });
            }
        }
        res.json((await fetchGroups(req.user.uid)).find((g) => g.id === groupId));
    } catch (error) {
        console.error("Error adding to group:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The group's owner removes someone
router.delete("/me/groups/:id/members/:handle", async (req, res) => {
    try {
        if (!(await removeGroupMember(req.user.uid, Number(req.params.id), req.params.handle.toLowerCase()))) {
            return res.status(404).json({ error: "They aren't in a group of yours." });
        }
        res.json((await fetchGroups(req.user.uid)).find((g) => g.id === Number(req.params.id)));
    } catch (error) {
        console.error("Error removing from group:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The group's shortlist: recommendations and suggestions, most liked first, with everyone's likes and dislikes.
// New recommendations come from POST /movies/movie-night with "save": true
router.get("/me/groups/:id/picks", async (req, res) => {
    try {
        const picks = await fetchPicks(req.user.uid, Number(req.params.id));
        if (!picks) return res.status(404).json({ error: "Group not found." });
        res.json(picks);
    } catch (error) {
        console.error("Error fetching group picks:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Suggests a film to the group, e.g. { "tmdb_id": 949, "title": "Heat", "poster_path": "/x.jpg",
// "release_date": "1995-12-15", "overview": "...", "original_language": "en", "popularity": 30.1 }. It counts
// as the user's like, and everyone else hears about it. Returns the shortlist
router.post("/me/groups/:id/picks", async (req, res) => {
    const groupId = Number(req.params.id);
    const body = req.body ?? {};
    const text = (value, max) => (typeof value === "string" ? value.trim().slice(0, max) : "");
    const film = {
        tmdb_id: Number(body.tmdb_id),
        title: text(body.title, 255),
        poster_path: text(body.poster_path, 255) || null,
        release_date: text(body.release_date, 20),
        overview: text(body.overview, 2000),
        original_language: text(body.original_language, 10),
        popularity: Number(body.popularity) || 0,
    };
    if (!Number.isInteger(groupId) || !Number.isInteger(film.tmdb_id) || film.tmdb_id <= 0 || !film.title) {
        return res.status(400).json({ error: "A tmdb_id and title are required." });
    }
    try {
        if (!(await suggestPick(req.user.uid, groupId, film))) return res.status(404).json({ error: "Group not found." });
        const me = await getProfile(req.user.uid);
        const group = (await fetchGroups(req.user.uid)).find((g) => g.id === groupId);
        for (const person of await groupParticipants(req.user.uid, groupId)) {
            if (person.firebase_uid === req.user.uid) continue;
            notifyUser(person.firebase_uid, "group_suggestion", {
                title: group?.name ?? "Movie night",
                body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} suggested ${film.title}. Like it or pass?`,
                data: { group_id: String(groupId) },
            });
        }
        res.status(201).json(await fetchPicks(req.user.uid, groupId));
    } catch (error) {
        console.error("Error suggesting film:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Likes (1) or dislikes (-1) a film on the shortlist, or takes it back (0), e.g. { "reaction": 1 }. A film
// everyone dislikes leaves the shortlist for good. Returns the shortlist
router.put("/me/groups/:id/picks/:tmdbId/reaction", async (req, res) => {
    const groupId = Number(req.params.id), tmdbId = Number(req.params.tmdbId), reaction = Number(req.body?.reaction);
    if (!Number.isInteger(groupId) || !Number.isInteger(tmdbId) || ![1, 0, -1].includes(reaction)) {
        return res.status(400).json({ error: "A reaction of 1, 0 or -1 is required." });
    }
    try {
        const result = await reactToPick(req.user.uid, groupId, tmdbId, reaction);
        if (result === null) return res.status(404).json({ error: "Group not found." });
        if (!result) return res.status(404).json({ error: "That film isn't on the shortlist anymore." });
        res.json(await fetchPicks(req.user.uid, groupId));
    } catch (error) {
        console.error("Error reacting to pick:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Takes a suggestion off the shortlist: whoever suggested it, or the group's owner. Returns the shortlist
router.delete("/me/groups/:id/picks/:tmdbId", async (req, res) => {
    const groupId = Number(req.params.id), tmdbId = Number(req.params.tmdbId);
    try {
        if (!(await removePick(req.user.uid, groupId, tmdbId))) {
            return res.status(404).json({ error: "Only whoever suggested it or the group's owner can remove it." });
        }
        res.json(await fetchPicks(req.user.uid, groupId));
    } catch (error) {
        console.error("Error removing pick:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Starts a vote between the films the group has liked (the most liked, up to MAX_FILMS), e.g. { "hours": 3 }.
// Each person votes for one. Everyone else gets a push
router.post("/me/groups/:id/polls", async (req, res) => {
    const groupId = Number(req.params.id);
    const hours = Math.min(24, Math.max(1, Math.round(Number(req.body?.hours) || 3)));
    if (!Number.isInteger(groupId)) return res.status(400).json({ error: "Group not found." });
    try {
        if (!(await groupParticipants(req.user.uid, groupId))) return res.status(404).json({ error: "Group not found." });
        const films = await likedPicks(groupId, MAX_FILMS);
        if (films.length < MIN_FILMS) {
            return res.status(400).json({ error: `Like at least ${MIN_FILMS} films to start a vote.` });
        }
        const id = await startPoll(req.user.uid, groupId, films, hours);
        if (!id) return res.status(404).json({ error: "Group not found." });
        res.status(201).json(await currentPoll(req.user.uid, groupId));
    } catch (error) {
        console.error("Error starting poll:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The group's open vote, or the last one for a day after it closes; 204 when there's none
router.get("/me/groups/:id/polls/current", async (req, res) => {
    try {
        const poll = await currentPoll(req.user.uid, Number(req.params.id));
        if (!poll) return res.status(204).end();
        res.json(poll);
    } catch (error) {
        console.error("Error fetching poll:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Votes for one film, e.g. { "tmdb_id": 329865, "vote": 1 }. Each person has one vote, so this replaces any
// other; 0 (or -1, from older builds) takes it back. Returns the poll as it is now
router.put("/me/groups/:id/polls/:pollId/votes", async (req, res) => {
    const groupId = Number(req.params.id), pollId = Number(req.params.pollId), tmdbId = Number(req.body.tmdb_id);
    const value = Number(req.body.vote);
    if (![groupId, pollId, tmdbId].every(Number.isInteger) || ![1, 0, -1].includes(value)) {
        return res.status(400).json({ error: "A tmdb_id and a vote of 1, 0 or -1 are required." });
    }
    try {
        if (!(await vote(req.user.uid, groupId, pollId, tmdbId, value))) {
            return res.status(409).json({ error: "This vote has closed." });
        }
        res.json(await currentPoll(req.user.uid, groupId));
    } catch (error) {
        console.error("Error voting:", error);
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

// Makes the user's profile private (followers need approving) or public (anyone can follow straight away),
// e.g. { "private": true }. Going public accepts everyone waiting, and they're told
router.put("/me/privacy", async (req, res) => {
    if (typeof req.body.private !== "boolean") {
        return res.status(400).json({ error: "A true/false private is required." });
    }
    try {
        const accepted = await setPrivate(req.user.uid, req.body.private);
        if (accepted.length) {
            const me = await getProfile(req.user.uid);
            for (const follower of accepted) {
                notifyUser(follower, "follow_accepted", {
                    title: "Follow request accepted",
                    body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} accepted your request. You can now see their lists.`,
                    data: { handle: me?.handle ?? "" },
                });
            }
        }
        res.json({ private: req.body.private, accepted: accepted.length });
    } catch (error) {
        console.error("Error saving privacy:", error);
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
                body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} accepted your request. You can now see their lists.`,
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
    // Negative for a TV show (services/tmdbMedia.js)
    const tmdbId = Number(req.params.tmdb_id);
    if (!Number.isInteger(tmdbId) || tmdbId === 0) {
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

// What the people the user follows watched, rewatched and added to their lists lately, newest first, e.g.
// ?days=14 (1 to 30). Each entry has the friend, the film (with what the app needs to open it) and when
router.get("/me/activity", async (req, res) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 14, 1), 30);
    try {
        const rows = await fetchFriendActivity(req.user.uid, { days, limit: 200 });
        res.json(rows.filter((row) => row.handle).map((row) => ({
            kind: row.kind,
            rank: row.rank,
            list_name: row.list_name,
            at: new Date(row.at).toISOString(),
            handle: row.handle,
            avatar_version: row.avatar_version,
            tmdb_id: Number(row.tmdb_id),
            title: row.title,
            release_date: row.release_date ?? "",
            poster_path: row.poster_path,
            overview: row.overview ?? "",
            original_language: row.original_language ?? "",
            popularity: row.popularity ?? 0,
            my_list: row.my_list,
        })));
    } catch (error) {
        console.error("Error fetching friend activity:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Which episodes of a show the user has watched, e.g. /me/episodes/-1399 -> [{ season, episode }]
router.get("/me/episodes/:showId", async (req, res) => {
    const showId = Math.abs(parseInt(req.params.showId, 10));
    if (!(showId > 0)) return res.status(400).json({ error: "A show id is required." });
    try {
        res.json(await watchedEpisodes(req.user.uid, showId));
    } catch (error) {
        console.error("Error fetching watched episodes:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Marks episodes of one season watched or not, e.g. { "season": 2, "episodes": [1, 2, 3], "watched": true }, and
// replies with everything watched in the show
router.put("/me/episodes/:showId", async (req, res) => {
    const showId = Math.abs(parseInt(req.params.showId, 10));
    const season = parseInt(req.body?.season, 10);
    const episodes = (Array.isArray(req.body?.episodes) ? req.body.episodes : [])
        .map((n) => parseInt(n, 10)).filter((n) => Number.isInteger(n) && n > 0 && n < 10000).slice(0, 500);
    if (!(showId > 0) || !(season >= 0) || !episodes.length || typeof req.body?.watched !== "boolean") {
        return res.status(400).json({ error: "A show, season, episodes and watched are required." });
    }
    try {
        res.json(await setEpisodesWatched(req.user.uid, showId, season, episodes, req.body.watched));
    } catch (error) {
        console.error("Error saving watched episodes:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Films people sent the user, newest first
router.get("/me/recommendations", async (req, res) => {
    try {
        res.json(await fetchReceived(req.user.uid));
    } catch (error) {
        console.error("Error fetching recommendations:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Sends a film to people who follow the user or whom the user follows, e.g. { "handles": ["sam"], "tmdb_id": 329865,
// "title": "Arrival", "poster_path", "release_date", "overview", "original_language", "popularity", "note": "..." }.
// Replies with the @handles it went to
router.post("/me/recommendations", async (req, res) => {
    const body = req.body ?? {};
    const text = (value, max) => (typeof value === "string" ? value.trim().slice(0, max) : "");
    const handles = (Array.isArray(body.handles) ? body.handles : [])
        .map((handle) => text(handle, 40).replace(/^@/, "").toLowerCase()).filter(Boolean);
    const film = {
        // Negative for a TV show (services/tmdbMedia.js)
        tmdb_id: Number(body.tmdb_id),
        title: text(body.title, 255),
        poster_path: text(body.poster_path, 255) || null,
        release_date: text(body.release_date, 20),
        overview: text(body.overview, 2000),
        original_language: text(body.original_language, 10),
        popularity: Number(body.popularity) || 0,
    };
    const note = text(body.note, 300) || null;
    if (!handles.length || handles.length > MAX_RECIPIENTS) {
        return res.status(400).json({ error: `Pick between 1 and ${MAX_RECIPIENTS} people.` });
    }
    if (!Number.isInteger(film.tmdb_id) || film.tmdb_id === 0 || !film.title) {
        return res.status(400).json({ error: "A tmdb_id and title are required." });
    }
    try {
        const sentTo = await sendRecommendation(req.user.uid, handles, film, note);
        if (!sentTo.length) return res.status(403).json({ error: "You can only send films to people you follow or who follow you." });
        const me = await getProfile(req.user.uid);
        const from = me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone";
        const year = film.release_date.slice(0, 4);
        for (const recipient of sentTo) {
            notifyUser(recipient.firebase_uid, "recommendation", {
                title: `${from} thinks you should see this`,
                body: `${film.title}${year ? ` (${year})` : ""}${note ? `: "${note}"` : ""}`,
                data: { tmdb_id: String(film.tmdb_id) },
            });
        }
        res.status(201).json({ sent_to: sentTo.map((recipient) => recipient.handle) });
    } catch (error) {
        console.error("Error sending recommendation:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.put("/me/recommendations/seen", async (req, res) => {
    try {
        await markSeen(req.user.uid);
        res.json({ seen: true });
    } catch (error) {
        console.error("Error marking recommendations seen:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/me/recommendations/:id", async (req, res) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id)) return res.status(400).json({ error: "An id is required." });
    try {
        if (!(await removeReceived(req.user.uid, id))) return res.status(404).json({ error: "Not found." });
        res.json({ removed: true });
    } catch (error) {
        console.error("Error removing recommendation:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Reports another user, or something of theirs, e.g. { "handle": "sam", "content_type": "list", "content_id": "42",
// "reason": "harassment", "details": "..." }. content_type is "user" for the person as a whole. Reporting the same
// thing twice in a day only counts once
router.post("/reports", async (req, res) => {
    const body = req.body ?? {};
    const text = (value, max) => (typeof value === "string" || typeof value === "number" ? String(value).trim().slice(0, max) : "");
    const handle = text(body.handle, 40).replace(/^@/, "").toLowerCase();
    const report = {
        content_type: text(body.content_type, 20) || "user",
        content_id: text(body.content_id, 64) || null,
        reason: text(body.reason, 20),
        details: text(body.details, MAX_DETAILS) || null,
    };
    if (!handle) return res.status(400).json({ error: "Say who you're reporting." });
    if (!REPORT_CONTENT_TYPES.includes(report.content_type)) return res.status(400).json({ error: "That can't be reported." });
    if (!REPORT_REASONS.includes(report.reason)) return res.status(400).json({ error: "Pick a reason for the report." });
    try {
        const saved = await createReport(req.user.uid, handle, report);
        if (!saved) return res.status(404).json({ error: "User not found." });
        if (!saved.duplicate) notifyOperator({ ...report, id: saved.id, handle });
        res.status(201).json({ id: saved.id, received: true });
    } catch (error) {
        console.error("Error saving report:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The open reports, for reviewing them. Only for the Firebase uids in ADMIN_UIDS (comma separated)
router.get("/reports", async (req, res) => {
    const admins = (process.env.ADMIN_UIDS ?? "").split(",").map((uid) => uid.trim()).filter(Boolean);
    if (!admins.includes(req.user.uid)) return res.status(403).json({ error: "Forbidden" });
    try {
        res.json(await fetchOpenReports());
    } catch (error) {
        console.error("Error fetching reports:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The people the user has blocked
router.get("/me/blocked", async (req, res) => {
    try {
        res.json(await fetchBlocked(req.user.uid));
    } catch (error) {
        console.error("Error fetching blocked users:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Blocks or unblocks @handle. Blocking unfollows both ways and hides each from the other (see blockUser)
router.post("/:handle/block", async (req, res) => {
    try {
        const blocked = await blockUser(req.user.uid, req.params.handle.toLowerCase());
        if (!blocked) return res.status(404).json({ error: "User not found." });
        res.json({ handle: req.params.handle.toLowerCase(), blocked: true });
    } catch (error) {
        console.error("Error blocking user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/:handle/block", async (req, res) => {
    try {
        await unblockUser(req.user.uid, req.params.handle.toLowerCase());
        res.json({ handle: req.params.handle.toLowerCase(), blocked: false });
    } catch (error) {
        console.error("Error unblocking user:", error);
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
                body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} wants to follow you`,
                data: { handle: me?.handle ?? "" },
            });
        } else if (result.isNewFollow) {
            const me = await getProfile(req.user.uid);
            notifyUser(result.followee_id, "follow_new", {
                title: "New follower",
                body: `${me?.handle ? `@${me.handle}` : me?.display_name ?? "Someone"} started following you`,
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
