# Simplex.Messaging.TMap

> STM-safe concurrent map (`TVar (Map k a)`).

**Source**: [`TMap.hs`](../../../../src/Simplex/Messaging/TMap.hs)

## lookupInsert / lookupDelete

Atomic swap operations using `stateTVar` + `alterF`. `lookupInsert` returns the previous value (if any) while inserting the new one; `lookupDelete` returns the value while removing it. Both are single STM operations — no window between lookup and modification.

## union

Left-biased: the passed-in `Map` wins on key conflicts. `union additions tmap` overwrites existing keys in `tmap` with values from `additions`.

## alterF

The STM action `f` runs inside the same STM transaction. If `f` retries, the entire `alterF` retries. If `f` has side effects via other TVars, they compose atomically with the map modification.
