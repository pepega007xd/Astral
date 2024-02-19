(set-info :source Astral)
(set-info :status unsat)

(declare-sort Loc 0)
(declare-heap (Loc Loc))

(declare-const x1 NLS_t)
(declare-const x2 NLS_t)
(declare-const x3 NLS_t)

(assert
  (sep
    (pto x1 (c_nls x2 nil))
    (nls x2 x3 nil)
    (pto x3 (c_nls nil nil))
  )
)


(assert (not (nll x1 nil nil)))

(check-sat)
