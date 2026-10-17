const express = require("express");
const { loginUser } = require("../controllers/authController");
const { deleteUser, createUser } = require("../models/userModel");
const verifyToken = require("../middleware/authMiddleware");

const router = express.Router();

router.post("/login", verifyToken, loginUser);

router.post("/create", verifyToken, async (req, res) => {
    try {
        const { username } = req.body;
        const newUser = await createUser(req.user.uid, req.user.email ?? req.body.email, username);
        res.status(200).json(newUser);
    } catch (error) {
        console.error("Error creating user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

router.delete("/delete/:uid", verifyToken, async (req, res) => {
    try {
        const { uid } = req.params;
        if (uid !== req.user.uid) {
            return res.status(403).json({ error: "You can only delete your own account." });
        }
        const removedUser = await deleteUser(uid);
        res.status(200).json(removedUser);
    } catch (error) {
        console.error("Error removing user:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

module.exports = router;