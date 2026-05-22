struct Point {
    x : float
    y : float
}

terra struct_test() : float
    var p : Point
    p.x = 10.5
    p.y = 20.0
    return p.x + p.y
end

terra pointer_test() : int
    var a : int = 5
    var ptr : &int = &a
    @ptr = 10
    return a
end

terra cast_test(f : float) : int
    var x = [int](f)
    return x
end