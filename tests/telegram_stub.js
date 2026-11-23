// A stand-in for the Telegram Bot API, for away_test.sh. Logs every call; control: GET /_log, POST /_push, POST /_reset.
const http = require('http');
let log = [], updates = [], nextUpdate = 1, nextMessage = 100;
const send = (res, o) => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(o)); };
http.createServer((req, res) => {
  let raw = ''; req.on('data', c => raw += c); req.on('end', () => {
    const body = raw ? JSON.parse(raw) : {};
    if (req.url === '/_log') return send(res, log);
    if (req.url === '/_reset') { log = []; updates = []; return send(res, {}); }
    if (req.url === '/_push') { updates.push({ update_id: nextUpdate++, ...body }); return send(res, {}); }
    const m = /^\/bot([^/]+)\/(\w+)$/.exec(req.url); if (!m) { res.statusCode = 404; return res.end(); }
    log.push({ token: m[1], method: m[2], body });
    if (m[2] === 'sendMessage') return send(res, { ok: true, result: { message_id: nextMessage++ } });
    if (m[2] === 'getUpdates') {
      updates = updates.filter(u => u.update_id >= (body.offset || 0));
      return send(res, { ok: true, result: updates });
    }
    send(res, { ok: true, result: true });
  });
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
