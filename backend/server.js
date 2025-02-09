const express = require("express");
const authRoutes = require("./routes/authRoutes");
const createTables = require("./migrations/setupDB");

const app = express();
app.use(express.json());

createTables();

app.use("/auth", authRoutes);

app.listen(3000, () => console.log("Server running on port 3000"));