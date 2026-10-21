const express = require("express");
const {
    createList, deleteList, fetchLists, updateList, setListFollowed, addListEditor, removeListEditor, VISIBILITIES, MAX_EDITORS,
} = require("../models/listModel");
const requireListOwner = require("../middleware/listOwnership");
const { requireListEditor } = requireListOwner;
const { notifyUser } = require("../services/pushService");
const pool = require("../config/db");
const { setListWatched } = require("../models/watchedModel");

const router = express.Router();

router.post("/create", async (req, res) => {
    try {
        const { name, overview, is_ranked } = req.body;
        if (!name) {
            return res.status(400).json({ error: "Name is required." });
        }
        const newList = await createList(req.user.uid, name, overview, is_ranked);
        res.status(201).json(newList);
    } catch (error) {
        console.error("Error creating list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.get("/fetch", async (req, res) => {
    try {
        const lists = await fetchLists(req.user.uid);
        res.status(200).json(lists);
    } catch (error) {
        console.error("Error fetching lists:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Marks every film in one of the user's lists (or a list they edit) as watched or unwatched, for them
router.put("/:id/watched", requireListEditor((req) => req.params.id), async (req, res) => {
    try {
        if (typeof req.body.watched !== "boolean") {
            return res.status(400).json({ error: "A true/false watched is required." });
        }
        await setListWatched(req.user.uid, Number(req.params.id), req.body.watched);
        res.status(200).json({ list_id: Number(req.params.id), watched: req.body.watched });
    } catch (error) {
        console.error("Error updating watched status for list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Renames a list and/or changes its description, e.g. { "name": "Best of 2026", "overview": "..." }
router.put("/:id", requireListOwner((req) => req.params.id), async (req, res) => {
    try {
        const { name, overview, visibility } = req.body;
        if (name !== undefined && (typeof name !== "string" || !name.trim() || name.length > 100)) {
            return res.status(400).json({ error: "A name must be 1 to 100 characters." });
        }
        if (overview !== undefined && (typeof overview !== "string" || overview.length > 2000)) {
            return res.status(400).json({ error: "A description must be at most 2000 characters." });
        }
        if (visibility !== undefined && !VISIBILITIES.includes(visibility)) {
            return res.status(400).json({ error: "Visibility must be public, followers or private." });
        }
        if (name === undefined && overview === undefined && visibility === undefined) {
            return res.status(400).json({ error: "Nothing to update." });
        }
        const list = await updateList(Number(req.params.id), { name: name?.trim(), overview, visibility });
        res.status(200).json(list);
    } catch (error) {
        console.error("Error updating list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Invites someone the owner follows to edit the list with them, e.g. { "handle": "sam" }. They get a push
router.post("/:id/editors", requireListOwner((req) => req.params.id), async (req, res) => {
    try {
        const handle = String(req.body.handle ?? "").trim().replace(/^@/, "").toLowerCase();
        if (!handle) return res.status(400).json({ error: "A handle is required." });
        const result = await addListEditor(req.user.uid, Number(req.params.id), handle);
        switch (result.error) {
            case "not_found": return res.status(404).json({ error: "List not found." });
            case "not_following": return res.status(400).json({ error: "You can only invite people you follow." });
            case "full": return res.status(400).json({ error: `A list can have at most ${MAX_EDITORS} editors.` });
            case "already": return res.status(409).json({ error: "They can already edit this list." });
        }
        const me = await pool.query("SELECT COALESCE('@' || handle, username) AS name FROM users WHERE firebase_uid = $1", [req.user.uid]);
        await notifyUser(result.editor_id, "list_invite", {
            title: "New shared list",
            body: `${me.rows[0]?.name ?? "A friend"} added you to "${result.list_name}". You can add and rank films in it.`,
            data: { list_id: String(req.params.id) },
        });
        res.status(201).json({ list_id: Number(req.params.id), handle });
    } catch (error) {
        console.error("Error adding list editor:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Takes someone off a shared list. The owner can remove anyone; "me" leaves a list the user was invited to
router.delete("/:id/editors/:handle", async (req, res) => {
    try {
        const id = Number(req.params.id);
        const handle = req.params.handle === "me" ? null : String(req.params.handle).toLowerCase();
        if (!Number.isInteger(id) || !(await removeListEditor(req.user.uid, id, handle))) {
            return res.status(404).json({ error: "Not found." });
        }
        res.json({ list_id: id, removed: req.params.handle });
    } catch (error) {
        console.error("Error removing list editor:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Follows someone else's list, to hear about films added to it in the daily digest
router.post("/:id/follow", (req, res) => followList(req, res, true));
router.delete("/:id/follow", (req, res) => followList(req, res, false));

async function followList(req, res, follow) {
    try {
        const id = Number(req.params.id);
        if (!Number.isInteger(id) || !(await setListFollowed(req.user.uid, id, follow))) {
            return res.status(404).json({ error: "List not found." });
        }
        res.json({ list_id: id, followed: follow });
    } catch (error) {
        console.error("Error following list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
}

router.delete("/delete/:id", requireListOwner((req) => req.params.id), async (req, res) => {
    try {
        const { id } = req.params;
        const deletedList = await deleteList(id);
        res.status(200).json(deletedList);
    } catch (error) {
        console.error("Error deleting list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;