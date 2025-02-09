const { getUserByFirebaseUID, createUser } = require("../models/userModel");

async function loginUser(req, res) {
  try {
    const { uid, email } = req.user;

    let user = await getUserByFirebaseUID(uid);
    if (!user) {
      user = await createUser(uid, email, `user_${uid.substring(0, 6)}`);
    }

    res.json({ user });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
}

module.exports = { loginUser };