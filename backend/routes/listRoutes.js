const express = require("express");
const { createList, deleteList } = require("../models/listModel");

const router = express.Router();

router.post("/create", async (req, res) => {
    try {
        const { user_id, name, overview, is_ranked } = req.body;
        console.log(req.body)
        if (!user_id || !name) {
            return res.status(400).json({ error: "User ID and name are required." });
        }
        const newList = await createList(user_id, name, overview, is_ranked);
        res.status(201).json(newList);
    } catch (error) {
        console.error("Error creating list:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/delete/:id", async (req, res) => {
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