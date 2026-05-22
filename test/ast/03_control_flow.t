terra if_else_statement(n : int) : int
    var result : int = 0
    if n < 0 then
        result = -1
    elseif n == 0 then
        result = 0
    else
        result = 1
    end
    return result
end

terra for_loop_test() : int
    var result : int = 0
    for i = 0, 10, 2 do
        result = result + i
    end
    return result
end

terra while_loop_test(count : int) : int
    while count < 10 do
        count = count + 1
        if count == 5 then
            break
        end
    end
    return count
end

terra repeat_loop_test(count : int) : int
    repeat
        count = count - 1
    until count <= 0
    return count
end