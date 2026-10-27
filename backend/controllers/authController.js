const { getUserByFirebaseUID, createUser, accountJSON } = require("../models/userModel");

async function loginUser(req, res) {
  try {
    const { uid, email } = req.user;

    let user = await getUserByFirebaseUID(uid);
    if (!user) {
      user = await createUser(uid, email, `user_${uid.substring(0, 6)}`);
    }

    // Only { firebase_uid, handle, name }: never the whole row
    res.json({ user: accountJSON(user) });
  } catch (error) {
    console.error("Error signing in:", error);
    res.status(500).json({ error: "Internal server error" });
  }
}

module.exports = { loginUser };