let rec tarai x y z =
    if x<y+1 then y
    else tarai (tarai (x-1) y z) (tarai (y-1) z x) (tarai (z-1) x y)
in print_int (tarai 15 5 0)
