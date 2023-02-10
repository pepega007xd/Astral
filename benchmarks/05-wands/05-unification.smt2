(set-info :source Astral)
(set-info :status sat)

(declare-sort Loc 0)
(declare-heap (Loc Loc))

(declare-const x Loc)
(declare-const y Loc)
(declare-const z Loc)

; The heap is empty and s(x) = s(z)
(assert
  (wand
    (pto x y)
    (pto z y)
  )
)

(check-sat)
