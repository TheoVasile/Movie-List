const express = require("express");
const { loginUser } = require("../controllers/authController");
const { deleteUser, createUser } = require("../models/userModel");
const verifyToken = require("../middleware/authMiddleware");
const { isValidHandle, setHandle, HandleTakenError } = require("../models/socialModel");
const pool = require("../config/db");
const { TERMS_VERSION, TERMS_UPDATED, PRIVACY_VERSION, PRIVACY_UPDATED, loadTerms, loadPrivacy } = require("../config/terms");

const router = express.Router();

router.post("/login", verifyToken, loginUser);

// Makes the account, e.g. { "username": "Theo", "handle": "theo.v" }. The handle is saved too when it's
// valid and free; handle_saved says whether it was, and the app asks for another one if not
router.post("/create", verifyToken, async (req, res) => {
    try {
        const { username } = req.body;
        const newUser = await createUser(req.user.uid, req.user.email ?? req.body.email, username);
        const handle = typeof req.body.handle === "string" ? req.body.handle.trim().toLowerCase() : "";
        let handle_saved = false;
        if (isValidHandle(handle)) {
            try {
                await setHandle(req.user.uid, handle);
                handle_saved = true;
            } catch (error) {
                if (!(error instanceof HandleTakenError)) throw error;
            }
        }
        res.status(200).json({ ...newUser, handle_saved });
    } catch (error) {
        console.error("Error creating user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// How many availability checks one address can make a minute, so this can't be used to list usernames
const MAX_CHECKS_PER_MINUTE = 30;
const recentChecks = new Map();

// Whether an @username is free, for the sign-up form before the account exists, e.g.
// /auth/handle-available?handle=theo.v -> { "valid": true, "available": false }
router.get("/handle-available", async (req, res) => {
    // The last X-Forwarded-For entry is the one Render's proxy added; earlier ones come from the client
    const address = String(req.headers["x-forwarded-for"] ?? req.ip ?? "").split(",").pop().trim();
    const now = Date.now();
    const recent = (recentChecks.get(address) ?? []).filter((time) => now - time < 60 * 1000);
    if (recent.length >= MAX_CHECKS_PER_MINUTE) {
        return res.status(429).json({ error: "Too many checks. Try again in a minute." });
    }
    recent.push(now);
    // Old addresses are forgotten wholesale rather than one by one
    if (recentChecks.size > 10000) recentChecks.clear();
    recentChecks.set(address, recent);

    const handle = String(req.query.handle ?? "").trim().toLowerCase().replace(/^@/, "");
    if (!isValidHandle(handle)) return res.json({ valid: false, available: false });
    try {
        const taken = await pool.query("SELECT 1 FROM users WHERE handle = $1", [handle]);
        res.json({ valid: true, available: taken.rowCount === 0 });
    } catch (error) {
        console.error("Error checking username:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The Terms of Service, for the screen that asks people to accept them, before and after sign-up
// -> { "version": "2026-10-23", "updated": "October 23, 2026", "markdown": "# Terms of Service ..." }
router.get("/terms", (req, res) => {
    try {
        res.json({ version: TERMS_VERSION, updated: TERMS_UPDATED, markdown: loadTerms() });
    } catch (error) {
        console.error("Error loading terms:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// The Privacy Policy, for reading in the app, signed in or not
// -> { "version": "2026-10-24", "updated": "October 24, 2026", "markdown": "# CineList Privacy Policy ..." }
router.get("/privacy", (req, res) => {
    try {
        res.json({ version: PRIVACY_VERSION, updated: PRIVACY_UPDATED, markdown: loadPrivacy() });
    } catch (error) {
        console.error("Error loading privacy policy:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// How recently someone must have signed in, or confirmed their password or Google account, to delete their account
const DELETE_SIGN_IN_WINDOW_SECONDS = 5 * 60;

// Permanently deletes the signed-in user's account, its data and its Firebase sign-in. Only their own: the uid has
// to match the token's. The app has them confirm their password or Google account first, so a phone left signed in
// isn't enough to delete the account
router.delete("/delete/:uid", verifyToken, async (req, res) => {
    try {
        const { uid } = req.params;
        if (uid !== req.user.uid) {
            return res.status(403).json({ error: "You can only delete your own account." });
        }
        if (Date.now() / 1000 - (req.user.auth_time ?? 0) > DELETE_SIGN_IN_WINDOW_SECONDS) {
            return res.status(401).json({ error: "For your security, confirm it's you again, then delete your account." });
        }
        const removed = await deleteUser(uid);
        res.status(200).json({ deleted: true, removed });
    } catch (error) {
        console.error("Error removing user:", error);
        res.status(500).json({ error: "Couldn't delete your account. Try again in a moment." });
    }
});

module.exports = router;