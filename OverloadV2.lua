-- OverloadV2.lua
-- Lua 函数重载库 V2: 平铺签名表 + 单态内联缓存
--
-- 背景: lua_overload_interface 原版是云风 trie 方案 (type 前缀树 + __end/"..." 哨兵 +
-- last_match 回退) 的语法糖包装。V2 保留 a.overload.foo{...} 注册语法, 引擎重写。
--
-- 相比原版的差异:
--   1. 无匹配/短参调用不再崩 "attempt to call a nil value", 而是 error 带函数名与实际参数类型串
--   2. 不 mutate 调用方传入的 desc 表 (原版 desc[#desc]=nil 会弹掉函数)
--   3. 热重载安全: 同签名重注册 = 覆盖, 不 assert 崩; 不依赖项目内 DefineGlobal
--   4. 谓词槽 / union 槽: 解决 XLua 下 C# 对象 type() 全为 "userdata" 无法分派的问题
--   5. 单态内联缓存: 同形状调用 (参数个数 + 逐槽检查) 命中即直接调用, 免注册表遍历
--
-- 分派语义 (对齐云风原版意图, 并修复其崩溃点):
--   * 只有 "全部必需槽位都匹配" 的签名才是候选 (部分匹配的签名不参与)
--   * 候选中深度 (必需槽位数) 最大者胜出; 同深度 exact (参数个数恰等) > fallback > wildcard("...")
--   * exact 命中立即返回; 无 exact 时调用胜出者并传入全部原始参数 (fallback 语义)
--   * 全无候选 -> error("Overload 'foo': no matching overload for (number, string)")
--
-- 槽位形式:
--   "number"           按 type() 名匹配 (8 种内建类型名, 拼写错误会在注册时报错)
--   function(x)->bool  谓词槽: 每次调用执行一次谓词 (含缓存命中路径), 注意谓词开销
--   {"number","string"}union 槽: 任一类型名命中即可 (原版不支持)
--   "..."              通配槽: 只能是最后一槽, 匹配零或多个额外参数
--   desc 最后一个元素必须是函数; {} + fn 即 0 参重载
--
-- API:
--   Overload.mount(env)               装配 env.overload 子表 (替代原版 include_overload / Overload(a))
--   env.overload.foo{ slots..., fn }  注册签名 (语法与原版一致)
--   Overload.new(name)                创建独立 dispatcher 函数
--   Overload.def(disp, desc)          给独立 dispatcher 注册签名
--
-- 兼容性: 纯标准 Lua (5.1+), 无全局注入, require/dofile 均可。

local M = { _NAME = "OverloadV2" }

local type, select, setmetatable, ipairs = type, select, setmetatable, ipairs
local format, concat = string.format, table.concat

local TYPE_SET = {
    ["nil"] = true, ["boolean"] = true, ["number"] = true, ["string"] = true,
    ["table"] = true, ["function"] = true, ["thread"] = true, ["userdata"] = true,
}

-- dispatcher 函数 -> registry (弱键: env 被 GC 后自动清理, 无泄漏)
local dispatchers = setmetatable({}, { __mode = "k" })

-- 单槽检查: checker 为 type 字符串 | 谓词函数 | union set 表
local function slot_hit(chk, arg)
    local ct = type(chk)
    if ct == "string" then
        return type(arg) == chk
    elseif ct == "function" then
        return chk(arg) and true or false
    end
    return chk[type(arg)] ~= nil
end

-- desc -> (checkers, wildcard, req, key); 不修改 desc 本身
local function normalize_slots(desc, name)
    local m = #desc
    local func = desc[m]
    if type(func) ~= "function" then
        error(format("Overload '%s': desc 最后一个元素必须是函数, 实际为 %s", name, type(func)), 0)
    end
    local slot_count = m - 1
    local wildcard = slot_count > 0 and desc[m - 1] == "..." or false
    local req = slot_count - (wildcard and 1 or 0)
    local checkers, key_parts = {}, {}
    for i = 1, slot_count do
        local slot = desc[i]
        if slot == nil then
            error(format("Overload '%s': 第 %d 槽为 nil (数组空洞); nil 参数槽请显式写字符串 \"nil\"", name, i), 0)
        elseif slot == "..." then
            if i ~= slot_count then
                error(format("Overload '%s': \"...\" 只能作为最后一个槽位", name), 0)
            end
            key_parts[i] = "..."
        else
            local st = type(slot)
            if st == "string" then
                if not TYPE_SET[slot] then
                    error(format("Overload '%s': 未知类型名 '%s' (槽 %d)", name, slot, i), 0)
                end
                checkers[i] = slot
                key_parts[i] = slot
            elseif st == "function" then
                checkers[i] = slot
                key_parts[i] = "f:" .. tostring(slot)
            elseif st == "table" then
                local set = {}
                for _, v in ipairs(slot) do
                    if type(v) ~= "string" or not TYPE_SET[v] then
                        error(format("Overload '%s': union 槽 (第 %d) 内必须是类型名", name, i), 0)
                    end
                    set[v] = true
                end
                if not next(set) then
                    error(format("Overload '%s': union 槽 (第 %d) 不能为空", name, i), 0)
                end
                checkers[i] = set
                key_parts[i] = "u:" .. concat(slot, "|")
            else
                error(format("Overload '%s': 槽 %d 必须是类型名/谓词函数/union 表, 实际为 %s", name, i, st), 0)
            end
        end
    end
    return checkers, wildcard, req, concat(key_parts, "\1")
end

-- 同 key 重注册 = 覆盖 (热重载安全); 否则追加。注册后缓存失效。
local function sig_add(reg, checkers, wildcard, req, key, func)
    for _, s in ipairs(reg.list) do
        if s.key == key then
            s.checkers, s.wildcard, s.req, s.func = checkers, wildcard, req, func
            reg.cache.func = nil
            return
        end
    end
    reg.list[#reg.list + 1] = { key = key, checkers = checkers, wildcard = wildcard, req = req, func = func }
    reg.cache.func = nil
end

local function dispatch(reg, ...)
    local n = select("#", ...)

    -- 单态缓存: 上次胜者的形状 (参数个数 + 逐槽检查) 命中即直接调用
    local c = reg.cache
    if c.func then
        local n_ok = c.wildcard and n >= c.req or n == c.req
        if n_ok then
            local ok = true
            for i = 1, c.req do
                if not slot_hit(c.chk[i], (select(i, ...))) then
                    ok = false
                    break
                end
            end
            if ok then
                return c.func(...)
            end
        end
    end

    -- 全量匹配: exact 即中即返; 否则按 (深度, 类别) 取最高分候选
    local best, best_score
    for i = 1, #reg.list do
        local s = reg.list[i]
        local d = 0
        for j = 1, s.req do
            if slot_hit(s.checkers[j], (select(j, ...))) then
                d = j
            else
                break
            end
        end
        if d == s.req then
            local score
            if not s.wildcard then
                if n == s.req then
                    -- exact: 深度已达上限且个数恰等, 必为最优, 直接返回
                    c.func, c.chk, c.req, c.wildcard = s.func, s.checkers, s.req, false
                    return s.func(...)
                end
                score = s.req * 4 + 1 -- fallback 候选 (槽位全匹配, 参数个数不符)
            else
                score = s.req * 4 -- wildcard 候选 (同深度时让位于精确槽位签名)
            end
            if score > (best_score or -1) then
                best, best_score = s, score
            end
        end
    end

    if not best then
        local parts = {}
        for i = 1, n do
            parts[i] = type((select(i, ...)))
        end
        error(format("Overload '%s': no matching overload for (%s)", reg.name, concat(parts, ", ")), 0)
    end

    c.func, c.chk, c.req, c.wildcard = best.func, best.checkers, best.req, best.wildcard
    return best.func(...) -- fallback/wildcard 均传全部原始参数
end

local function new_registry(name)
    return { name = name or "anonymous", list = {}, cache = { func = nil } }
end

local function make_dispatcher(reg)
    local function dispatcher(...)
        return dispatch(reg, ...)
    end
    dispatchers[dispatcher] = reg
    return dispatcher
end

--- 创建独立 dispatcher 函数
function M.new(name)
    return make_dispatcher(new_registry(name))
end

--- 给独立 dispatcher 注册签名
function M.def(disp, desc)
    local reg = dispatchers[disp]
    if not reg then
        error("Overload.def: 第一个参数必须是 Overload.new 创建的 dispatcher", 2)
    end
    local checkers, wildcard, req, key = normalize_slots(desc, reg.name)
    sig_add(reg, checkers, wildcard, req, key, desc[#desc])
    return disp
end

-- env.overload.<name>{desc} 语法糖: 每次访问生成一个一次性 receiver 闭包 (仅注册期, 开销可忽略)
local function add(env, name, desc)
    local reg = dispatchers[env[name]]
    if not reg then
        if env[name] ~= nil then
            error(format("Overload.mount: env['%s'] 已存在且不是 Overload dispatcher", name), 0)
        end
        reg = new_registry(name)
        env[name] = make_dispatcher(reg)
    end
    local checkers, wildcard, req, key = normalize_slots(desc, reg.name)
    sig_add(reg, checkers, wildcard, req, key, desc[#desc])
    return env[name]
end

--- 装配 env.overload 子表 (替代原版 include_overload / Overload(a)); 幂等
function M.mount(env)
    rawset(env, "overload", setmetatable({}, {
        __index = function(_, k)
            return function(desc)
                return add(env, k, desc)
            end
        end,
    }))
    return env
end

return M
