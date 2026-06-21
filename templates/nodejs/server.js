import express from "express";

const app = express();
const port = process.env.PORT || 3000;

app.get("/healthz", (_req, res) => res.json({ status: "ok" }));
app.get("/", (_req, res) => res.json({ message: "hello from node" }));

app.listen(port, "0.0.0.0", () => {
  console.log(`listening on :${port}`);
});
