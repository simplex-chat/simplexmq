// TMVar — transactional mutable variable, empty or full.
// Transpilation of Haskell's Control.Concurrent.STM.TMVar for single-threaded JS.
//
// Operations:
//   take    — block until full, take value (leaves empty)
//   put     — block until empty, put value (leaves full)
//   read    — block until full, return value without taking
//   tryTake — non-blocking take, returns undefined if empty
//   tryPut  — non-blocking put, returns false if full
//   tryRead — non-blocking read, returns undefined if empty
//
// Used for:
//   doWork :: TMVar ()  — worker signaling
//   action :: TMVar ... — worker running state
//   retry lock          — delivery retry coordination

export class TMVar<T> {
  private val: T | undefined
  private full: boolean
  private takeQ: Array<(v: T) => void> = []
  private putQ: Array<() => void> = []

  private constructor(val: T | undefined, full: boolean) {
    this.val = val
    this.full = full
  }

  static empty<T>(): TMVar<T> {
    return new TMVar<T>(undefined, false)
  }

  static new<T>(v: T): TMVar<T> {
    return new TMVar<T>(v, true)
  }

  // Block until full, take value, leave empty.
  // Haskell: takeTMVar
  take(): Promise<T> {
    if (this.full) {
      const v = this.val as T
      this.val = undefined
      this.full = false
      // Wake one blocked putter
      const putter = this.putQ.shift()
      if (putter) putter()
      return Promise.resolve(v)
    }
    return new Promise<T>(resolve => this.takeQ.push(resolve))
  }

  // Block until empty, put value.
  // Haskell: putTMVar
  put(v: T): Promise<void> {
    if (!this.full) {
      // Check if a taker is waiting — hand off directly
      const taker = this.takeQ.shift()
      if (taker) {
        taker(v)
      } else {
        this.val = v
        this.full = true
      }
      return Promise.resolve()
    }
    return new Promise<void>(resolve => {
      this.putQ.push(() => {
        const taker = this.takeQ.shift()
        if (taker) {
          taker(v)
        } else {
          this.val = v
          this.full = true
        }
        resolve()
      })
    })
  }

  // Block until full, return value without taking.
  // Haskell: readTMVar
  //
  // In Haskell STM, readTMVar is atomic (take + put in one transaction).
  // In single-threaded JS, we read the value and leave it in place — no interleaving
  // between the read and the next synchronous operation.
  read(): Promise<T> {
    if (this.full) return Promise.resolve(this.val as T)
    return new Promise<T>(resolve => {
      this.takeQ.push(v => {
        // Put back immediately — single-threaded, no interleaving here
        this.val = v
        this.full = true
        resolve(v)
      })
    })
  }

  // Non-blocking take. Returns undefined if empty.
  // Haskell: tryTakeTMVar
  tryTake(): T | undefined {
    if (!this.full) return undefined
    const v = this.val as T
    this.val = undefined
    this.full = false
    const putter = this.putQ.shift()
    if (putter) putter()
    return v
  }

  // Non-blocking put. Returns false if full.
  // Haskell: tryPutTMVar
  tryPut(v: T): boolean {
    if (this.full) return false
    const taker = this.takeQ.shift()
    if (taker) {
      taker(v)
    } else {
      this.val = v
      this.full = true
    }
    return true
  }

  // Non-blocking read. Returns undefined if empty.
  // Haskell: tryReadTMVar
  tryRead(): T | undefined {
    return this.full ? (this.val as T) : undefined
  }

  isEmpty(): boolean {
    return !this.full
  }
}
