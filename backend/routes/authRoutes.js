const express = require("express");
const { loginUser } = require("../controllers/authController");
const { deleteUser, createUser } = require("../models/userModel");
const verifyToken = require("../middleware/authMiddleware");

const router = express.Router();

router.post("/login", verifyToken, loginUser);

router.post("/create", async (req, res) => {
    try {
        const { firebase_id, email, username } = req.body;
        const newUser = await createUser(firebase_id, email, username);
        res.status(200).json(newUser);
    } catch (error) {
        console.error("Error creating user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/delete/:uid", async (req, res) => {
    try {
        const { uid } = req.params;
        const removedUser = await deleteUser(uid);
        res.status(200).json(removedUser);
    } catch (error) {
        console.error("Error removing user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;