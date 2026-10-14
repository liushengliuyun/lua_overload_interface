-- examples_v2.lua
-- OverloadV2 使用示例 + 自校验 (全部 assert 通过则打印 ALL PASS)
-- 运行: cd 到本目录后  lua examples_v2.lua   (Lua 5.1+ 均可)
--
-- 用户确认: 原版 Overload.lua 尾部 _G.DefineGlobal(...) 一行可删;
-- V2 不做全局注入, 标准 return 模块表。

local here = arg[0]:match("^(.*)[/\\]") or "."
local Overload = dofile(here .. "/OverloadV2.lua")

print("== OverloadV2 examples ==")

-- [1] 基础重载: 按 type 分派
local a = {}
Overload.mount(a)
a.overload.greet{ "string", function(s) return "hello " .. s end }
a.overload.greet{ "number", function(n) return "num " .. n end }
assert(a.greet("world") == "hello world")
assert(a.greet(42) == "num 42")
print("[1] basic overload ok")

-- [2] 多参数签名
a.overload.add{ "number", "number", function(x, y) return x + y end }
assert(a.add(1, 2) == 3)
print("[2] multi-arg ok")

-- [3] union 槽 (原版不支持): 任一类型名命中即可
a.overload.concat{ {"string", "number"}, "string", function(v, s) return tostring(v) .. s end }
assert(a.concat(1, "x") == "1x")
assert(a.concat("y", "x") == "yx")
print("[3] union slot ok")

-- [4] 谓词槽: 按值条件分派, 解决 XLua userdata 无法按 C# 类型分派的问题
--     (XLua 下 C# 对象 type() 全是 "userdata", 原版无法区分)
local function is_pos(n) return type(n) == "number" and n > 0 end
a.overload.inv{ is_pos, function(n) return 1 / n end }
a.overload.inv{ "number", function(n) return 0 end } -- 其余 number 兜底
assert(a.inv(5) == 0.2)
assert(a.inv(-1) == 0)
print("[4] predicate slot ok")
-- 注: 谓词签名与类型签名同形状时, 先注册者优先 (V2 exact 即中即返)
--     XLua 实战: local function is_transform(u)
--        return type(u) == "userdata" and u:GetType().Name == "Transform" end

-- [5] "..." 通配槽: 匹配零或多个额外参数
a.overload.sum{ "...", function(...) return (select("#", ...)) end }
assert(a.sum() == 0)
assert(a.sum(1, 2, 3) == 3)
print("[5] wildcard slot ok")

-- [6] 0 参重载: desc 只放函数
a.overload.now{ function() return "zero-arg" end }
assert(a.now() == "zero-arg")
print("[6] zero-arg ok")

-- [7] fallback 语义: 槽位全匹配但参数个数不符时, 调用它并传全部原始参数 (云风语义)
local b = {}
Overload.mount(b)
b.overload.two{ "number", "number", function(x, y) return "two:" .. (x + y) end }
assert(b.two(1, 2, 3) == "two:3")   -- 多传的 3 被忽略, 但确实透传了全部参数
print("[7] fallback semantics ok")

-- [8] 无匹配: 带函数名与实际参数类型的明确报错 (原版: attempt to call a nil value)
local ok, err = pcall(a.greet, true)
assert(not ok)
print("[8] clean error: " .. tostring(err))

-- [9] 同签名重注册 = 覆盖 (热重载安全; 原版同一 env 重挂载后注册会 assert 崩)
a.overload.greet{ "string", function(s) return "NEW " .. s end }
assert(a.greet("x") == "NEW x")
print("[9] re-register overwrite ok")

-- [10] desc 表复用: V2 不 mutate 调用方 desc (原版会弹出函数, 二次注册 assert 崩)
local shared_desc = { "number", function(n) return n * 10 end }
a.overload.times10(shared_desc)
a.overload.times10(shared_desc)
assert(a.times10(2) == 20)
print("[10] desc reuse ok")

-- [11] 独立 dispatcher (适合局部函数, 不占用表字段)
local abs2 = Overload.new("abs2")
Overload.def(abs2, { "number", function(n) return math.abs(n) end })
Overload.def(abs2, { "string", "string", function(s1, s2) return #s1 == #s2 end })
assert(abs2(-5) == 5)
assert(abs2("ab", "cd") == true)
print("[11] standalone dispatcher ok")

-- [12] 单态缓存冒烟: 同形状调用重复命中
for _ = 1, 3 do
    assert(a.greet("cache") == "NEW cache")
    assert(a.add(1, 2) == 3)
end
print("[12] inline cache smoke ok")

print("ALL PASS")


