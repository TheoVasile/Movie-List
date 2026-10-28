const express = require("express");

// Discover reactions, mounted at /movies/discover/reactions (signed in and rate limited like every /movies route):
//   POST   /                { tmdb_id, reaction: "like" | "dislike" | "skip", source? } -> { ok: true }
//   POST   /bulk            { reactions: [{ tmdb_id, reaction, at? }] } (at most 2000; the newest reaction to a film
//                            wins) -> { ok: true, saved }. For moving a device's history to the server once
//   GET    /                -> { reactions: [{ tmdb_id, reaction, updated_at }] }, newest first
//   DELETE /                deletes them all (Reset Taste Profile); ?tmdb_id= deletes one (Undo); ?reaction=skip
//                            deletes every skip (Show Skipped Again) -> { ok: true, deleted }
// Skips keep a film out of Discover for 30 days; likes and dislikes for good
// TV shows have negative ids. The model (models/reactionsModel.js) and onChange (called with the user's id after a
// change, to forget their cached taste) are passed in, so tests can use stand-ins

/// A film or show id, or null
function tmdbIdOf(value) {
    const id = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
    return Number.isInteger(id) && id !== 0 && Math.abs(id) < 2 ** 31 ? id : null;
}

function createReactionsRouter(model, onChange = () => {}) {
    const router = express.Router();
    const valid = (reaction) => model.REACTIONS.includes(reaction);

    router.post("/", async (req, res) => {
        const body = req.body ?? {};
        const tmdbId = tmdbIdOf(body.tmdb_id);
        if (tmdbId === null || !valid(body.reaction)) {
            return res.status(400).json({ error: "A tmdb_id and a reaction (like, dislike or skip) are required." });
        }
        const source = typeof body.source === "string" && body.source.trim() ? body.source.trim().slice(0, 40) : null;
        try {
            await model.upsertReaction(req.user.uid, tmdbId, body.reaction, source);
            onChange(req.user.uid);
            res.json({ ok: true });
        } catch (error) {
            console.error("Error saving a Discover reaction:", error.message);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    router.post("/bulk", async (req, res) => {
        const list = req.body?.reactions;
        if (!Array.isArray(list)) return res.status(400).json({ error: "reactions must be an array." });
        if (list.length > model.MAX_BULK) {
            return res.status(400).json({ error: `At most ${model.MAX_BULK} reactions at a time.` });
        }
        const now = new Date();
        // Entries that aren't valid are skipped rather than failing the rest; a missing, bad or future time is now
        const reactions = list.flatMap((entry) => {
            const tmdbId = tmdbIdOf(entry?.tmdb_id);
            if (tmdbId === null || !valid(entry?.reaction)) return [];
            const at = new Date(entry.at ?? NaN);
            return [{ tmdb_id: tmdbId, reaction: entry.reaction, at: Number.isNaN(at.getTime()) || at > now ? now : at }];
        });
        try {
            const saved = await model.upsertReactions(req.user.uid, reactions);
            onChange(req.user.uid);
            res.json({ ok: true, saved });
        } catch (error) {
            console.error("Error saving Discover reactions:", error.message);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    router.get("/", async (req, res) => {
        try {
            const reactions = await model.fetchReactions(req.user.uid);
            res.json({ reactions: reactions.map((row) => ({ tmdb_id: Number(row.tmdb_id), reaction: row.reaction, updated_at: row.updated_at })) });
        } catch (error) {
            console.error("Error fetching Discover reactions:", error.message);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    router.delete("/", async (req, res) => {
        let tmdbId = null;
        if (req.query.tmdb_id !== undefined) {
            tmdbId = tmdbIdOf(String(req.query.tmdb_id));
            if (tmdbId === null) return res.status(400).json({ error: "tmdb_id must be a film id." });
        }
        let reaction = null;
        if (req.query.reaction !== undefined) {
            reaction = String(req.query.reaction);
            if (!valid(reaction)) return res.status(400).json({ error: "reaction must be like, dislike or skip." });
        }
        try {
            const deleted = await model.deleteReactions(req.user.uid, tmdbId, reaction);
            onChange(req.user.uid);
            res.json({ ok: true, deleted });
        } catch (error) {
            console.error("Error deleting Discover reactions:", error.message);
            res.status(500).json({ error: "Internal server error" });
        }
    });

    return router;
}

module.exports = { createReactionsRouter, tmdbIdOf };
