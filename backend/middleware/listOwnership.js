const { isListOwner } = require("../models/listModel");

// Only lets a request through when the list it touches belongs to the signed-in user.
// Must run after verifyToken. Answers 404 rather than 403 so other users' list ids can't be probed
function requireListOwner(getListId) {
    return async (req, res, next) => {
        try {
            const listId = Number(getListId(req));
            if (!Number.isInteger(listId) || !(await isListOwner(listId, req.user.uid))) {
                return res.status(404).json({ error: "List not found." });
            }
            next();
        } catch (error) {
            console.error("Error checking list ownership:", error);
            res.status(500).json({ error: "Internal server error" });
        }
    };
}

module.exports = requireListOwner;
