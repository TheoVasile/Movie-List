const express = require("express");
const { loginUser } = require("../controllers/authController");
const { deleteUser } = require("../models/userModel");
const verifyToken = require("../middleware/authMiddleware");

const router = express.Router();

router.post("/login", verifyToken, loginUser);

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