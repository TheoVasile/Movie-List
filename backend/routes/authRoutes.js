const express = require("express");
const { loginUser } = require("../controllers/authController");
const verifyToken = require("../middleware/authMiddleware");

const router = express.Router();

router.post("/login", verifyToken, loginUser);

module.exports = router;