const express = require("express");
const authRoutes = require("./routes/authRoutes");
const listRoutes = require("./routes/listRoutes");
const movieRoutes = require("./routes/movieRoutes");
const letterboxdRoutes = require("./routes/letterboxdRoutes");
const createTables = require("./migrations/setupDB");
const verifyToken = require("./middleware/authMiddleware");
const cors = require("cors");
const pool = require("./config/db");

const app = express();
// Letterboxd imports can carry thousands of films in one request
app.use(express.json({ limit: "5mb" }));
app.use(cors());

createTables();

app.use("/auth", authRoutes);
// Everything except account setup needs a signed-in user; /auth checks tokens per route
app.use("/lists", verifyToken, listRoutes);
app.use("/movies", verifyToken, movieRoutes);
app.use("/letterboxd", verifyToken, letterboxdRoutes);

app.listen(3000, () => console.log("Server running on port 3000"));

const shutdown = () => {
    console.log("\n🔻 Closing database connection pool...");
    pool.end(() => {
        console.log("✅ Pool closed. Exiting process...");
        process.exit(0);
    });
};

process.on("SIGINT", shutdown); // Ctrl + C
process.on("SIGTERM", shutdown);