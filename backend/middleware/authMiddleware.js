const admin = require("../config/firebase");

// Requires a valid Firebase ID token ("Authorization: Bearer <token>") and exposes the
// decoded token as req.user. Routes must take the caller's identity from req.user.uid,
// never from the request body or query
async function verifyToken(req, res, next) {
  try {
    const token = req.headers.authorization?.split(" ")[1];
    if (!token) return res.status(401).json({ error: "Unauthorized" });

    const decoded = await admin.auth().verifyIdToken(token);
    req.user = decoded;
    next();
  } catch (error) {
    return res.status(401).json({ error: "Invalid token" });
  }
}

module.exports = verifyToken;
