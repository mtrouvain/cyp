Lemma: length (reverse ys) = length ys

Proof by induction on ys

-- Cases

Case Nil
    length (reverse Nil) 
    = length Nil
    
{-Between Case-}

Case :
    length (reverse (x:xs))
    = length (reverse xs ++ [x])
    = length (reverse xs) + length [x] --Sepp
    = length xs + length [x]
    = length (xs ++ [x])
    = length (x:xs)
{-After Hier darf kein C sein _ase-}
QED
{-Between Lemma 
Lemma: length (reverse ys) = length ys

Proof by equotions
{-Proof by biatch-
q.e.d.-}