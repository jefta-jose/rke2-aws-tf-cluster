import React, { useState } from 'react'

// Every call goes to a relative /api/<service>/... path. nginx (same origin) reverse-proxies those
// to the in-cluster Services, so the browser only ever talks to the Traefik `web` entrypoint and
// each call generates http.server.requests metrics on the backend it lands on. The `pod` field in
// each response shows WHICH pod served it — handy once service-a is scaled across the two workers.

async function callApi(path) {
  const started = performance.now()
  const res = await fetch(path)
  const ms = Math.round(performance.now() - started)
  let body
  try {
    body = await res.json()
  } catch {
    body = { error: `non-JSON (${res.status})` }
  }
  return { ok: res.ok, status: res.status, ms, body }
}

function ServiceCard({ title, actions }) {
  const [last, setLast] = useState(null)
  const [busy, setBusy] = useState(false)

  async function run(path) {
    setBusy(true)
    try {
      setLast(await callApi(path))
    } catch (e) {
      setLast({ ok: false, status: 0, ms: 0, body: { error: String(e) } })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="card">
      <h2>{title}</h2>
      <div className="btns">
        {actions.map((a) => (
          <button key={a.label} disabled={busy} onClick={() => run(a.path)}>
            {a.label}
          </button>
        ))}
      </div>
      {last && (
        <div className={last.ok ? 'out ok' : 'out err'}>
          <div className="meta">
            <span>status {last.status}</span>
            <span>{last.ms} ms</span>
            {last.body?.pod && <span className="pod">pod {last.body.pod}</span>}
          </div>
          <pre>{JSON.stringify(last.body, null, 2)}</pre>
        </div>
      )}
    </div>
  )
}

export default function App() {
  const [loadMsg, setLoadMsg] = useState('')

  // Fire a burst of requests to light up the metrics in Prometheus/Grafana.
  async function loadTest() {
    setLoadMsg('running…')
    const paths = [
      '/api/service-a/work',
      '/api/service-a/visit',
      '/api/service-b/work',
    ]
    const n = 60
    const jobs = Array.from({ length: n }, (_, i) => callApi(paths[i % paths.length]))
    const done = await Promise.allSettled(jobs)
    const okCount = done.filter((d) => d.status === 'fulfilled' && d.value.ok).length
    setLoadMsg(`sent ${n}, ${okCount} ok — check Prometheus/Grafana`)
  }

  return (
    <main>
      <header>
        <h1>Nimbus</h1>
        <p>React → nginx → Traefik <code>web</code> → service-a / service-b → Postgres</p>
      </header>

      <div className="grid">
        <ServiceCard
          title="service-a (Postgres)"
          actions={[
            { label: 'Info', path: '/api/service-a/' },
            { label: 'Visit (DB)', path: '/api/service-a/visit' },
            { label: 'Work', path: '/api/service-a/work' },
          ]}
        />
        <ServiceCard
          title="service-b (stateless)"
          actions={[
            { label: 'Info', path: '/api/service-b/' },
            { label: 'Work', path: '/api/service-b/work' },
          ]}
        />
      </div>

      <div className="loadbar">
        <button onClick={loadTest}>Load test (60 requests)</button>
        <span>{loadMsg}</span>
      </div>
    </main>
  )
}
