---- MODULE util ----

RECURSIVE FoldSet(_,_,_)

FoldSet(f(_,_), init, set) ==
    IF  set = {}
    THEN
        init
    ELSE
        LET next == CHOOSE x \in set : TRUE
        IN  FoldSet(f, f(next, init), set \ { next })

====
