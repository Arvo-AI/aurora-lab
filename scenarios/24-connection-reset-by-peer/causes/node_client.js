const http = require("http");
const [mode, url, mb] = process.argv.slice(2);
const req = http.request(url, { method: mode === "upload" ? "POST" : "GET", timeout: 90000 }, res => {
  res.on("data", () => {});
  res.on("end", () => console.log("node status:", res.statusCode));
  res.on("error", e => console.log(`node response error: code=${e.code} message=${e.message}`));
});
req.on("error", e => console.log(`node error: code=${e.code} message=${e.message}`));
if (mode === "upload") {
  let left = (Number(mb) || 40) * 4;
  const buf = Buffer.alloc(262144);
  const t = setInterval(() => { if (left-- <= 0) { clearInterval(t); req.end(); } else if (!req.destroyed) req.write(buf); else clearInterval(t); }, 250);
} else req.end();
