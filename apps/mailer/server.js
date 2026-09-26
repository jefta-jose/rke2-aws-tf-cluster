// rok-mailer — Phase 9.2
// A tiny, dependency-free service: POST /api/email {to,subject,body} opens a raw
// SMTP conversation with the in-cluster mailpit sink and sends the message.
// SMTP_HOST/SMTP_PORT arrive as env (from development-rok-general-secret via ESO:
// Smtp__Host=mailpit-smtp.mailhog, Smtp__Port=1025). No auth, no TLS — mailpit is a
// test sink. Same zero-dependency style as apps/backend/server.js.
const http = require('http');
const net = require('net');

const PORT = parseInt(process.env.PORT || '8080', 10);
const SMTP_HOST = process.env.SMTP_HOST || 'mailpit-smtp.mailhog';
const SMTP_PORT = parseInt(process.env.SMTP_PORT || '1025', 10);
const MAIL_FROM = process.env.MAIL_FROM || 'noreply@rok.local';

// Minimal SMTP client. Drives an ordered exchange: wait for `code`, then send `cmd`.
// The banner (220) is the first thing the server sends, so it leads the list.
function sendMail({ to, subject, body }) {
  const oneLine = (s) => String(s).replace(/[\r\n]+/g, ' ').trim();
  const from = MAIL_FROM;
  to = oneLine(to);
  subject = oneLine(subject);

  // Body: normalize newlines to CRLF and dot-stuff lines starting with '.' (RFC 5321).
  const message =
    `From: ${from}\r\n` +
    `To: ${to}\r\n` +
    `Subject: ${subject}\r\n` +
    `Date: ${new Date().toUTCString()}\r\n` +
    `MIME-Version: 1.0\r\n` +
    `Content-Type: text/plain; charset=utf-8\r\n` +
    `\r\n` +
    String(body || '')
      .replace(/\r?\n/g, '\r\n')
      .split('\r\n')
      .map((l) => (l.startsWith('.') ? '.' + l : l))
      .join('\r\n') +
    `\r\n.\r\n`;

  const steps = [
    { code: 220, cmd: `EHLO rok-mailer\r\n` },
    { code: 250, cmd: `MAIL FROM:<${from}>\r\n` },
    { code: 250, cmd: `RCPT TO:<${to}>\r\n` },
    { code: 250, cmd: `DATA\r\n` },
    { code: 354, cmd: message },
    { code: 250, cmd: `QUIT\r\n` },
    { code: 221, cmd: null },
  ];

  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SMTP_PORT, SMTP_HOST);
    socket.setEncoding('utf8');
    socket.setTimeout(10000);

    let i = 0;
    let buf = '';
    let done = false;
    const fail = (msg) => {
      if (done) return;
      done = true;
      socket.destroy();
      reject(new Error(msg));
    };

    socket.on('data', (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf('\r\n')) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        if (line.length >= 4 && line[3] === '-') continue; // multiline continuation
        const code = parseInt(line.slice(0, 3), 10);
        const step = steps[i];
        if (!step) return;
        if (code !== step.code) return fail(`SMTP step ${i}: expected ${step.code}, got "${line}"`);
        i += 1;
        if (step.cmd) socket.write(step.cmd);
        if (i >= steps.length) {
          done = true;
          socket.end();
          return resolve();
        }
      }
    });

    socket.on('timeout', () => fail(`SMTP timeout talking to ${SMTP_HOST}:${SMTP_PORT}`));
    socket.on('error', (e) => fail(`SMTP socket error: ${e.message}`));
    socket.on('close', () => {
      if (!done) fail('SMTP connection closed before the message was accepted');
    });
  });
}

const json = (res, status, obj) => {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
};

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    return json(res, 200, { status: 'ok', sink: `${SMTP_HOST}:${SMTP_PORT}` });
  }

  if (req.method === 'POST' && req.url === '/api/email') {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 1e6) req.destroy(); // cap the body
    });
    req.on('end', async () => {
      let payload;
      try {
        payload = JSON.parse(data || '{}');
      } catch {
        return json(res, 400, { error: 'invalid JSON body' });
      }
      const { to, subject, body } = payload;
      if (!to || !subject) {
        return json(res, 400, { error: 'fields "to" and "subject" are required' });
      }
      try {
        await sendMail({ to, subject, body });
        return json(res, 200, { status: 'sent', to, subject, sink: `${SMTP_HOST}:${SMTP_PORT}` });
      } catch (e) {
        return json(res, 502, { error: 'send failed', detail: e.message });
      }
    });
    return;
  }

  json(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`rok-mailer listening on :${PORT}, SMTP sink ${SMTP_HOST}:${SMTP_PORT}`);
});
