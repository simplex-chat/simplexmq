// IndexedDB implementation of AgentStore.
// Each method is a faithful transpilation of SQL in AgentStore.hs.
//
// Transpilation approach:
// - Each SQL query is converted to equivalent IndexedDB operations
// - Field names match SQLite column names from agent_schema.sql
// - Transaction scoping matches the Haskell withStore patterns
//
// This file is a work in progress — methods are added as they are transpiled
// from the Haskell source.

import type {AgentStore, ConnId, UserId} from "./store.js"

const DB_NAME = "simplex-agent"
const DB_VERSION = 1

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")
}

function compareUint8Array(a: Uint8Array, b: Uint8Array): number {
  const len = Math.min(a.length, b.length)
  for (let i = 0; i < len; i++) {
    if (a[i] !== b[i]) return a[i] - b[i]
  }
  return a.length - b.length
}

// -- Database opening + schema creation (from agent_schema.sql)

export async function openAgentStore(): Promise<AgentStore> {
  const db = await openDB()
  return createStore(db)
}

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION)
    req.onerror = () => reject(req.error)
    req.onsuccess = () => resolve(req.result)
    req.onupgradeneeded = () => createSchema(req.result)
  })
}

// Schema mirrors agent_schema.sql tables needed for MVP
function createSchema(db: IDBDatabase): void {
  // users — agent_schema.sql:266-270
  // CREATE TABLE users(user_id INTEGER PRIMARY KEY AUTOINCREMENT, deleted INTEGER DEFAULT 0)
  db.createObjectStore("users", {keyPath: "user_id", autoIncrement: true})

  // servers — agent_schema.sql:6-11
  // Deviation from Haskell: keyHash is part of the primary key (Haskell uses (host,port) as workaround to avoid migration)
  db.createObjectStore("servers", {keyPath: ["host", "port", "key_hash"]})

  // connections — agent_schema.sql:12-31
  const conns = db.createObjectStore("connections", {keyPath: "conn_id"})
  conns.createIndex("user_id", "user_id")

  // rcv_queues — agent_schema.sql:32-70
  const rcvQ = db.createObjectStore("rcv_queues", {keyPath: ["host", "port", "rcv_id"]})
  rcvQ.createIndex("conn_id", "conn_id")
  rcvQ.createIndex("conn_id_rcv_queue_id", ["conn_id", "rcv_queue_id"], {unique: true})

  // snd_queues — agent_schema.sql:71-92
  const sndQ = db.createObjectStore("snd_queues", {keyPath: ["host", "port", "snd_id"]})
  sndQ.createIndex("conn_id", "conn_id")
  sndQ.createIndex("conn_id_snd_queue_id", ["conn_id", "snd_queue_id"], {unique: true})

  // messages — agent_schema.sql:93-109
  const msgs = db.createObjectStore("messages", {keyPath: ["conn_id", "internal_id"]})
  msgs.createIndex("conn_id", "conn_id")
  msgs.createIndex("conn_id_internal_rcv_id", ["conn_id", "internal_rcv_id"])
  msgs.createIndex("conn_id_internal_snd_id", ["conn_id", "internal_snd_id"])

  // rcv_messages — agent_schema.sql:110-126
  const rcvMsgs = db.createObjectStore("rcv_messages", {keyPath: ["conn_id", "internal_rcv_id"]})
  rcvMsgs.createIndex("conn_id_internal_id", ["conn_id", "internal_id"])
  rcvMsgs.createIndex("conn_id_broker_id", ["conn_id", "broker_id"])

  // snd_messages — agent_schema.sql:127-143
  const sndMsgs = db.createObjectStore("snd_messages", {keyPath: ["conn_id", "internal_snd_id"]})
  sndMsgs.createIndex("conn_id_internal_id", ["conn_id", "internal_id"])

  // snd_message_deliveries — agent_schema.sql:257-264
  const sndDel = db.createObjectStore("snd_message_deliveries", {keyPath: "snd_message_delivery_id", autoIncrement: true})
  sndDel.createIndex("conn_id_snd_queue_id", ["conn_id", "snd_queue_id"])

  // snd_message_bodies — agent_schema.sql:428-431
  db.createObjectStore("snd_message_bodies", {keyPath: "snd_message_body_id", autoIncrement: true})

  // conn_confirmations — agent_schema.sql:144-157
  const confs = db.createObjectStore("conn_confirmations", {keyPath: "confirmation_id"})
  confs.createIndex("conn_id", "conn_id")

  // conn_invitations — agent_schema.sql:158-166
  const invs = db.createObjectStore("conn_invitations", {keyPath: "invitation_id"})
  invs.createIndex("contact_conn_id", "contact_conn_id")

  // ratchets — agent_schema.sql:167-181
  db.createObjectStore("ratchets", {keyPath: "conn_id"})

  // skipped_messages — agent_schema.sql:182-189
  const skip = db.createObjectStore("skipped_messages", {keyPath: "skipped_message_id", autoIncrement: true})
  skip.createIndex("conn_id", "conn_id")

  // commands — agent_schema.sql:242-256
  const cmds = db.createObjectStore("commands", {keyPath: "command_id", autoIncrement: true})
  cmds.createIndex("conn_id", "conn_id")
  cmds.createIndex("host_port", ["host", "port"])

  // encrypted_rcv_message_hashes — agent_schema.sql:397-403
  const hashes = db.createObjectStore("encrypted_rcv_message_hashes", {keyPath: "encrypted_rcv_message_hash_id", autoIncrement: true})
  hashes.createIndex("conn_id_hash", ["conn_id", "hash"])
}

// -- Helpers

function idbReq<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  })
}

function eqBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

// IndexedDB index.getAll() with Uint8Array keys doesn't work in fake-indexeddb polyfill.
// These helpers scan all records and filter by field values, handling Uint8Array comparison.
function fieldEq(a: any, b: any): boolean {
  if (a instanceof Uint8Array && b instanceof Uint8Array) return eqBytes(a, b)
  return a === b
}

async function allByIndex(store: IDBObjectStore, fields: Record<string, any>): Promise<any[]> {
  const all = await idbReq(store.getAll())
  return all.filter(r => Object.entries(fields).every(([k, v]) => fieldEq(r[k], v)))
}

function createStore(db: IDBDatabase): AgentStore {
  // Transaction helper
  function withTx<T>(stores: string | string[], mode: IDBTransactionMode, fn: (tx: IDBTransaction) => Promise<T>): Promise<T> {
    return new Promise((resolve, reject) => {
      const tx = db.transaction(stores, mode)
      let result: T
      const p = fn(tx).then(r => { result = r })
      tx.oncomplete = () => p.then(() => resolve(result))
      tx.onerror = () => reject(tx.error)
      tx.onabort = () => reject(tx.error)
    })
  }

  return {
    // ============================================================
    // Users — AgentStore.hs:341-397
    // ============================================================

    // createUserRecord (AgentStore.hs:341-344)
    // SQL: INSERT INTO users DEFAULT VALUES; SELECT last_insert_rowid()
    async createUserRecord() {
      return withTx("users", "readwrite", async (tx) => {
        const store = tx.objectStore("users")
        const id = await idbReq(store.add({deleted: 0}))
        return id as number
      })
    },

    // getUserIds (AgentStore.hs:346-348)
    // SQL: SELECT user_id FROM users WHERE deleted = 0
    async getUserIds() {
      return withTx("users", "readonly", async (tx) => {
        const all = await idbReq(tx.objectStore("users").getAll())
        return all.filter(u => u.deleted === 0).map(u => u.user_id)
      })
    },

    // deleteUserRecord (AgentStore.hs:355-358)
    // SQL: DELETE FROM users WHERE user_id = ?
    async deleteUserRecord(userId) {
      return withTx("users", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("users").delete(userId))
      })
    },

    // setUserDeleted (AgentStore.hs:360-365)
    // SQL: UPDATE users SET deleted = 1 WHERE user_id = ?
    // SQL: SELECT conn_id FROM connections WHERE user_id = ?
    async setUserDeleted(userId) {
      return withTx(["users", "connections"], "readwrite", async (tx) => {
        const store = tx.objectStore("users")
        const user = await idbReq(store.get(userId))
        if (user) {
          user.deleted = 1
          await idbReq(store.put(user))
        }
        const allConns = await idbReq(tx.objectStore("connections").getAll())
        return allConns.filter((c: any) => c.user_id === userId).map((c: any) => c.conn_id)
      })
    },

    // ============================================================
    // Servers — AgentStore.hs:233-240 (approximate, createServer is simple)
    // ============================================================

    // createServer
    // SQL: INSERT OR IGNORE INTO servers (host, port, key_hash) VALUES (?,?,?)
    async createServer(host, port, keyHash) {
      return withTx("servers", "readwrite", async (tx) => {
        const store = tx.objectStore("servers")
        const existing = await idbReq(store.get([host, port, keyHash]))
        if (!existing) await idbReq(store.add({host, port, key_hash: keyHash}))
      })
    },

    // ============================================================
    // Connections — AgentStore.hs:409-498
    // ============================================================

    // createNewConn (AgentStore.hs:409-411) → calls createConnRecord (AgentStore.hs:442-450)
    // SQL: INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, pq_support, duplex_handshake) VALUES (?,?,?,?,?,?,?)
    async createNewConn(connData, connMode) {
      return withTx("connections", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("connections").add({
          conn_id: connData.connId,
          user_id: connData.userId,
          conn_mode: connMode,
          smp_agent_version: connData.smpAgentVersion,
          enable_ntfs: connData.enableNtfs ? 1 : 0,
          pq_support: connData.pqSupport ? 1 : 0,
          duplex_handshake: 1,
          deleted: 0,
          ratchet_sync_state: "ok",
          last_internal_msg_id: 0,
          last_internal_rcv_msg_id: 0,
          last_internal_snd_msg_id: 0,
          last_external_snd_msg_id: 0,
          last_rcv_msg_hash: new Uint8Array(0),
          last_snd_msg_hash: new Uint8Array(0),
        }))
        return connData.connId
      })
    },

    // Placeholder for remaining methods — each will be transpiled from the actual SQL
    // TODO: transpile remaining ~70 methods from AgentStore.hs

    // getConn (AgentStore.hs:2248-2280)
    // SQL: SELECT ... FROM connections WHERE conn_id = ? AND deleted = 0
    // Then gets rcv_queues and snd_queues by conn_id
    async getConn(connId) {
      return withTx(["connections", "rcv_queues", "snd_queues", "servers"], "readonly", async (tx) => {
        // getConnData: SELECT user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, last_external_snd_msg_id, deleted, ratchet_sync_state, pq_support FROM connections WHERE conn_id = ? AND deleted = 0
        const conn = await idbReq(tx.objectStore("connections").get(connId))
        if (!conn || conn.deleted !== 0) return null
        // getRcvQueuesByConnId_: rcvQueueQuery WHERE q.conn_id = ? AND q.deleted = 0
        const rcvQueues = (await allByIndex(tx.objectStore("rcv_queues"), {conn_id: connId})).filter((q: any) => !q.deleted)
        // getSndQueuesByConnId_: sndQueueQuery WHERE q.conn_id = ?
        const sndQueues = await allByIndex(tx.objectStore("snd_queues"), {conn_id: connId})
        return {connData: conn, rcvQueues, sndQueues}
      })
    },

    // getRcvConn (AgentStore.hs:467-472)
    // SQL: rcvQueueQuery WHERE q.host = ? AND q.port = ? AND q.rcv_id = ? AND q.deleted = 0
    // Then getConn for the connId
    async getRcvConn(host, port, rcvId) {
      return withTx(["rcv_queues", "connections", "snd_queues", "servers"], "readonly", async (tx) => {
        const rq = await idbReq(tx.objectStore("rcv_queues").get([host, port, rcvId]))
        if (!rq || rq.deleted) return null
        const conn = await idbReq(tx.objectStore("connections").get(rq.conn_id))
        if (!conn || conn.deleted !== 0) return null
        return {connData: conn, rcvQueue: rq}
      })
    },

    // getConnSubs (AgentStore.hs:2295-2297) — gets ConnData for multiple connIds
    async getConnSubs(connIds) {
      return withTx("connections", "readonly", async (tx) => {
        const store = tx.objectStore("connections")
        const result = new Map()
        for (const cid of connIds) {
          const conn = await idbReq(store.get(cid))
          if (conn && conn.deleted === 0) result.set(toHex(cid), conn)
        }
        return result
      })
    },

    // getConnsData (AgentStore.hs:2371) — same as getConnSubs for our purposes
    async getConnsData(connIds) {
      return this.getConnSubs(connIds)
    },

    // lockConnForUpdate (AgentStore.hs:2394-2399)
    // Postgres: SELECT 1 FROM connections WHERE conn_id = ? FOR UPDATE
    // SQLite/IndexedDB: no-op (single-threaded)
    async lockConnForUpdate() { },

    // setConnDeleted (AgentStore.hs:2405-2411)
    // waitDelivery=true: UPDATE connections SET deleted_at_wait_delivery = ? WHERE conn_id = ?
    // waitDelivery=false: UPDATE connections SET deleted = 1 WHERE conn_id = ?
    async setConnDeleted(connId, waitDelivery) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) {
          if (waitDelivery) {
            conn.deleted_at_wait_delivery = new Date().toISOString()
          } else {
            conn.deleted = 1
          }
          await idbReq(store.put(conn))
        }
      })
    },

    // setConnUserId (AgentStore.hs:2413-2415)
    // SQL: UPDATE connections SET user_id = ? WHERE conn_id = ? AND user_id = ?
    async setConnUserId(oldUserId, connId, newUserId) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn && conn.user_id === oldUserId) {
          conn.user_id = newUserId
          await idbReq(store.put(conn))
        }
      })
    },

    // setConnAgentVersion (AgentStore.hs:2417-2419)
    // SQL: UPDATE connections SET smp_agent_version = ? WHERE conn_id = ?
    async setConnAgentVersion(connId, version) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) {
          conn.smp_agent_version = version
          await idbReq(store.put(conn))
        }
      })
    },

    // setConnPQSupport (AgentStore.hs:2421-2423)
    // SQL: UPDATE connections SET pq_support = ? WHERE conn_id = ?
    async setConnPQSupport(connId, pqSupport) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) {
          conn.pq_support = pqSupport ? 1 : 0
          await idbReq(store.put(conn))
        }
      })
    },

    // setConnRatchetSync (AgentStore.hs:2436)
    // SQL: UPDATE connections SET ratchet_sync_state = ? WHERE conn_id = ?
    async setConnRatchetSync(connId, state) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) {
          conn.ratchet_sync_state = state
          await idbReq(store.put(conn))
        }
      })
    },

    // updateNewConnJoin (AgentStore.hs:2425-2427)
    // SQL: UPDATE connections SET smp_agent_version = ?, pq_support = ?, enable_ntfs = ? WHERE conn_id = ?
    async updateNewConnJoin(connId, agentVersion, pqSupport, enableNtfs) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) {
          conn.smp_agent_version = agentVersion
          conn.pq_support = pqSupport ? 1 : 0
          conn.enable_ntfs = enableNtfs ? 1 : 0
          await idbReq(store.put(conn))
        }
      })
    },

    // updateNewConnRcv (AgentStore.hs:414-422)
    // Calls addConnRcvQueue_ which calls insertRcvQueue_
    async updateNewConnRcv(connId, rcvQueue, subMode) {
      return this.addConnRcvQueue(connId, rcvQueue, subMode)
    },

    // getDeletedConnIds (AgentStore.hs:2429-2430)
    // SQL: SELECT conn_id FROM connections WHERE deleted = 1
    async getDeletedConnIds() {
      return withTx("connections", "readonly", async (tx) => {
        const all = await idbReq(tx.objectStore("connections").getAll())
        return all.filter((c: any) => c.deleted === 1).map((c: any) => c.conn_id)
      })
    },

    // getDeletedWaitingDeliveryConnIds (AgentStore.hs:2432-2434)
    // SQL: SELECT conn_id FROM connections WHERE deleted_at_wait_delivery IS NOT NULL
    async getDeletedWaitingDeliveryConnIds() {
      return withTx("connections", "readonly", async (tx) => {
        const all = await idbReq(tx.objectStore("connections").getAll())
        return all.filter((c: any) => c.deleted_at_wait_delivery != null).map((c: any) => c.conn_id)
      })
    },

    // getConnIds (AgentStore.hs:2245-2246)
    // SQL: SELECT conn_id FROM connections WHERE deleted = 0
    async getConnIds() {
      return withTx("connections", "readonly", async (tx) => {
        const all = await idbReq(tx.objectStore("connections").getAll())
        return all.filter((c: any) => c.deleted === 0).map((c: any) => c.conn_id)
      })
    },

    // addConnRcvQueue (AgentStore.hs:516-526 → insertRcvQueue_ at 2077-2099)
    // SQL: INSERT INTO rcv_queues (host, port, rcv_id, conn_id, rcv_private_key, rcv_dh_secret, e2e_priv_key, e2e_dh_secret, snd_id, queue_mode, status, to_subscribe, rcv_queue_id, rcv_primary, ...) VALUES (...)
    async addConnRcvQueue(connId, rcvQueue, subMode) {
      return withTx(["rcv_queues", "servers"], "readwrite", async (tx) => {
        // createServer (INSERT OR IGNORE)
        const srvStore = tx.objectStore("servers")
        if (!(await idbReq(srvStore.get([rcvQueue.host, rcvQueue.port, rcvQueue.serverKeyHash])))) await idbReq(srvStore.add({host: rcvQueue.host, port: rcvQueue.port, key_hash: rcvQueue.serverKeyHash}))
        // Haskell: first check if queue with same (conn_id, host, port, snd_id) exists and reuse its rcv_queue_id
        // SELECT rcv_queue_id FROM rcv_queues WHERE conn_id = ? AND host = ? AND port = ? AND snd_id = ?
        const existing = await allByIndex(tx.objectStore("rcv_queues"), {conn_id: connId})
        const curr = existing.find((q: any) => q.host === rcvQueue.host && q.port === rcvQueue.port && eqBytes(q.snd_id, rcvQueue.sndId))
        const qId = curr ? curr.rcv_queue_id : (existing.reduce((m: number, q: any) => Math.max(m, q.rcv_queue_id || 0), 0) + 1)
        const toSubscribe = subMode === "SMOnlyCreate" ? 1 : 0
        await idbReq(tx.objectStore("rcv_queues").add({
          host: rcvQueue.host, port: rcvQueue.port, rcv_id: rcvQueue.rcvId,
          conn_id: connId, rcv_private_key: rcvQueue.rcvPrivateKey, rcv_dh_secret: rcvQueue.rcvDhSecret,
          e2e_priv_key: rcvQueue.e2ePrivKey, e2e_dh_secret: rcvQueue.e2eDhSecret,
          snd_id: rcvQueue.sndId, queue_mode: rcvQueue.queueMode, status: rcvQueue.status,
          to_subscribe: toSubscribe, rcv_queue_id: qId, rcv_primary: rcvQueue.primary ? 1 : 0,
          replace_rcv_queue_id: rcvQueue.replaceRcvQueueId, smp_client_version: rcvQueue.smpClientVersion,
          server_key_hash: rcvQueue.serverKeyHash, deleted: 0,
          snd_key: rcvQueue.sndKey, last_broker_ts: rcvQueue.lastBrokerTs,
        }))
        return {...rcvQueue, connId, dbQueueId: qId}
      })
    },

    // addConnSndQueue (AgentStore.hs:528-538 → insertSndQueue_ at 2109-2140)
    // SQL: INSERT INTO snd_queues (host, port, snd_id, queue_mode, conn_id, snd_private_key, e2e_pub_key, e2e_dh_secret, status, snd_queue_id, snd_primary, ...) VALUES (...) ON CONFLICT DO UPDATE
    async addConnSndQueue(connId, sndQueue) {
      return withTx(["snd_queues", "servers"], "readwrite", async (tx) => {
        const srvStore2 = tx.objectStore("servers")
        if (!(await idbReq(srvStore2.get([sndQueue.host, sndQueue.port, sndQueue.serverKeyHash])))) await idbReq(srvStore2.add({host: sndQueue.host, port: sndQueue.port, key_hash: sndQueue.serverKeyHash}))
        // Haskell: first check if queue with same (conn_id, host, port, snd_id) exists and reuse its snd_queue_id
        // SELECT snd_queue_id FROM snd_queues WHERE conn_id = ? AND host = ? AND port = ? AND snd_id = ?
        const existing = await allByIndex(tx.objectStore("snd_queues"), {conn_id: connId})
        const curr = existing.find((q: any) => q.host === sndQueue.host && q.port === sndQueue.port && eqBytes(q.snd_id, sndQueue.sndId))
        const qId = curr ? curr.snd_queue_id : (existing.reduce((m: number, q: any) => Math.max(m, q.snd_queue_id || 0), 0) + 1)
        // ON CONFLICT DO UPDATE → use put (upsert)
        await idbReq(tx.objectStore("snd_queues").put({
          host: sndQueue.host, port: sndQueue.port, snd_id: sndQueue.sndId,
          queue_mode: sndQueue.queueMode, conn_id: connId,
          snd_private_key: sndQueue.sndPrivateKey, e2e_pub_key: sndQueue.e2ePubKey,
          e2e_dh_secret: sndQueue.e2eDhSecret, status: sndQueue.status,
          snd_queue_id: qId, snd_primary: sndQueue.primary ? 1 : 0,
          replace_snd_queue_id: null, smp_client_version: sndQueue.smpClientVersion,
          server_key_hash: sndQueue.serverKeyHash, snd_public_key: sndQueue.sndPublicKey,
        }))
      })
    },

    // setRcvQueueStatus (AgentStore.hs:540-550)
    // SQL: UPDATE rcv_queues SET status = ? WHERE host = ? AND port = ? AND rcv_id = ?
    async setRcvQueueStatus(rcvQueue, status) {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_queues")
        const rq = await idbReq(store.get([rcvQueue.host, rcvQueue.port, rcvQueue.rcvId]))
        if (rq) { rq.status = status; await idbReq(store.put(rq)) }
      })
    },

    // setSndQueueStatus (AgentStore.hs:588-598)
    // SQL: UPDATE snd_queues SET status = ? WHERE host = ? AND port = ? AND snd_id = ?
    async setSndQueueStatus(sndQueue, status) {
      return withTx("snd_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("snd_queues")
        const sq = await idbReq(store.get([sndQueue.host, sndQueue.port, sndQueue.sndId]))
        if (sq) { sq.status = status; await idbReq(store.put(sq)) }
      })
    },

    // setRcvQueueConfirmedE2E (AgentStore.hs:575-586)
    // SQL: UPDATE rcv_queues SET e2e_dh_secret = ?, status = 'confirmed', smp_client_version = ? WHERE host = ? AND port = ? AND rcv_id = ?
    async setRcvQueueConfirmedE2E(rcvQueue, dhSecret, smpClientVersion) {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_queues")
        const rq = await idbReq(store.get([rcvQueue.host, rcvQueue.port, rcvQueue.rcvId]))
        if (rq) { rq.e2e_dh_secret = dhSecret; rq.status = "confirmed"; rq.smp_client_version = smpClientVersion; await idbReq(store.put(rq)) }
      })
    },

    // setRcvQueuePrimary (AgentStore.hs:612-618)
    // SQL1: UPDATE rcv_queues SET rcv_primary = 0 WHERE conn_id = ?
    // SQL2: UPDATE rcv_queues SET rcv_primary = 1, replace_rcv_queue_id = NULL WHERE conn_id = ? AND rcv_queue_id = ?
    async setRcvQueuePrimary(connId, rcvQueue) {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_queues")
        const all = await allByIndex(store, {conn_id: connId})
        for (const rq of all) {
          if (rq.rcv_queue_id === rcvQueue.dbQueueId) {
            rq.rcv_primary = 1; rq.replace_rcv_queue_id = null
          } else {
            rq.rcv_primary = 0
          }
          await idbReq(store.put(rq))
        }
      })
    },

    // deleteConnRcvQueue (AgentStore.hs:632-634)
    // SQL: DELETE FROM rcv_queues WHERE conn_id = ? AND rcv_queue_id = ?
    async deleteConnRcvQueue(rcvQueue) {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("rcv_queues").delete([rcvQueue.host, rcvQueue.port, rcvQueue.rcvId]))
      })
    },

    // deleteConnRecord (AgentStore.hs:452-453)
    // SQL: DELETE FROM connections WHERE conn_id = ?
    async deleteConnRecord(connId) {
      return withTx("connections", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("connections").delete(connId))
      })
    },

    // upgradeRcvConnToDuplex (AgentStore.hs:501-505)
    // Adds snd queue to an existing rcv connection
    async upgradeRcvConnToDuplex(connId, sndQueue) {
      return this.addConnSndQueue(connId, sndQueue)
    },

    // upgradeSndConnToDuplex (AgentStore.hs:508-513)
    // Adds rcv queue to an existing snd connection
    async upgradeSndConnToDuplex(connId, rcvQueue, subMode) {
      return this.addConnRcvQueue(connId, rcvQueue, subMode)
    },

    // getPrimaryRcvQueue (AgentStore.hs:641-643)
    // Gets rcv queues by connId, returns first (primary, sorted)
    async getPrimaryRcvQueue(connId) {
      return withTx("rcv_queues", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("rcv_queues"), {conn_id: connId})
        const active = all.filter((q: any) => !q.deleted)
        // Sort by primary first (primary=1 first)
        active.sort((a: any, b: any) => (b.rcv_primary || 0) - (a.rcv_primary || 0))
        return active[0] ?? null
      })
    },

    // getRcvQueue (AgentStore.hs:645-648)
    // SQL: rcvQueueQuery WHERE q.conn_id = ? AND q.host = ? AND q.port = ? AND q.rcv_id = ? AND q.deleted = 0
    async getRcvQueue(connId, host, port, rcvId) {
      return withTx("rcv_queues", "readonly", async (tx) => {
        const rq = await idbReq(tx.objectStore("rcv_queues").get([host, port, rcvId]))
        if (!rq || rq.deleted || toHex(rq.conn_id) !== toHex(connId)) return null
        return rq
      })
    },

    // getDeletedRcvQueue (AgentStore.hs:650-653)
    // SQL: same but q.deleted = 1
    async getDeletedRcvQueue(connId, host, port, rcvId) {
      return withTx("rcv_queues", "readonly", async (tx) => {
        const rq = await idbReq(tx.objectStore("rcv_queues").get([host, port, rcvId]))
        if (!rq || !rq.deleted || toHex(rq.conn_id) !== toHex(connId)) return null
        return rq
      })
    },

    // setConnectionNtfs — UPDATE connections SET enable_ntfs = ? WHERE conn_id = ?
    async setConnectionNtfs(connId, enable) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn) { conn.enable_ntfs = enable ? 1 : 0; await idbReq(store.put(conn)) }
      })
    },

    // ============================================================
    // Subscriptions — AgentStore.hs:2211-2242, 943-954
    // ============================================================

    // getSubscriptionServers (AgentStore.hs:2211-2226)
    // SQL: SELECT DISTINCT c.user_id, q.host, q.port, COALESCE(q.server_key_hash, s.key_hash)
    //      FROM rcv_queues q
    //      JOIN servers s ON q.host = s.host AND q.port = s.port
    //      JOIN connections c ON q.conn_id = c.conn_id
    //      WHERE [q.to_subscribe = 1 AND] c.deleted = 0 AND q.deleted = 0
    async getSubscriptionServers(onlyNeeded) {
      return withTx(["rcv_queues", "connections"], "readonly", async (tx) => {
        const allQ = await idbReq(tx.objectStore("rcv_queues").getAll())
        const connStore = tx.objectStore("connections")
        const seen = new Set<string>()
        const result: Array<{userId: number, host: string, port: string, keyHash: Uint8Array}> = []
        for (const q of allQ) {
          if (q.deleted) continue
          if (onlyNeeded && !q.to_subscribe) continue
          if (!q.server_key_hash) continue
          const conn = await idbReq(connStore.get(q.conn_id))
          if (!conn || conn.deleted !== 0) continue
          const key = `${conn.user_id}:${q.host}:${q.port}:${toHex(q.server_key_hash)}`
          if (!seen.has(key)) {
            seen.add(key)
            result.push({userId: conn.user_id, host: q.host, port: q.port, keyHash: q.server_key_hash})
          }
        }
        return result
      })
    },

    // getUserServerRcvQueueSubs (AgentStore.hs:2228-2238)
    // SQL: rcvQueueSubQuery WHERE [q.to_subscribe = 1 AND] c.deleted = 0 AND q.deleted = 0
    //      AND c.user_id = ? AND q.host = ? AND q.port = ? AND COALESCE(q.server_key_hash, s.key_hash) = ?
    //      ORDER BY q.rcv_id LIMIT ?
    async getUserServerRcvQueueSubs(userId, host, port, keyHash, onlyNeeded, batchSize, cursor) {
      return withTx(["rcv_queues", "connections"], "readonly", async (tx) => {
        const allQ = await idbReq(tx.objectStore("rcv_queues").getAll())
        const connStore = tx.objectStore("connections")
        // Filter matching queues
        const matching: any[] = []
        for (const q of allQ) {
          if (q.deleted) continue
          if (q.host !== host || q.port !== port) continue
          if (!q.server_key_hash || !eqBytes(q.server_key_hash, keyHash)) continue
          if (onlyNeeded && !q.to_subscribe) continue
          if (cursor !== null && compareUint8Array(q.rcv_id, cursor as any) <= 0) continue
          const conn = await idbReq(connStore.get(q.conn_id))
          if (!conn || conn.deleted !== 0 || conn.user_id !== userId) continue
          matching.push(q)
        }
        // ORDER BY q.rcv_id
        matching.sort((a, b) => compareUint8Array(a.rcv_id, b.rcv_id))
        // LIMIT
        const queues = matching.slice(0, batchSize)
        const nextCursor = queues.length === batchSize ? queues[queues.length - 1].rcv_id : null
        return {queues, nextCursor}
      })
    },

    // unsetQueuesToSubscribe (AgentStore.hs:2240-2241)
    // SQL: UPDATE rcv_queues SET to_subscribe = 0 WHERE to_subscribe = 1
    async unsetQueuesToSubscribe() {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_queues")
        const all = await idbReq(store.getAll())
        for (const q of all) {
          if (q.to_subscribe === 1) {
            q.to_subscribe = 0
            await idbReq(store.put(q))
          }
        }
      })
    },

    // getConnectionsForDelivery (AgentStore.hs:943-945)
    // SQL: SELECT DISTINCT conn_id FROM snd_message_deliveries WHERE failed = 0
    async getConnectionsForDelivery() {
      return withTx("snd_message_deliveries", "readonly", async (tx) => {
        const all = await idbReq(tx.objectStore("snd_message_deliveries").getAll())
        const seen = new Set<string>()
        const result: Uint8Array[] = []
        for (const d of all) {
          if (d.failed) continue
          const hex = toHex(d.conn_id)
          if (!seen.has(hex)) {
            seen.add(hex)
            result.push(d.conn_id)
          }
        }
        return result
      })
    },

    // getAllSndQueuesForDelivery (AgentStore.hs:947-954)
    // SQL: sndQueueQuery
    //      JOIN (SELECT DISTINCT conn_id, snd_queue_id FROM snd_message_deliveries WHERE failed = 0) d
    //      ON d.conn_id = q.conn_id AND d.snd_queue_id = q.snd_queue_id
    //      WHERE c.deleted = 0
    async getAllSndQueuesForDelivery() {
      return withTx(["snd_message_deliveries", "snd_queues", "connections"], "readonly", async (tx) => {
        // Get distinct (conn_id, snd_queue_id) from non-failed deliveries
        const allDel = await idbReq(tx.objectStore("snd_message_deliveries").getAll())
        const deliveryKeys = new Set<string>()
        for (const d of allDel) {
          if (!d.failed) deliveryKeys.add(toHex(d.conn_id) + ":" + d.snd_queue_id)
        }
        // Get snd_queues that match
        const allSQ = await idbReq(tx.objectStore("snd_queues").getAll())
        const connStore = tx.objectStore("connections")
        const result: any[] = []
        for (const sq of allSQ) {
          const key = toHex(sq.conn_id) + ":" + sq.snd_queue_id
          if (!deliveryKeys.has(key)) continue
          const conn = await idbReq(connStore.get(sq.conn_id))
          if (!conn || conn.deleted !== 0) continue
          result.push(sq)
        }
        return result
      })
    },

    // ============================================================
    // Confirmations — AgentStore.hs:682-752
    // ============================================================

    // createConfirmation (AgentStore.hs:682-691)
    // SQL: INSERT INTO conn_confirmations
    //      (confirmation_id, conn_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info, smp_reply_queues, smp_client_version, accepted)
    //      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    async createConfirmation(confirmation) {
      return withTx("conn_confirmations", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("conn_confirmations").add({
          confirmation_id: confirmation.confirmationId,
          conn_id: confirmation.connId,
          sender_key: confirmation.senderKey,
          e2e_snd_pub_key: confirmation.e2eSndPubKey,
          ratchet_state: confirmation.ratchetState,
          sender_conn_info: confirmation.senderConnInfo,
          smp_reply_queues: confirmation.smpReplyQueues,
          smp_client_version: confirmation.smpClientVersion,
          accepted: 0,
          own_conn_info: null,
        }))
        return confirmation.confirmationId
      })
    },

    // acceptConfirmation (AgentStore.hs:693-721)
    // SQL1: UPDATE conn_confirmations SET accepted = 1, own_conn_info = ? WHERE confirmation_id = ?
    // SQL2: SELECT conn_id, ratchet_state, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
    //       FROM conn_confirmations WHERE confirmation_id = ?
    async acceptConfirmation(confirmationId, ownConnInfo) {
      return withTx("conn_confirmations", "readwrite", async (tx) => {
        const store = tx.objectStore("conn_confirmations")
        const conf = await idbReq(store.get(confirmationId))
        if (!conf) throw new Error("confirmation not found")
        conf.accepted = 1
        conf.own_conn_info = ownConnInfo
        await idbReq(store.put(conf))
        return conf
      })
    },

    // getAcceptedConfirmation (AgentStore.hs:723-742)
    // SQL: SELECT confirmation_id, ratchet_state, own_conn_info, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
    //      FROM conn_confirmations WHERE conn_id = ? AND accepted = 1
    async getAcceptedConfirmation(connId) {
      return withTx("conn_confirmations", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("conn_confirmations"), {conn_id: connId})
        const accepted = all.find((c: any) => c.accepted === 1)
        return accepted ?? null
      })
    },

    // removeConfirmations (AgentStore.hs:744-752)
    // SQL: DELETE FROM conn_confirmations WHERE conn_id = ?
    async removeConfirmations(connId) {
      return withTx("conn_confirmations", "readwrite", async (tx) => {
        const store = tx.objectStore("conn_confirmations")
        const allConf = await allByIndex(store, {conn_id: connId})
        const all = allConf.map((c: any) => c.confirmation_id)
        for (const key of all) {
          await idbReq(store.delete(key))
        }
      })
    },

    // ============================================================
    // Invitations — AgentStore.hs:754-799
    // ============================================================

    // createInvitation (AgentStore.hs:754-763)
    // SQL: INSERT INTO conn_invitations
    //      (invitation_id, contact_conn_id, cr_invitation, recipient_conn_info, accepted)
    //      VALUES (?, ?, ?, ?, 0)
    async createInvitation(invitation) {
      return withTx("conn_invitations", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("conn_invitations").add({
          invitation_id: invitation.invitationId,
          contact_conn_id: invitation.contactConnId,
          cr_invitation: invitation.crInvitation,
          recipient_conn_info: invitation.recipientConnInfo,
          accepted: 0,
          own_conn_info: null,
        }))
        return invitation.invitationId
      })
    },

    // getInvitation (AgentStore.hs:765-779)
    // SQL: SELECT contact_conn_id, cr_invitation, recipient_conn_info, own_conn_info, accepted
    //      FROM conn_invitations WHERE invitation_id = ? AND accepted = 0
    async getInvitation(invitationId) {
      return withTx("conn_invitations", "readonly", async (tx) => {
        const inv = await idbReq(tx.objectStore("conn_invitations").get(invitationId))
        if (!inv || inv.accepted !== 0) return null
        return inv
      })
    },

    // acceptInvitation (AgentStore.hs:781-791)
    // SQL: UPDATE conn_invitations SET accepted = 1, own_conn_info = ? WHERE invitation_id = ?
    async acceptInvitation(invitationId, ownConnInfo) {
      return withTx("conn_invitations", "readwrite", async (tx) => {
        const store = tx.objectStore("conn_invitations")
        const inv = await idbReq(store.get(invitationId))
        if (inv) {
          inv.accepted = 1
          inv.own_conn_info = ownConnInfo
          await idbReq(store.put(inv))
        }
      })
    },

    // unacceptInvitation (AgentStore.hs:793-795)
    // SQL: UPDATE conn_invitations SET accepted = 0, own_conn_info = NULL WHERE invitation_id = ?
    async unacceptInvitation(invitationId) {
      return withTx("conn_invitations", "readwrite", async (tx) => {
        const store = tx.objectStore("conn_invitations")
        const inv = await idbReq(store.get(invitationId))
        if (inv) {
          inv.accepted = 0
          inv.own_conn_info = null
          await idbReq(store.put(inv))
        }
      })
    },

    // deleteInvitation (AgentStore.hs:797-799)
    // SQL: DELETE FROM conn_invitations WHERE invitation_id = ?
    async deleteInvitation(invitationId) {
      return withTx("conn_invitations", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("conn_invitations").delete(invitationId))
      })
    },

    // ============================================================
    // Messages — AgentStore.hs:873-1205
    // ============================================================

    // updateRcvIds (AgentStore.hs:873-879)
    // Calls retrieveLastIdsAndHashRcv_ (AgentStore.hs:2584-2599):
    //   SQL: SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash FROM connections WHERE conn_id = ?
    // Then updateLastIdsRcv_ (AgentStore.hs:2601-2611):
    //   SQL: UPDATE connections SET last_internal_msg_id = ?, last_internal_rcv_msg_id = ? WHERE conn_id = ?
    async updateRcvIds(connId) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (!conn) throw new Error("connection not found")
        const internalId = conn.last_internal_msg_id + 1
        const internalRcvId = conn.last_internal_rcv_msg_id + 1
        const prevExternalSndId = conn.last_external_snd_msg_id
        const prevRcvMsgHash = conn.last_rcv_msg_hash
        conn.last_internal_msg_id = internalId
        conn.last_internal_rcv_msg_id = internalRcvId
        await idbReq(store.put(conn))
        return {internalId, internalRcvId, prevExternalSndId, prevRcvMsgHash}
      })
    },

    // createRcvMsg (AgentStore.hs:881-886)
    // Calls insertRcvMsgBase_ (AgentStore.hs:2615-2625):
    //   SQL: INSERT INTO messages (conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body, pq_encryption) VALUES (?,?,?,?,?,?,?,?,?)
    // Calls insertRcvMsgDetails_ (AgentStore.hs:2627-2641):
    //   SQL: INSERT INTO rcv_messages (conn_id, rcv_queue_id, internal_rcv_id, internal_id, external_snd_id, broker_id, broker_ts, internal_hash, external_prev_snd_hash, integrity) VALUES (?,?,?,?,?,?,?,?,?,?)
    //   SQL: INSERT INTO encrypted_rcv_message_hashes (conn_id, hash) VALUES (?,?)
    // Calls updateRcvMsgHash (AgentStore.hs:2643-2655):
    //   SQL: UPDATE connections SET last_external_snd_msg_id = ?, last_rcv_msg_hash = ? WHERE conn_id = ? AND last_internal_rcv_msg_id = ?
    // Calls setLastBrokerTs (AgentStore.hs:888-890):
    //   SQL: UPDATE rcv_queues SET last_broker_ts = ? WHERE conn_id = ? AND rcv_queue_id = ? AND (last_broker_ts IS NULL OR last_broker_ts < ?)
    async createRcvMsg(connId, rcvQueue, rcvMsgData) {
      return withTx(["messages", "rcv_messages", "encrypted_rcv_message_hashes", "connections", "rcv_queues"], "readwrite", async (tx) => {
        const {msgMeta, msgType, msgFlags, msgBody, internalRcvId, internalHash, externalPrevSndHash, encryptedMsgHash} = rcvMsgData
        const {recipient, broker, sndMsgId, integrity, pqEncryption} = msgMeta
        const [internalId, internalTs] = recipient
        const [brokerId, brokerTs] = broker

        // insertRcvMsgBase_: INSERT INTO messages
        await idbReq(tx.objectStore("messages").add({
          conn_id: connId, internal_id: internalId, internal_ts: internalTs,
          internal_rcv_id: internalRcvId, internal_snd_id: null,
          msg_type: msgType, msg_flags: msgFlags, msg_body: msgBody, pq_encryption: pqEncryption,
        }))

        // insertRcvMsgDetails_: INSERT INTO rcv_messages
        await idbReq(tx.objectStore("rcv_messages").add({
          conn_id: connId, rcv_queue_id: rcvQueue.dbQueueId, internal_rcv_id: internalRcvId,
          internal_id: internalId, external_snd_id: sndMsgId,
          broker_id: brokerId, broker_ts: brokerTs,
          internal_hash: internalHash, external_prev_snd_hash: externalPrevSndHash,
          integrity, user_ack: 0, receive_attempts: 0,
        }))

        // insertRcvMsgDetails_: INSERT INTO encrypted_rcv_message_hashes
        await idbReq(tx.objectStore("encrypted_rcv_message_hashes").add({
          conn_id: connId, hash: encryptedMsgHash, created_at: new Date().toISOString(),
        }))

        // updateRcvMsgHash: UPDATE connections SET last_external_snd_msg_id, last_rcv_msg_hash
        const connStore = tx.objectStore("connections")
        const conn = await idbReq(connStore.get(connId))
        if (conn && conn.last_internal_rcv_msg_id === internalRcvId) {
          conn.last_external_snd_msg_id = sndMsgId
          conn.last_rcv_msg_hash = internalHash
          await idbReq(connStore.put(conn))
        }

        // setLastBrokerTs: UPDATE rcv_queues SET last_broker_ts
        const rcvQStore = tx.objectStore("rcv_queues")
        const allRQ = await allByIndex(rcvQStore, {conn_id: connId})
        for (const rq of allRQ) {
          if (rq.rcv_queue_id === rcvQueue.dbQueueId) {
            if (rq.last_broker_ts == null || rq.last_broker_ts < brokerTs) {
              rq.last_broker_ts = brokerTs
              await idbReq(rcvQStore.put(rq))
            }
            break
          }
        }
      })
    },

    // setLastBrokerTs (AgentStore.hs:888-890)
    // SQL: UPDATE rcv_queues SET last_broker_ts = ? WHERE conn_id = ? AND rcv_queue_id = ? AND (last_broker_ts IS NULL OR last_broker_ts < ?)
    async setLastBrokerTs(connId, dbQueueId, brokerTs) {
      return withTx("rcv_queues", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_queues")
        const all = await allByIndex(store, {conn_id: connId})
        for (const rq of all) {
          if (rq.rcv_queue_id === dbQueueId) {
            if (rq.last_broker_ts == null || rq.last_broker_ts < brokerTs) {
              rq.last_broker_ts = brokerTs
              await idbReq(store.put(rq))
            }
            break
          }
        }
      })
    },

    // updateRcvMsgHash (AgentStore.hs:2643-2655)
    // SQL: UPDATE connections SET last_external_snd_msg_id = ?, last_rcv_msg_hash = ?
    //      WHERE conn_id = ? AND last_internal_rcv_msg_id = ?
    async updateRcvMsgHash(connId, sndMsgId, internalRcvId, hash) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn && conn.last_internal_rcv_msg_id === internalRcvId) {
          conn.last_external_snd_msg_id = sndMsgId
          conn.last_rcv_msg_hash = hash
          await idbReq(store.put(conn))
        }
      })
    },

    // createSndMsgBody (AgentStore.hs:892-898)
    // SQL: INSERT INTO snd_message_bodies (agent_msg) VALUES (?) RETURNING snd_message_body_id
    async createSndMsgBody(agentMsg) {
      return withTx("snd_message_bodies", "readwrite", async (tx) => {
        return await idbReq(tx.objectStore("snd_message_bodies").add({agent_msg: agentMsg})) as number
      })
    },

    // updateSndIds (AgentStore.hs:900-906)
    // Calls retrieveLastIdsAndHashSnd_ (AgentStore.hs:2659-2673):
    //   SQL: SELECT last_internal_msg_id, last_internal_snd_msg_id, last_snd_msg_hash FROM connections WHERE conn_id = ?
    // Then updateLastIdsSnd_ (AgentStore.hs:2675-2685):
    //   SQL: UPDATE connections SET last_internal_msg_id = ?, last_internal_snd_msg_id = ? WHERE conn_id = ?
    async updateSndIds(connId) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (!conn) throw new Error("connection not found")
        const internalId = conn.last_internal_msg_id + 1
        const internalSndId = conn.last_internal_snd_msg_id + 1
        const prevSndMsgHash = conn.last_snd_msg_hash
        conn.last_internal_msg_id = internalId
        conn.last_internal_snd_msg_id = internalSndId
        await idbReq(store.put(conn))
        return {internalId, internalSndId, prevSndMsgHash}
      })
    },

    // createSndMsg (AgentStore.hs:908-912)
    // Calls insertSndMsgBase_ (AgentStore.hs:2689-2699):
    //   SQL: INSERT INTO messages (conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body, pq_encryption) VALUES (?,?,?,?,?,?,?,?,?)
    // Calls insertSndMsgDetails_ (AgentStore.hs:2701-2715):
    //   SQL: INSERT INTO snd_messages (conn_id, internal_snd_id, internal_id, internal_hash, previous_msg_hash, msg_encrypt_key, padded_msg_len, snd_message_body_id) VALUES (?,?,?,?,?,?,?,?)
    // Calls updateSndMsgHash (AgentStore.hs:2717-2728):
    //   SQL: UPDATE connections SET last_snd_msg_hash = ? WHERE conn_id = ? AND last_internal_snd_msg_id = ?
    async createSndMsg(connId, sndMsgData) {
      return withTx(["messages", "snd_messages", "connections"], "readwrite", async (tx) => {
        const {internalId, internalSndId, internalTs, msgType, msgFlags, msgBody, pqEncryption,
               internalHash, prevMsgHash, msgEncryptKey, paddedMsgLen, sndMessageBodyId} = sndMsgData

        // insertSndMsgBase_: INSERT INTO messages
        await idbReq(tx.objectStore("messages").add({
          conn_id: connId, internal_id: internalId, internal_ts: internalTs,
          internal_rcv_id: null, internal_snd_id: internalSndId,
          msg_type: msgType, msg_flags: msgFlags, msg_body: msgBody, pq_encryption: pqEncryption,
        }))

        // insertSndMsgDetails_: INSERT INTO snd_messages
        await idbReq(tx.objectStore("snd_messages").add({
          conn_id: connId, internal_snd_id: internalSndId, internal_id: internalId,
          internal_hash: internalHash, previous_msg_hash: prevMsgHash,
          msg_encrypt_key: msgEncryptKey, padded_msg_len: paddedMsgLen,
          snd_message_body_id: sndMessageBodyId,
          retry_int_slow: null, retry_int_fast: null,
          rcpt_internal_id: null, rcpt_status: null,
        }))

        // updateSndMsgHash: UPDATE connections SET last_snd_msg_hash
        const connStore = tx.objectStore("connections")
        const conn = await idbReq(connStore.get(connId))
        if (conn && conn.last_internal_snd_msg_id === internalSndId) {
          conn.last_snd_msg_hash = internalHash
          await idbReq(connStore.put(conn))
        }
      })
    },

    // updateSndMsgHash (AgentStore.hs:2717-2728)
    // SQL: UPDATE connections SET last_snd_msg_hash = ? WHERE conn_id = ? AND last_internal_snd_msg_id = ?
    async updateSndMsgHash(connId, internalSndId, hash) {
      return withTx("connections", "readwrite", async (tx) => {
        const store = tx.objectStore("connections")
        const conn = await idbReq(store.get(connId))
        if (conn && conn.last_internal_snd_msg_id === internalSndId) {
          conn.last_snd_msg_hash = hash
          await idbReq(store.put(conn))
        }
      })
    },

    // createSndMsgDelivery (AgentStore.hs:914-916)
    // SQL: INSERT INTO snd_message_deliveries (conn_id, snd_queue_id, internal_id) VALUES (?, ?, ?)
    async createSndMsgDelivery(connId, sndQueue, internalId) {
      return withTx("snd_message_deliveries", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("snd_message_deliveries").add({
          conn_id: connId, snd_queue_id: sndQueue.dbQueueId, internal_id: internalId, failed: 0,
        }))
      })
    },

    // getPendingQueueMsg (AgentStore.hs:956-1002)
    // getMsgId SQL: SELECT internal_id FROM snd_message_deliveries d
    //              WHERE conn_id = ? AND snd_queue_id = ? AND failed = 0
    //              ORDER BY internal_id ASC LIMIT 1
    // getMsgData SQL: SELECT m.msg_type, m.msg_flags, m.msg_body, m.pq_encryption, m.internal_ts, m.internal_snd_id, s.previous_msg_hash,
    //                        s.retry_int_slow, s.retry_int_fast, s.msg_encrypt_key, s.padded_msg_len, sb.agent_msg
    //                 FROM messages m
    //                 JOIN snd_messages s ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
    //                 LEFT JOIN snd_message_bodies sb ON sb.snd_message_body_id = s.snd_message_body_id
    //                 WHERE m.conn_id = ? AND m.internal_id = ?
    async getPendingQueueMsg(connId, sndQueue) {
      return withTx(["snd_message_deliveries", "messages", "snd_messages", "snd_message_bodies"], "readonly", async (tx) => {
        // getMsgId: find first non-failed delivery for this queue
        const allDel = await allByIndex(tx.objectStore("snd_message_deliveries"), {conn_id: connId, snd_queue_id: sndQueue.dbQueueId})
        const pending = allDel.filter((d: any) => !d.failed).sort((a: any, b: any) => a.internal_id - b.internal_id)
        if (pending.length === 0) return null
        const msgId = pending[0].internal_id

        // getMsgData: JOIN messages + snd_messages + snd_message_bodies
        const msg = await idbReq(tx.objectStore("messages").get([connId, msgId]))
        if (!msg) return null
        // Find snd_message by [conn_id, internal_id] via index
        const sndMsgs = await allByIndex(tx.objectStore("snd_messages"), {conn_id: connId, internal_id: msgId})
        if (sndMsgs.length === 0) return null
        const sm = sndMsgs[0]
        // LEFT JOIN snd_message_bodies
        let sndMsgBody: Uint8Array | null = null
        if (sm.snd_message_body_id != null) {
          const body = await idbReq(tx.objectStore("snd_message_bodies").get(sm.snd_message_body_id))
          if (body) sndMsgBody = body.agent_msg
        }

        return {
          connId, sndQueueId: sndQueue.dbQueueId, internalId: msgId,
          msgType: msg.msg_type, msgFlags: msg.msg_flags, msgBody: msg.msg_body,
          internalHash: sm.internal_hash, prevMsgHash: sm.previous_msg_hash,
          pqEncryption: msg.pq_encryption,
          msgEncryptKey: sm.msg_encrypt_key, paddedMsgLen: sm.padded_msg_len,
          sndMessageBodyId: sm.snd_message_body_id,
        }
      })
    },

    // updatePendingMsgRIState (AgentStore.hs:1024-1026)
    // SQL: UPDATE snd_messages SET retry_int_slow = ?, retry_int_fast = ? WHERE conn_id = ? AND internal_id = ?
    async updatePendingMsgRIState(connId, msgId, retryIntSlow, retryIntFast) {
      return withTx("snd_messages", "readwrite", async (tx) => {
        const store = tx.objectStore("snd_messages")
        const all = await allByIndex(store, {conn_id: connId, internal_id: msgId})
        if (all.length > 0) {
          const sm = all[0]
          sm.retry_int_slow = retryIntSlow
          sm.retry_int_fast = retryIntFast
          await idbReq(store.put(sm))
        }
      })
    },

    // setMsgUserAck (AgentStore.hs:1059-1073)
    // SQL1: SELECT rcv_queue_id, broker_id FROM rcv_messages WHERE conn_id = ? AND internal_id = ?
    // SQL2: UPDATE rcv_messages SET user_ack = 1 WHERE conn_id = ? AND internal_id = ?
    // Then getRcvQueueById to return the rcv queue
    async setMsgUserAck(connId, internalId) {
      return withTx(["rcv_messages", "rcv_queues"], "readwrite", async (tx) => {
        const rmStore = tx.objectStore("rcv_messages")
        // Find rcv_message by conn_id + internal_id via index
        const all = await allByIndex(rmStore, {conn_id: connId, internal_id: internalId})
        if (all.length === 0) throw new Error("rcv message not found")
        const rm = all[0]
        const dbRcvId = rm.rcv_queue_id
        const brokerId = rm.broker_id
        // Update user_ack
        rm.user_ack = 1
        await idbReq(rmStore.put(rm))
        // getRcvQueueById: find rcv_queue by conn_id + rcv_queue_id
        const rqStore = tx.objectStore("rcv_queues")
        const rqs = await allByIndex(rqStore, {conn_id: connId, rcv_queue_id: dbRcvId})
        if (rqs.length === 0) throw new Error("rcv queue not found")
        return {rcvQueue: rqs[0], brokerId}
      })
    },

    // getRcvMsg (AgentStore.hs:1075-1089)
    // SQL: SELECT r.internal_id, m.internal_ts, r.broker_id, r.broker_ts, r.external_snd_id, r.integrity, r.internal_hash,
    //             m.msg_type, m.msg_body, m.pq_encryption, s.internal_id, s.rcpt_status, r.user_ack
    //      FROM rcv_messages r
    //      JOIN messages m ON r.conn_id = m.conn_id AND r.internal_id = m.internal_id
    //      LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
    //      WHERE r.conn_id = ? AND r.internal_id = ?
    async getRcvMsg(connId, internalId) {
      return withTx(["rcv_messages", "messages", "snd_messages"], "readonly", async (tx) => {
        // Find rcv_message
        const rmAll = await allByIndex(tx.objectStore("rcv_messages"), {conn_id: connId, internal_id: internalId})
        if (rmAll.length === 0) return null
        const rm = rmAll[0]
        // JOIN messages
        const msg = await idbReq(tx.objectStore("messages").get([connId, internalId]))
        if (!msg) return null
        // LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
        const sndAll = await allByIndex(tx.objectStore("snd_messages"), {conn_id: connId})
        const sndRcpt = sndAll.find((s: any) => s.rcpt_internal_id === internalId)
        return {
          internalId: rm.internal_id,
          msgMeta: {
            integrity: rm.integrity,
            recipient: [rm.internal_id, msg.internal_ts],
            broker: [rm.broker_id, rm.broker_ts],
            sndMsgId: rm.external_snd_id,
            pqEncryption: msg.pq_encryption,
          },
          msgType: msg.msg_type,
          msgBody: msg.msg_body,
          userAck: rm.user_ack === 1,
          msgReceipt: sndRcpt?.rcpt_status ?? null,
        }
      })
    },

    // getLastMsg (AgentStore.hs:1091-1106)
    // SQL: SELECT ... FROM rcv_messages r
    //      JOIN messages m ON r.conn_id = m.conn_id AND r.internal_id = m.internal_id
    //      JOIN connections c ON r.conn_id = c.conn_id AND c.last_internal_msg_id = r.internal_id
    //      LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
    //      WHERE r.conn_id = ? AND r.broker_id = ?
    async getLastMsg(connId, brokerId) {
      return withTx(["rcv_messages", "messages", "connections", "snd_messages"], "readonly", async (tx) => {
        // Find rcv_message by broker_id
        const rmAll = await allByIndex(tx.objectStore("rcv_messages"), {conn_id: connId, broker_id: brokerId})
        if (rmAll.length === 0) return null
        const rm = rmAll[0]
        // JOIN connections: verify last_internal_msg_id = r.internal_id
        const conn = await idbReq(tx.objectStore("connections").get(connId))
        if (!conn || conn.last_internal_msg_id !== rm.internal_id) return null
        // JOIN messages
        const msg = await idbReq(tx.objectStore("messages").get([connId, rm.internal_id]))
        if (!msg) return null
        // LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
        const sndAll = await allByIndex(tx.objectStore("snd_messages"), {conn_id: connId})
        const sndRcpt = sndAll.find((s: any) => s.rcpt_internal_id === rm.internal_id)
        return {
          internalId: rm.internal_id,
          msgMeta: {
            integrity: rm.integrity,
            recipient: [rm.internal_id, msg.internal_ts],
            broker: [rm.broker_id, rm.broker_ts],
            sndMsgId: rm.external_snd_id,
            pqEncryption: msg.pq_encryption,
          },
          msgType: msg.msg_type,
          msgBody: msg.msg_body,
          userAck: rm.user_ack === 1,
          msgReceipt: sndRcpt?.rcpt_status ?? null,
        }
      })
    },

    // incMsgRcvAttempts (AgentStore.hs:1114-1125)
    // SQL: UPDATE rcv_messages SET receive_attempts = receive_attempts + 1
    //      WHERE conn_id = ? AND internal_id = ? RETURNING receive_attempts
    async incMsgRcvAttempts(connId, internalId) {
      return withTx("rcv_messages", "readwrite", async (tx) => {
        const store = tx.objectStore("rcv_messages")
        const all = await allByIndex(store, {conn_id: connId, internal_id: internalId})
        if (all.length === 0) throw new Error("rcv message not found")
        const rm = all[0]
        rm.receive_attempts = (rm.receive_attempts || 0) + 1
        await idbReq(store.put(rm))
        return rm.receive_attempts
      })
    },

    // checkRcvMsgHashExists (AgentStore.hs:1127-1133)
    // SQL: SELECT 1 FROM encrypted_rcv_message_hashes WHERE conn_id = ? AND hash = ? LIMIT 1
    async checkRcvMsgHashExists(connId, hash) {
      return withTx("encrypted_rcv_message_hashes", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("encrypted_rcv_message_hashes"), {conn_id: connId, hash})
        return all.length > 0
      })
    },

    // getRcvMsgBrokerTs (AgentStore.hs:1135-1138)
    // SQL: SELECT broker_ts FROM rcv_messages WHERE conn_id = ? AND broker_id = ?
    async getRcvMsgBrokerTs(connId, brokerId) {
      return withTx("rcv_messages", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("rcv_messages"), {conn_id: connId, broker_id: brokerId})
        if (all.length === 0) return null
        return all[0].broker_ts
      })
    },

    // deleteMsg (AgentStore.hs:1140-1142)
    // SQL: DELETE FROM messages WHERE conn_id = ? AND internal_id = ?
    async deleteMsg(connId, internalId) {
      return withTx("messages", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("messages").delete([connId, internalId]))
      })
    },

    // deleteDeliveredSndMsg (AgentStore.hs:1153-1159)
    // SQL: countPendingSndDeliveries_ then deleteMsg if cnt == 0
    // countPendingSndDeliveries_: SELECT count(*) FROM snd_message_deliveries WHERE conn_id = ? AND internal_id = ? AND failed = 0
    async deleteDeliveredSndMsg(connId, internalId) {
      return withTx(["snd_message_deliveries", "messages"], "readwrite", async (tx) => {
        const allDel = await idbReq(tx.objectStore("snd_message_deliveries").getAll())
        const cnt = allDel.filter((d: any) => toHex(d.conn_id) === toHex(connId) && d.internal_id === internalId && !d.failed).length
        if (cnt === 0) {
          await idbReq(tx.objectStore("messages").delete([connId, internalId]))
        }
      })
    },

    // deleteSndMsgDelivery (AgentStore.hs:1161-1205)
    // SQL1: DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ? AND internal_id = ?
    // SQL2: SELECT rcpt_status, snd_message_body_id FROM snd_messages
    //       WHERE NOT EXISTS (SELECT 1 FROM snd_message_deliveries WHERE conn_id = ? AND internal_id = ? AND failed = 0)
    //       AND conn_id = ? AND internal_id = ?
    // Then conditionally: DELETE FROM messages, DELETE FROM snd_message_bodies
    async deleteSndMsgDelivery(connId, sndQueue, msgId, keepForReceipt) {
      return withTx(["snd_message_deliveries", "snd_messages", "messages", "snd_message_bodies"], "readwrite", async (tx) => {
        // Delete the delivery record
        const delStore = tx.objectStore("snd_message_deliveries")
        const allDel = await idbReq(delStore.getAll())
        for (const d of allDel) {
          if (toHex(d.conn_id) === toHex(connId) && d.snd_queue_id === sndQueue.dbQueueId && d.internal_id === msgId) {
            await idbReq(delStore.delete(d.snd_message_delivery_id))
            break
          }
        }

        // Check if there are remaining non-failed deliveries
        const remainingDel = await idbReq(delStore.getAll())
        const hasPending = remainingDel.some((d: any) => toHex(d.conn_id) === toHex(connId) && d.internal_id === msgId && !d.failed)
        if (hasPending) return

        // Get snd_message for this msg
        const smAll = await allByIndex(tx.objectStore("snd_messages"), {conn_id: connId, internal_id: msgId})
        if (smAll.length === 0) return
        const sm = smAll[0]
        const rcptStatus = sm.rcpt_status
        const sndMsgBodyId = sm.snd_message_body_id

        // Decide whether to delete or clear content
        // MROk → deleteMsg; otherwise if keepForReceipt → deleteMsgContent; else deleteMsg
        const shouldDeleteFull = rcptStatus === "ok" || !keepForReceipt
        if (shouldDeleteFull) {
          await idbReq(tx.objectStore("messages").delete([connId, msgId]))
        } else {
          // deleteMsgContent: clear msg_body
          const msg = await idbReq(tx.objectStore("messages").get([connId, msgId]))
          if (msg) {
            msg.msg_body = new Uint8Array(0)
            await idbReq(tx.objectStore("messages").put(msg))
          }
          sm.snd_message_body_id = null
          await idbReq(tx.objectStore("snd_messages").put(sm))
        }

        // Delete snd_message_body if no other snd_messages reference it
        if (sndMsgBodyId != null) {
          const allSM = await idbReq(tx.objectStore("snd_messages").getAll())
          const referenced = allSM.some((s: any) => s.snd_message_body_id === sndMsgBodyId)
          if (!referenced) {
            await idbReq(tx.objectStore("snd_message_bodies").delete(sndMsgBodyId))
          }
        }
      })
    },

    // getSndMsgViaRcpt (AgentStore.hs:918-934)
    // SQL: SELECT s.internal_id, m.msg_type, s.internal_hash, s.rcpt_internal_id, s.rcpt_status
    //      FROM snd_messages s
    //      JOIN messages m ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
    //      WHERE s.conn_id = ? AND s.internal_snd_id = ?
    async getSndMsgViaRcpt(connId, sndMsgId) {
      return withTx(["snd_messages", "messages"], "readonly", async (tx) => {
        const sm = await idbReq(tx.objectStore("snd_messages").get([connId, sndMsgId]))
        if (!sm) return null
        const msg = await idbReq(tx.objectStore("messages").get([connId, sm.internal_id]))
        if (!msg) return null
        return {
          internalId: sm.internal_id,
          msgType: msg.msg_type,
          internalHash: sm.internal_hash,
          msgReceipt: sm.rcpt_internal_id != null && sm.rcpt_status != null
            ? {agentMsgId: sm.rcpt_internal_id, msgRcptStatus: sm.rcpt_status}
            : null,
        }
      })
    },

    // updateSndMsgRcpt (AgentStore.hs:936-941)
    // SQL: UPDATE snd_messages SET rcpt_internal_id = ?, rcpt_status = ? WHERE conn_id = ? AND internal_snd_id = ?
    async updateSndMsgRcpt(connId, sndMsgId, receipt) {
      return withTx("snd_messages", "readwrite", async (tx) => {
        const store = tx.objectStore("snd_messages")
        const sm = await idbReq(store.get([connId, sndMsgId]))
        if (sm) {
          sm.rcpt_internal_id = receipt.agentMsgId
          sm.rcpt_status = receipt.msgRcptStatus
          await idbReq(store.put(sm))
        }
      })
    },

    // ============================================================
    // Ratchet — AgentStore.hs:1246-1367
    // ============================================================

    // createRatchetX3dhKeys (AgentStore.hs:1246-1248)
    // SQL: INSERT INTO ratchets (conn_id, x3dh_priv_key_1, x3dh_priv_key_2, pq_priv_kem) VALUES (?, ?, ?, ?)
    async createRatchetX3dhKeys(connId, privKey1, privKey2, pqKem) {
      return withTx("ratchets", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("ratchets").add({
          conn_id: connId,
          x3dh_priv_key_1: privKey1, x3dh_priv_key_2: privKey2,
          pq_priv_kem: pqKem,
          ratchet_state: null,
          x3dh_pub_key_1: null, x3dh_pub_key_2: null, pq_pub_kem: null,
        }))
      })
    },

    // getRatchetX3dhKeys (AgentStore.hs:1250-1257)
    // SQL: SELECT x3dh_priv_key_1, x3dh_priv_key_2, pq_priv_kem FROM ratchets WHERE conn_id = ?
    async getRatchetX3dhKeys(connId) {
      return withTx("ratchets", "readonly", async (tx) => {
        const r = await idbReq(tx.objectStore("ratchets").get(connId))
        if (!r || !r.x3dh_priv_key_1 || !r.x3dh_priv_key_2) return null
        return {privKey1: r.x3dh_priv_key_1, privKey2: r.x3dh_priv_key_2, pqKem: r.pq_priv_kem}
      })
    },

    // createRatchet (AgentStore.hs:1303-1319)
    // SQL: INSERT INTO ratchets (conn_id, ratchet_state) VALUES (?, ?)
    //      ON CONFLICT (conn_id) DO UPDATE SET ratchet_state = ?,
    //      x3dh_priv_key_1 = NULL, x3dh_priv_key_2 = NULL, x3dh_pub_key_1 = NULL, x3dh_pub_key_2 = NULL,
    //      pq_priv_kem = NULL, pq_pub_kem = NULL
    async createRatchet(connId, ratchetState) {
      return withTx("ratchets", "readwrite", async (tx) => {
        // ON CONFLICT DO UPDATE → use put (upsert)
        await idbReq(tx.objectStore("ratchets").put({
          conn_id: connId,
          ratchet_state: ratchetState,
          x3dh_priv_key_1: null, x3dh_priv_key_2: null,
          x3dh_pub_key_1: null, x3dh_pub_key_2: null,
          pq_priv_kem: null, pq_pub_kem: null,
        }))
      })
    },

    // getRatchet (AgentStore.hs:1334-1345)
    // SQL: SELECT ratchet_state FROM ratchets WHERE conn_id = ?
    async getRatchet(connId) {
      return withTx("ratchets", "readonly", async (tx) => {
        const r = await idbReq(tx.objectStore("ratchets").get(connId))
        return r?.ratchet_state ?? null
      })
    },

    // getRatchetForUpdate (AgentStore.hs:1325-1332) — same as getRatchet in IndexedDB (single-threaded)
    async getRatchetForUpdate(connId) {
      return this.getRatchet(connId)
    },

    // getSkippedMsgKeys (AgentStore.hs:1347-1354)
    // SQL: SELECT header_key, msg_n, msg_key FROM skipped_messages WHERE conn_id = ?
    // Returns: Map<headerKey, Map<msgN, msgKey>>
    async getSkippedMsgKeys(connId) {
      return withTx("skipped_messages", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("skipped_messages"), {conn_id: connId})
        const result = new Map<string, Map<number, {mk: Uint8Array, iv: Uint8Array}>>()
        for (const row of all) {
          const hkHex = toHex(row.header_key)
          let inner = result.get(hkHex)
          if (!inner) {
            inner = new Map()
            result.set(hkHex, inner)
          }
          inner.set(row.msg_n, row.msg_key)
        }
        return result
      })
    },

    // updateRatchet (AgentStore.hs:1356-1366)
    // SQL1: UPDATE ratchets SET ratchet_state = ? WHERE conn_id = ?
    // SMDNoChange: no-op
    // SMDRemove: DELETE FROM skipped_messages WHERE conn_id = ? AND header_key = ? AND msg_n = ?
    // SMDAdd: INSERT INTO skipped_messages (conn_id, header_key, msg_n, msg_key) VALUES (?, ?, ?, ?)
    async updateRatchet(connId, ratchetState, skippedMsgDiff) {
      return withTx(["ratchets", "skipped_messages"], "readwrite", async (tx) => {
        // Update ratchet state
        const rStore = tx.objectStore("ratchets")
        const r = await idbReq(rStore.get(connId))
        if (r) {
          r.ratchet_state = ratchetState
          await idbReq(rStore.put(r))
        }
        // Apply skipped message diff
        const diff = skippedMsgDiff as any
        if (!diff || diff.type === "noChange") return
        const skStore = tx.objectStore("skipped_messages")
        if (diff.type === "remove") {
          // Delete specific skipped message
          const all = await allByIndex(skStore, {conn_id: connId})
          for (const row of all) {
            if (toHex(row.header_key) === toHex(diff.headerKey) && row.msg_n === diff.msgN) {
              await idbReq(skStore.delete(row.skipped_message_id))
              break
            }
          }
        } else if (diff.type === "add") {
          // Add new skipped message keys
          for (const [hk, mks] of diff.keys.entries()) {
            for (const [msgN, mk] of mks.entries()) {
              await idbReq(skStore.add({
                conn_id: connId, header_key: hk, msg_n: msgN, msg_key: mk,
              }))
            }
          }
        }
      })
    },

    // ============================================================
    // Commands — AgentStore.hs:1368-1497
    // ============================================================

    // createCommand (AgentStore.hs:1368-1392)
    // SQL: INSERT INTO commands (host, port, corr_id, conn_id, command_tag, command, server_key_hash, created_at) VALUES (?,?,?,?,?,?,?,?)
    async createCommand(corrId, connId, host, port, command) {
      return withTx("commands", "readwrite", async (tx) => {
        const id = await idbReq(tx.objectStore("commands").add({
          host, port, corr_id: corrId, conn_id: connId,
          command_tag: command.commandTag, command: command.command,
          agent_version: command.agentVersion,
          server_key_hash: command.serverKeyHash,
          created_at: new Date().toISOString(), failed: 0,
        }))
        return id as number
      })
    },

    // getPendingCommandServers (AgentStore.hs:1403-1422)
    // SQL: SELECT DISTINCT c.conn_id, c.host, c.port, COALESCE(c.server_key_hash, s.key_hash)
    //      FROM commands c LEFT JOIN servers s ON s.host = c.host AND s.port = c.port
    //      ORDER BY c.conn_id
    // Then filter by connIds set membership
    async getPendingCommandServers(connIds) {
      return withTx(["commands", "servers"], "readonly", async (tx) => {
        const allCmds = await idbReq(tx.objectStore("commands").getAll())
        const connIdSet = new Set(connIds.map(toHex))
        const seen = new Set<string>()
        const result: Array<{connId: Uint8Array, host: string, port: string}> = []
        for (const cmd of allCmds) {
          if (!cmd.host || !cmd.port) continue
          if (!connIdSet.has(toHex(cmd.conn_id))) continue
          const key = toHex(cmd.conn_id) + ":" + cmd.host + ":" + cmd.port
          if (!seen.has(key)) {
            seen.add(key)
            result.push({connId: cmd.conn_id, host: cmd.host, port: cmd.port})
          }
        }
        return result
      })
    },

    // getAllPendingCommandConns (AgentStore.hs:1424-1437)
    // SQL: SELECT DISTINCT c.conn_id, c.host, c.port, COALESCE(c.server_key_hash, s.key_hash)
    //      FROM commands c
    //      JOIN connections cs ON c.conn_id = cs.conn_id
    //      LEFT JOIN servers s ON s.host = c.host AND s.port = c.port
    //      WHERE cs.deleted = 0
    async getAllPendingCommandConns() {
      return withTx(["commands", "connections", "servers"], "readonly", async (tx) => {
        const allCmds = await idbReq(tx.objectStore("commands").getAll())
        const connStore = tx.objectStore("connections")
        const seen = new Set<string>()
        const result: Array<{connId: Uint8Array, host: string, port: string}> = []
        for (const cmd of allCmds) {
          if (!cmd.host || !cmd.port) continue
          const conn = await idbReq(connStore.get(cmd.conn_id))
          if (!conn || conn.deleted !== 0) continue
          const key = toHex(cmd.conn_id) + ":" + cmd.host + ":" + cmd.port
          if (!seen.has(key)) {
            seen.add(key)
            result.push({connId: cmd.conn_id, host: cmd.host, port: cmd.port})
          }
        }
        return result
      })
    },

    // getPendingServerCommand (AgentStore.hs:1439-1480)
    // When host/port are null:
    //   SQL: SELECT command_id FROM commands WHERE conn_id = ? AND host IS NULL AND port IS NULL AND failed = 0
    //        ORDER BY created_at ASC, command_id ASC LIMIT 1
    // When host/port are provided:
    //   SQL: SELECT command_id FROM commands WHERE conn_id = ? AND host = ? AND port = ? AND failed = 0
    //        ORDER BY created_at ASC, command_id ASC LIMIT 1
    // getCommand SQL: SELECT c.corr_id, cs.user_id, c.command FROM commands c
    //                 JOIN connections cs USING (conn_id) WHERE c.command_id = ?
    async getPendingServerCommand(connId, host, port) {
      return withTx(["commands", "connections"], "readonly", async (tx) => {
        const allCmds = await allByIndex(tx.objectStore("commands"), {conn_id: connId})
        // Filter by host/port and non-failed
        const pending = allCmds
          .filter((c: any) => {
            if (c.failed) return false
            if (host === null && port === null) return c.host == null && c.port == null
            return c.host === host && c.port === port
          })
          .sort((a: any, b: any) => {
            const tsCompare = (a.created_at || "").localeCompare(b.created_at || "")
            return tsCompare !== 0 ? tsCompare : (a.command_id - b.command_id)
          })
        if (pending.length === 0) return null
        return pending[0]
      })
    },

    // updateCommandServer (AgentStore.hs:1482-1493)
    // SQL: UPDATE commands SET host = ?, port = ?, server_key_hash = ? WHERE command_id = ?
    async updateCommandServer(commandId, host, port) {
      return withTx("commands", "readwrite", async (tx) => {
        const store = tx.objectStore("commands")
        const cmd = await idbReq(store.get(commandId))
        if (cmd) {
          cmd.host = host
          cmd.port = port
          await idbReq(store.put(cmd))
        }
      })
    },

    // deleteCommand (AgentStore.hs:1495-1497)
    // SQL: DELETE FROM commands WHERE command_id = ?
    async deleteCommand(commandId) {
      return withTx("commands", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("commands").delete(commandId))
      })
    },

    // ============================================================
    // Encrypted message hash dedup — AgentStore.hs:1127-1133, 2641
    // ============================================================

    // checkRcvMsgHashExists_encrypted (AgentStore.hs:1127-1133)
    // SQL: SELECT 1 FROM encrypted_rcv_message_hashes WHERE conn_id = ? AND hash = ? LIMIT 1
    async checkRcvMsgHashExists_encrypted(connId, hash) {
      return withTx("encrypted_rcv_message_hashes", "readonly", async (tx) => {
        const all = await allByIndex(tx.objectStore("encrypted_rcv_message_hashes"), {conn_id: connId, hash})
        return all.length > 0
      })
    },

    // addEncryptedRcvMsgHash (from insertRcvMsgDetails_ AgentStore.hs:2641)
    // SQL: INSERT INTO encrypted_rcv_message_hashes (conn_id, hash) VALUES (?,?)
    async addEncryptedRcvMsgHash(connId, hash) {
      return withTx("encrypted_rcv_message_hashes", "readwrite", async (tx) => {
        await idbReq(tx.objectStore("encrypted_rcv_message_hashes").add({
          conn_id: connId, hash, created_at: new Date().toISOString(),
        }))
      })
    },
  }
}
