(set-info :source Astral)
(set-info :status sat)

(declare-sort Loc 0)
(declare-heap (Loc Loc))

(declare-const x Loc)
(declare-const y Loc)

(assert (pto x (locPair nil nil)))

(assert (not (dls x y nil nil)))

(check-sat)