local WoWForeverRace = _G.WoWForeverRace

-- table helpers
WoWForeverRace.table = {}

WoWForeverRace.table.contains = function(list, value)
    for _, v in pairs(list) do
        if v == value then
            return true
        end
    end

    return false
end

WoWForeverRace.table.filter = function(list, filterfn)
    local result = {}
    for k, v in ipairs(list) do
        if filterfn(v) then
            result[k] = v
        end
    end

    return result
end

WoWForeverRace.table.reduce = function(table, fn, acc)
    for _, v in pairs(table) do
        if acc == nil then
            acc = v
        else
            acc = fn(v, acc)
        end
    end
    return acc
end

WoWForeverRace.table.sum = function(table)
    return WoWForeverRace.table.reduce(table, function(a, b)
        return a + b
    end)
end

WoWForeverRace.table.cnt = function(table)
    return WoWForeverRace.table.reduce(table, function(_, cnt)
        return cnt + 1
    end, 0)
end

WoWForeverRace.table.avg = function(table)
    return WoWForeverRace.table.sum(table) / WoWForeverRace.table.cnt(table)
end

WoWForeverRace.table.min = function(table)
    return WoWForeverRace.table.reduce(table, function(a, b)
        if a > b then
            return b
        else
            return a
        end
    end)
end

WoWForeverRace.table.max = function(table)
    return WoWForeverRace.table.reduce(table, function(a, b)
        if a > b then
            return a
        else
            return b
        end
    end)
end

WoWForeverRace.table.cntsumminmax = function(table, valuefn)
    local cnt = 0
    local minn = nil
    local maxx = nil
    local sum = nil

    for _, v in pairs(table) do
        if valuefn ~= nil then
            v = valuefn(v)
        end

        cnt = cnt + 1

        if sum == nil then
            sum = v
        else
            sum = sum + v
        end

        if maxx == nil or v > maxx then
            maxx = v
        end
        if minn == nil or v < minn then
            minn = v
        end
    end

    return cnt, sum, minn, maxx
end
