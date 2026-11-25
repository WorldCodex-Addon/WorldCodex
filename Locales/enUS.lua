local _, ns = ...

ns.L = setmetatable({}, {
    __index = function(t, k)
        rawset(t, k, k)
        return k
    end,
})
