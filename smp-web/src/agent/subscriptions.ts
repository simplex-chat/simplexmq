// TSessionSubs — subscription tracking.
// Transpilation of Agent/TSessionSubs.hs (lines 49-201).
//
// Transport session key is (userId, server) serialized as string.
// One session per server (no TSMEntity mode).
// RecipientId key is hex-encoded Uint8Array.

// RcvQueueSub — subset of RcvQueue fields needed for subscription management.
// Transpilation of Agent/Store.hs:183-196.
export interface RcvQueueSub {
  userId: number
  connId: Uint8Array
  server: string  // serialized SMPServer
  rcvId: Uint8Array
  rcvPrivateKey: Uint8Array
  status: string
  enableNtfs: boolean
  clientNoticeId: number | null
  dbQueueId: number
  primary: boolean
  dbReplaceQueueId: number | null
}

function toHex(b: Uint8Array): string {
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
}

function rcvIdKey(rq: RcvQueueSub): string {
  return toHex(rq.rcvId)
}

// SessSubs (TSessionSubs.hs:53-57)
export interface SessSubs {
  sessId: Uint8Array | null   // SessionId
  activeSubs: Map<string, RcvQueueSub>   // keyed by rcvId hex
  pendingSubs: Map<string, RcvQueueSub>  // keyed by rcvId hex
}

// TSessionSubs (TSessionSubs.hs:49-51)
export class TSessionSubs {
  readonly sessionSubs: Map<string, SessSubs> = new Map()

  // -- Construction

  // clear (TSessionSubs.hs:63-65)
  clear(): void {
    this.sessionSubs.clear()
  }

  // -- Lookup helpers

  // lookupSubs (TSessionSubs.hs:67-69)
  private lookupSubs(tSess: string): SessSubs | undefined {
    return this.sessionSubs.get(tSess)
  }

  // getSessSubs (TSessionSubs.hs:71-77)
  private getSessSubs(tSess: string): SessSubs {
    const existing = this.sessionSubs.get(tSess)
    if (existing) return existing
    const s: SessSubs = {sessId: null, activeSubs: new Map(), pendingSubs: new Map()}
    this.sessionSubs.set(tSess, s)
    return s
  }

  // -- Query

  // hasActiveSub (TSessionSubs.hs:79-81)
  hasActiveSub(tSess: string, rcvId: string): boolean {
    const s = this.lookupSubs(tSess)
    return s ? s.activeSubs.has(rcvId) : false
  }

  // hasPendingSub (TSessionSubs.hs:83-85)
  hasPendingSub(tSess: string, rcvId: string): boolean {
    const s = this.lookupSubs(tSess)
    return s ? s.pendingSubs.has(rcvId) : false
  }

  // hasPendingSubs (TSessionSubs.hs:145-146)
  hasPendingSubs(tSess: string): boolean {
    const s = this.lookupSubs(tSess)
    return s ? s.pendingSubs.size > 0 : false
  }

  // getPendingSubs (TSessionSubs.hs:148-150)
  getPendingSubs(tSess: string): Map<string, RcvQueueSub> {
    return this.lookupSubs(tSess)?.pendingSubs ?? new Map()
  }

  // getActiveSubs (TSessionSubs.hs:152-154)
  getActiveSubs(tSess: string): Map<string, RcvQueueSub> {
    return this.lookupSubs(tSess)?.activeSubs ?? new Map()
  }

  // -- Mutation

  // addPendingSub (TSessionSubs.hs:91-92)
  addPendingSub(tSess: string, rq: RcvQueueSub): void {
    this.getSessSubs(tSess).pendingSubs.set(rcvIdKey(rq), rq)
  }

  // setSessionId (TSessionSubs.hs:94-99)
  setSessionId(tSess: string, sessId: Uint8Array): void {
    const s = this.getSessSubs(tSess)
    if (s.sessId === null) {
      s.sessId = sessId
    } else if (toHex(s.sessId) !== toHex(sessId)) {
      this.setSubsPending_(s, sessId)
    }
  }

  // addActiveSub (TSessionSubs.hs:101-110)
  addActiveSub(tSess: string, sessId: Uint8Array, rq: RcvQueueSub): void {
    const s = this.getSessSubs(tSess)
    const rId = rcvIdKey(rq)
    if (s.sessId && toHex(s.sessId) === toHex(sessId)) {
      s.activeSubs.set(rId, rq)
      s.pendingSubs.delete(rId)
    } else {
      s.pendingSubs.set(rId, rq)
    }
  }

  // batchAddActiveSubs (TSessionSubs.hs:112-121)
  batchAddActiveSubs(tSess: string, sessId: Uint8Array, rqs: RcvQueueSub[]): void {
    const s = this.getSessSubs(tSess)
    if (s.sessId && toHex(s.sessId) === toHex(sessId)) {
      for (const rq of rqs) {
        const rId = rcvIdKey(rq)
        s.activeSubs.set(rId, rq)
        s.pendingSubs.delete(rId)
      }
    } else {
      for (const rq of rqs) s.pendingSubs.set(rcvIdKey(rq), rq)
    }
  }

  // batchAddPendingSubs (TSessionSubs.hs:123-126)
  batchAddPendingSubs(tSess: string, rqs: RcvQueueSub[]): void {
    const s = this.getSessSubs(tSess)
    for (const rq of rqs) s.pendingSubs.set(rcvIdKey(rq), rq)
  }

  // deletePendingSub (TSessionSubs.hs:128-129)
  deletePendingSub(tSess: string, rcvId: string): void {
    this.lookupSubs(tSess)?.pendingSubs.delete(rcvId)
  }

  // batchDeletePendingSubs (TSessionSubs.hs:131-134)
  batchDeletePendingSubs(tSess: string, rcvIds: Set<string>): void {
    const s = this.lookupSubs(tSess)
    if (s) for (const rId of rcvIds) s.pendingSubs.delete(rId)
  }

  // deleteSub (TSessionSubs.hs:136-137)
  deleteSub(tSess: string, rcvId: string): void {
    const s = this.lookupSubs(tSess)
    if (s) {
      s.activeSubs.delete(rcvId)
      s.pendingSubs.delete(rcvId)
    }
  }

  // batchDeleteSubs (TSessionSubs.hs:139-143)
  batchDeleteSubs(tSess: string, rcvIds: string[]): void {
    const s = this.lookupSubs(tSess)
    if (s) for (const rId of rcvIds) {
      s.activeSubs.delete(rId)
      s.pendingSubs.delete(rId)
    }
  }

  // setSubsPending (TSessionSubs.hs:159-177)
  // Simplified: no TSMEntity mode. Session key is always (userId, server) with no entity ID.
  // So the mode check `entitySession == isJust connId_` always equals `false == false` = true,
  // taking the first branch: lookup + setSubsPending_ with Nothing.
  setSubsPending(tSess: string, sessId: Uint8Array): Map<string, RcvQueueSub> {
    const s = this.lookupSubs(tSess)
    if (!s) return new Map()
    if (!s.sessId || toHex(s.sessId) !== toHex(sessId)) return new Map()
    return this.setSubsPending_(s, null)
  }

  // setSubsPending_ (TSessionSubs.hs:179-187)
  private setSubsPending_(s: SessSubs, newSessId: Uint8Array | null): Map<string, RcvQueueSub> {
    s.sessId = newSessId
    const subs = new Map(s.activeSubs)
    if (subs.size > 0) {
      s.activeSubs.clear()
      for (const [rId, rq] of subs) s.pendingSubs.set(rId, rq)
    }
    return subs
  }

  // updateClientNotices (TSessionSubs.hs:189-192)
  // Skip for MVP — client notices are not implemented.
  updateClientNotices(_tSess: string, _noticeIds: Array<[string, number | null]>): void {
    // no-op
  }

  // foldSessionSubs (TSessionSubs.hs:194-195)
  foldSessionSubs<A>(f: (acc: A, entry: [string, SessSubs]) => A, initial: A): A {
    let acc = initial
    for (const entry of this.sessionSubs.entries()) acc = f(acc, entry)
    return acc
  }

  // mapSubs (TSessionSubs.hs:197-201)
  mapSubs<A>(f: (subs: Map<string, RcvQueueSub>) => A, s: SessSubs): [A, A] {
    return [f(s.activeSubs), f(s.pendingSubs)]
  }
}
