const express = require("express");
const { createList, deleteList, fetchLists } = require("../models/listModel");
const requireListOwner = require("../middleware/listOwnership");
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

// Marks every film in one of the user's lists as watched or unwatched
router.put("/:id/watched", requireListOwner((req) => req.params.id), async (req, res) => {
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