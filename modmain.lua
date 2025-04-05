-- 在文件开头添加
local LOG_LEVEL = GetModConfigData("log_level") or 2

-- 在文件开头添加清理记录表
local BUFF_CLEANUP = {}

-- 在文件开头补充全局表访问
local _G = GLOBAL

local env = env

GLOBAL.setmetatable(env, { __index = function(t, k) return GLOBAL.rawget(GLOBAL, k) end })

-- 以下两行仅在开发测试时使用，发布模组前应删除
-- _G.CHEATS_ENABLED = true
-- _G.require("debugkeys")

-- 修改DebugLog函数
local function DebugLog(level, ...)
    if level > LOG_LEVEL then return end
    
    local args = {...}
    local message = "[每日惊喜] "
    for i, v in ipairs(args) do
        message = message .. tostring(v) .. " "
    end
    
    _G.print(message)
    if TheNet:GetIsServer() then
        TheNet:SystemMessage(message)
    end
end

-- mod初始化提示
DebugLog(1, "开始加载mod")

-- 安全地获取mod配置
local success, BUFF_DURATION = _G.pcall(function() 
    return GetModConfigData("buff_duration") 
end)

-- 配置错误处理
if not success or not BUFF_DURATION then
    DebugLog(1, "错误：无法获取mod配置，使用默认值1")
    BUFF_DURATION = 1
else
    DebugLog(1, "BUFF持续时间设置为:", BUFF_DURATION, "天")
end

-- 获取随机玩家数量配置
local success_players, RANDOM_PLAYERS_COUNT = _G.pcall(function() 
    return GetModConfigData("random_players_count") 
end)

-- 配置错误处理
if not success_players or not RANDOM_PLAYERS_COUNT then
    DebugLog(1, "错误：无法获取随机玩家数量配置，使用默认值1")
    RANDOM_PLAYERS_COUNT = 1
else
    DebugLog(1, "每日惊喜将随机选择", RANDOM_PLAYERS_COUNT, "名玩家")
end

-- 获取是否启用DEBUFF配置
local success_debuff, ENABLE_DEBUFF = _G.pcall(function() 
    return GetModConfigData("enable_debuff") 
end)

-- 配置错误处理
if not success_debuff then
    ENABLE_DEBUFF = false
end

-- 获取DEBUFF几率配置
local success_debuff_chance, DEBUFF_CHANCE = _G.pcall(function() 
    return GetModConfigData("debuff_chance") 
end)

-- 配置错误处理
if not success_debuff_chance then
    DEBUFF_CHANCE = 0.3
end

-- 全局变量声明
local lastday = -1  -- 记录上一次应用BUFF的天数
local LAST_SAVE_DAY = -1  -- 记录最后保存的天数

-- BUFF效果列表定义
local BUFF_LIST = {
    {
        id = "BUFF_001",
        name = "超级速度",
        description = "你感觉浑身充满了力量，移动速度提升了100%！",
        fn = function(player)
            player.components.locomotor:SetExternalSpeedMultiplier(player, "speedbuff", 2)
            
            return function()
                if player:IsValid() then
                    player.components.locomotor:RemoveExternalSpeedMultiplier(player, "speedbuff")
                    DebugLog(3, "清理速度效果")
                end
            end
        end
    },
    {
        id = "BUFF_002",
        name = "巨人化",
        description = "你变成了一个巨人，体型增大了50%！",
        fn = function(player)
            local original_scale = player.Transform:GetScale()
            player.Transform:SetScale(original_scale * 1.5, original_scale * 1.5, original_scale * 1.5)
            
            return function()
                if player:IsValid() then
                    player.Transform:SetScale(original_scale, original_scale, original_scale)
                    DebugLog(3, "清理巨人化效果")
                end
            end
        end
    },
    {
        id = "BUFF_003",
        name = "饥饿加速",
        description = "你的新陈代谢变快了，饥饿速度增加了100%！",
        fn = function(player)
            if player.components.hunger then
                local old_rate = player.components.hunger.hungerrate
                player.components.hunger.hungerrate = old_rate * 2
                
                return function()
                    if player:IsValid() and player.components.hunger then
                        player.components.hunger.hungerrate = old_rate
                    end
                end
            end
        end
    },
    {
        id = "BUFF_004",
        name = "幸运日",
        description = "今天运气特别好，击杀生物有50%几率获得双倍掉落！",
        fn = function(player)
            local old_onkilledother = player.OnKilledOther
            player.OnKilledOther = function(inst, data)
                if old_onkilledother then
                    old_onkilledother(inst, data)
                end
                
                if data and data.victim and data.victim.components.lootdropper then
                    if _G.math.random() < 0.5 then
                        data.victim.components.lootdropper:DropLoot()
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnKilledOther = old_onkilledother
                end
            end
        end
    },
    {
        id = "BUFF_005",
        name = "夜视能力",
        description = "你获得了在黑暗中视物的能力，夜晚也能看得一清二楚！",
        fn = function(player)
            if player.components.playervision then
                player.components.playervision:SetCustomCCTable({day = 0, dusk = 0, night = 0.7})
                
                return function()
                    if player:IsValid() and player.components.playervision then
                        player.components.playervision:SetCustomCCTable(nil)
                        DebugLog(3, "清理夜视效果")
                    end
                end
            end
        end
    },
    {
        id = "BUFF_006",
        name = "饥饿减缓",
        description = "你的新陈代谢变慢了，饥饿速度降低了50%！",
        fn = function(player)
            if player.components.hunger then
                local old_rate = player.components.hunger.hungerrate
                player.components.hunger.hungerrate = old_rate * 0.5
                
                return function()
                    if player:IsValid() and player.components.hunger then
                        player.components.hunger.hungerrate = old_rate
                    end
                end
            end
        end
    },
    {
        id = "BUFF_007",
        name = "随机传送",
        description = "空间在你周围不稳定，每隔一段时间有30%几率随机传送！",
        fn = function(player)
            local task = player:DoPeriodicTask(30, function()
                if _G.math.random() < 0.3 then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local offset = 20
                    local angle = _G.math.random() * 2 * _G.math.pi
                    local new_x = x + offset * _G.math.cos(angle)
                    local new_z = z + offset * _G.math.sin(angle)
                    
                    player.Physics:Teleport(new_x, 0, new_z)
                    
                    if player.components.talker then
                        player.components.talker:Say("哇！随机传送！")
                    end
                end
            end)
            
            return function()
                if task then task:Cancel() end
            end
        end
    },
    {
        id = "BUFF_008",
        name = "生物朋友",
        description = "野生生物似乎对你产生了好感，不会主动攻击你！",
        fn = function(player)
            player:AddTag("friendlycreatures")
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("friendlycreatures")
                end
            end
        end
    },
    {
        id = "BUFF_009",
        name = "小矮人",
        description = "你变得非常小，体型缩小到原来的60%！",
        fn = function(player)
            local original_scale = player.Transform:GetScale()
            player.Transform:SetScale(original_scale * 0.6, original_scale * 0.6, original_scale * 0.6)
            
            return function()
                if player:IsValid() then
                    player.Transform:SetScale(original_scale, original_scale, original_scale)
                end
            end
        end
    },
    {
        id = "BUFF_010",
        name = "彩虹光环",
        description = "你的周围出现了美丽的彩虹光环，不断变换着颜色！",
        fn = function(player)
            local light = _G.SpawnPrefab("minerhatlight")
            if light then
                light.entity:SetParent(player.entity)
                light.Light:SetRadius(2)
                light.Light:SetFalloff(0.5)
                light.Light:SetIntensity(0.8)
                
                local colors = {
                    {r=1, g=0, b=0},   -- 红
                    {r=1, g=0.5, b=0}, -- 橙
                    {r=1, g=1, b=0},   -- 黄
                    {r=0, g=1, b=0},   -- 绿
                    {r=0, g=0, b=1},   -- 蓝
                    {r=0.5, g=0, b=0.5} -- 紫
                }
                
                local color_index = 1
                local color_task = _G.TheWorld:DoPeriodicTask(0.5, function()
                    color_index = color_index % #colors + 1
                    local color = colors[color_index]
                    light.Light:SetColour(color.r, color.g, color.b)
                end)
                
                return function()
                    if color_task then color_task:Cancel() end
                    if light and light:IsValid() then
                        light:Remove()
                    end
                end
            end
        end
    },
    {
        id = "BUFF_011",
        name = "元素亲和",
        description = "你获得了对温度的抗性，不容易过热或者过冷！",
        fn = function(player)
            local original = {
                overheat = player.components.temperature.overheattemp,
                freeze = player.components.temperature.freezetemp
            }
            
            player.components.temperature.overheattemp = 100
            player.components.temperature.freezetemp = -100
            
            return function()
                if player:IsValid() and player.components.temperature then
                    player.components.temperature.overheattemp = original.overheat
                    player.components.temperature.freezetemp = original.freeze
                end
            end
        end
    },
    {
        id = "BUFF_012",
        name = "光合作用",
        description = "阳光照射在你身上会恢复生命值和饥饿值，就像植物一样！",
        fn = function(player)
            local task = player:DoPeriodicTask(10, function()
                if player:IsValid() and _G.TheWorld and _G.TheWorld.state and _G.TheWorld.state.isday then
                    if player.components.health then
                        player.components.health:DoDelta(5)
                    end
                    if player.components.hunger then
                        player.components.hunger:DoDelta(5)
                    end
                end
            end)
            
            return function()
                if task then task:Cancel() end
            end
        end
    },
    {
        id = "BUFF_013",
        name = "幸运垂钓",
        description = "钓鱼时总能钓到双倍的收获！",
        fn = function(player)
            if not player.components.fisherman then
                DebugLog(1, "玩家没有钓鱼组件")
                return
            end
            
            local old_catch = player.components.fisherman.OnCaughtFish
            player.components.fisherman.OnCaughtFish = function(self, fish, ...)
                local result = old_catch(self, fish, ...)
                if fish and fish.components.stackable 
                    and not fish:HasTag("rare") then
                    
                    fish.components.stackable:SetStackSize(fish.components.stackable.stacksize * 2)
                    DebugLog(3, "钓鱼收获加倍:", fish.prefab)
                end
                return result
            end
            
            return function()
                if player:IsValid() and player.components.fisherman then
                    player.components.fisherman.OnCaughtFish = old_catch
                    DebugLog(3, "清理幸运垂钓效果")
                end
            end
        end
    },
    {
        id = "BUFF_014",
        name = "星之祝福",
        description = "一颗明亮的星星在你头顶闪耀，照亮你的道路！",
        fn = function(player)
            local star = _G.SpawnPrefab("stafflight")
            if star then
                star.entity:SetParent(player.entity)
                star.Transform:SetPosition(0, 3, 0)
                star.Light:SetColour(0.2, 0.6, 1)
                star.Light:SetIntensity(0.8)
                
                return function()
                    if star and star:IsValid() then
                        star:Remove()
                    end
                end
            end
        end
    },
    {
        id = "BUFF_015",
        name = "资源探测器",
        description = "你能感知到附近的资源位置，它们会发出微弱的光芒！",
        fn = function(player)
            local detect_range = 20
            local detect_task = player:DoPeriodicTask(5, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, detect_range, nil, {"INLIMBO"})
                    
                    for _, ent in pairs(ents) do
                        if ent.prefab and (
                            ent:HasTag("tree") or 
                            ent:HasTag("boulder") or 
                            ent:HasTag("flower") or
                            ent:HasTag("berry") or
                            ent.prefab == "flint" or
                            ent.prefab == "goldnugget"
                        ) then
                            -- 确保fx存在
                            local fx = SpawnPrefab("miniboatlantern_projected_ground")
                            if fx then
                                local ex, ey, ez = ent.Transform:GetWorldPosition()
                                fx.Transform:SetPosition(ex, 0, ez)
                                fx:DoTaskInTime(3, function() 
                                    if fx and fx:IsValid() then 
                                        fx:Remove() 
                                    end 
                                end)
                            end
                        end
                    end
                end
            end)
            
            return function()
                if detect_task then
                    detect_task:Cancel()
                    DebugLog(3, "清理资源探测器效果")
                end
            end
        end
    },
    {
        id = "BUFF_016",
        name = "食物保鲜",
        description = "你随身携带的食物永远保持新鲜！",
        fn = function(player)
            local old_fn = player.components.inventory.DropItem
            player.components.inventory.DropItem = function(self, item, ...)
                if item and item.components.perishable then
                    item.components.perishable:SetPercent(1)
                end
                return old_fn(self, item, ...)
            end
            
            -- 定期刷新背包中的食物
            local refresh_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    for _, item in pairs(items) do
                        if item and item.components.perishable then
                            item.components.perishable:SetPercent(1)
                        end
                    end
                end
            end)
            
            return function()
                if player:IsValid() and player.components.inventory then
                    player.components.inventory.DropItem = old_fn
                end
                if refresh_task then
                    refresh_task:Cancel()
                end
                DebugLog(3, "清理食物保鲜效果")
            end
        end
    },
    {
        id = "BUFF_017",
        name = "宠物召唤师",
        description = "一只可爱的小动物会一直跟随着你！",
        fn = function(player)
            -- 召唤一个跟随玩家的小动物
            local pet_type = {"rabbit", "perd", "butterfly", "robin"} -- 添加更多安全的宠物选项
            local pet = SpawnPrefab(pet_type[math.random(#pet_type)])
            
            if pet then
                local x, y, z = player.Transform:GetWorldPosition()
                pet.Transform:SetPosition(x, y, z)
                
                -- 让宠物跟随玩家
                local follow_task = pet:DoPeriodicTask(1, function()
                    if player:IsValid() and pet:IsValid() then
                        local px, py, pz = player.Transform:GetWorldPosition()
                        local ex, ey, ez = pet.Transform:GetWorldPosition()
                        local dist = math.sqrt((px-ex)^2 + (pz-ez)^2)
                        
                        if dist > 10 then
                            -- 瞬移到玩家附近
                            local angle = math.random() * 2 * PI
                            local radius = 3 + math.random() * 2
                            pet.Transform:SetPosition(px + radius * math.cos(angle), 0, pz + radius * math.sin(angle))
                        elseif dist > 3 then
                            -- 向玩家移动
                            if pet.components.locomotor then
                                pet.components.locomotor:GoToPoint(Vector3(px, py, pz))
                            end
                        end
                        
                        -- 防止宠物被攻击
                        if pet.components.health then
                            pet.components.health:SetInvincible(true)
                        end
                        
                        -- 防止宠物攻击玩家
                        if pet.components.combat then
                            pet.components.combat:SetTarget(nil)
                        end
                    end
                end)
                
                return function()
                    if follow_task then
                        follow_task:Cancel()
                    end
                    if pet and pet:IsValid() then
                        pet:Remove()
                    end
                    DebugLog(3, "清理宠物召唤师效果")
                end
            else
                return function() end
            end
        end
    },
    {
        id = "BUFF_018",
        name = "蜜蜂朋友",
        description = "友好的蜜蜂会跟随你，并定期为你产出蜂蜜！",
        fn = function(player)
            local bee_count = 3
            local bees = {}
            
            -- 生成蜜蜂
            for i = 1, bee_count do
                local bee = SpawnPrefab("bee")
                if bee then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = 2 * PI * i / bee_count
                    local radius = 2
                    bee.Transform:SetPosition(x + radius * math.cos(angle), y, z + radius * math.sin(angle))
                    
                    -- 让蜜蜂友好
                    if bee.components.combat then
                        -- 不移除combat组件，而是修改它的行为
                        bee.components.combat:SetTarget(nil)
                        bee.components.combat.retargetfn = function() return nil end
                        bee.components.combat.keeptargetfn = function() return false end
                    end
                    
                    -- 移除蜜蜂的攻击性
                    if bee.components.health then
                        bee.components.health:SetInvincible(true)
                    end
                    
                    -- 让蜜蜂跟随玩家
                    local follow_task = bee:DoPeriodicTask(0.5, function()
                        if player:IsValid() and bee:IsValid() then
                            local px, py, pz = player.Transform:GetWorldPosition()
                            local ex, ey, ez = bee.Transform:GetWorldPosition()
                            local dist = math.sqrt((px-ex)^2 + (pz-ez)^2)
                            
                            if dist > 10 then
                                -- 瞬移到玩家附近
                                local angle = math.random() * 2 * PI
                                local radius = 2 + math.random()
                                bee.Transform:SetPosition(px + radius * math.cos(angle), py, pz + radius * math.sin(angle))
                            elseif dist > 3 then
                                -- 向玩家移动
                                if bee.components.locomotor then
                                    bee.components.locomotor:GoToPoint(Vector3(px, py, pz))
                                end
                            end
                        end
                    end)
                    
                    -- 定期产生蜂蜜
                    local honey_task = bee:DoPeriodicTask(120, function()
                        if player:IsValid() and bee:IsValid() then
                            local honey = SpawnPrefab("honey")
                            if honey then
                                local x, y, z = player.Transform:GetWorldPosition()
                                honey.Transform:SetPosition(x, y, z)
                                if player.components.talker then
                                    player.components.talker:Say("蜜蜂朋友给了我蜂蜜！")
                                end
                            end
                        end
                    end)
                    
                    table.insert(bees, {bee = bee, follow_task = follow_task, honey_task = honey_task})
                end
            end
            
            return function()
                for _, bee_data in ipairs(bees) do
                    if bee_data.follow_task then
                        bee_data.follow_task:Cancel()
                    end
                    if bee_data.honey_task then
                        bee_data.honey_task:Cancel()
                    end
                    if bee_data.bee and bee_data.bee:IsValid() then
                        bee_data.bee:Remove()
                    end
                end
                DebugLog(3, "清理蜜蜂朋友效果")
            end
        end
    },
    {
        id = "BUFF_019",
        name = "植物掌控",
        description = "你能加速植物生长，走过的地方还会开出鲜花！",
        fn = function(player)
            -- 加快附近植物生长
            local growth_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                    
                    for _, ent in pairs(ents) do
                        -- 加速树木生长
                        if ent.components.growable then
                            ent.components.growable:DoGrowth()
                        end
                        
                        -- 加速作物生长
                        if ent.components.crop then
                            ent.components.crop:DoGrow(5)
                        end
                        
                        -- 加速浆果生长
                        if ent.components.pickable and ent.components.pickable.targettime then
                            ent.components.pickable.targettime = ent.components.pickable.targettime - 120
                        end
                    end
                end
            end)
            
            -- 走过的地方有几率长出花朵
            local flower_task = player:DoPeriodicTask(3, function()
                if player:IsValid() and player:HasTag("moving") then
                    local x, y, z = player.Transform:GetWorldPosition()
                    if math.random() < 0.3 then
                        local flower = SpawnPrefab("flower")
                        if flower then
                            local offset = 1.5
                            flower.Transform:SetPosition(
                                x + math.random(-offset, offset), 
                                0, 
                                z + math.random(-offset, offset)
                            )
                        end
                    end
                end
            end)
            
            return function()
                if growth_task then
                    growth_task:Cancel()
                end
                if flower_task then
                    flower_task:Cancel()
                end
                DebugLog(3, "清理植物掌控效果")
            end
        end
    },
    {
        id = "BUFF_020",
        name = "元素掌控",
        description = "你的攻击会随机附带火焰、冰霜或闪电效果！",
        fn = function(player)
            -- 添加元素光环效果
            local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
            if fx then
                fx.entity:SetParent(player.entity)
                fx.Transform:SetPosition(0, 0, 0)
            end
            
            -- 添加元素攻击能力
            local old_attack = ACTIONS.ATTACK.fn
            ACTIONS.ATTACK.fn = function(act)
                local target = act.target
                local doer = act.doer
                
                if doer == player and target and target:IsValid() then
                    -- 随机元素效果
                    local element = math.random(3)
                    
                    if element == 1 then  -- 火
                        if target.components.burnable and not target.components.burnable:IsBurning() then
                            target.components.burnable:Ignite()
                        end
                    elseif element == 2 then  -- 冰
                        if target.components.freezable then
                            target.components.freezable:AddColdness(2)
                        end
                    else  -- 电
                        local x, y, z = target.Transform:GetWorldPosition()
                        TheWorld:PushEvent("ms_sendlightningstrike", Vector3(x, y, z))
                    end
                end
                
                return old_attack(act)
            end
            
            return function()
                ACTIONS.ATTACK.fn = old_attack
                if fx and fx:IsValid() then
                    fx:Remove()
                end
                DebugLog(3, "清理元素掌控效果")
            end
        end
    },
    {
        id = "BUFF_021",
        name = "影分身",
        description = "一个影子分身，只会跟着你白给。",
        fn = function(player)
            -- 创建影子分身
            local shadow = SpawnPrefab("shadowduelist")
            if shadow then
                local x, y, z = player.Transform:GetWorldPosition()
                shadow.Transform:SetPosition(x, y, z)
                
                -- 让影子分身跟随玩家
                local follow_task = shadow:DoPeriodicTask(0.5, function()
                    if player:IsValid() and shadow:IsValid() then
                        local px, py, pz = player.Transform:GetWorldPosition()
                        local sx, sy, sz = shadow.Transform:GetWorldPosition()
                        local dist = math.sqrt((px-sx)^2 + (pz-sz)^2)
                        
                        if dist > 15 then
                            -- 瞬移到玩家附近
                            shadow.Transform:SetPosition(px, py, pz)
                        elseif dist > 3 then
                            -- 向玩家移动
                            if shadow.components.locomotor then
                                shadow.components.locomotor:GoToPoint(Vector3(px, py, pz))
                            end
                        end
                        
                        -- 攻击玩家附近的敌人
                        if shadow.components.combat then
                            local enemies = TheSim:FindEntities(sx, sy, sz, 10, nil, {"player", "INLIMBO"})
                            local target = nil
                            
                            for _, ent in ipairs(enemies) do
                                if ent.components.combat and 
                                   ent.components.combat.target == player and
                                   ent:IsValid() then
                                    target = ent
                                    break
                                end
                            end
                            
                            if target then
                                shadow.components.combat:SetTarget(target)
                            end
                        end
                    end
                end)
                
                return function()
                    if follow_task then
                        follow_task:Cancel()
                    end
                    if shadow and shadow:IsValid() then
                        shadow:Remove()
                    end
                    DebugLog(3, "清理影分身效果")
                end
            end
            
            return function() end
        end
    },
    {
        id = "BUFF_022",
        name = "宝藏探测",
        description = "每隔一段时间在玩家附近生成一个宝藏",
        fn = function(player)
            -- 每隔一段时间在玩家附近生成一个宝藏
            local treasure_task = player:DoPeriodicTask(240, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local offset = 10
                    local treasure_x = x + math.random(-offset, offset)
                    local treasure_z = z + math.random(-offset, offset)
                    
                    -- 创建宝藏标记
                    local marker = SpawnPrefab("messagebottle")
                    if marker then
                        marker.Transform:SetPosition(treasure_x, 0, treasure_z)
                        
                        -- 在宝藏位置添加特效
                        local fx = SpawnPrefab("cane_candy_fx")
                        if fx then
                            fx.Transform:SetPosition(treasure_x, 0.5, treasure_z)
                            fx:DoTaskInTime(5, function() fx:Remove() end)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我感觉附近有宝藏！")
                        end
                    end
                end
            end)
            
            return function()
                if treasure_task then
                    treasure_task:Cancel()
                    DebugLog(3, "清理宝藏探测效果")
                end
            end
        end
    },
    {
        id = "BUFF_023",
        name = "火焰之友",
        description = "免疫火焰伤害，走路时留下火焰痕迹",
        fn = function(player)
            -- 免疫火焰伤害
            player:AddTag("fireimmune")
            
            -- 走路时留下火焰痕迹
            local fire_trail_task = player:DoPeriodicTask(0.5, function()
                if player:IsValid() and player:HasTag("moving") then
                    local x, y, z = player.Transform:GetWorldPosition()
                    
                    -- 有几率生成火焰
                    if math.random() < 0.3 then
                        local fire = SpawnPrefab("campfirefire")
                        if fire then
                            fire.Transform:SetPosition(x, 0, z)
                            fire:DoTaskInTime(3, function() fire:Remove() end)
                        end
                    end
                end
            end)
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("fireimmune")
                    if fire_trail_task then
                        fire_trail_task:Cancel()
                    end
                    DebugLog(3, "清理火焰之友效果")
                end
            end
        end
    },
    {
        id = "BUFF_024",
        name = "随机掉落",
        description = "你杀死的生物会掉落随机物品，有可能是稀有物品！",
        fn = function(player)
            local old_onkilledother = player.OnKilledOther
            player.OnKilledOther = function(inst, data)
                if old_onkilledother then
                    old_onkilledother(inst, data)
                end
                
                if data and data.victim then
                    -- 随机物品池
                    local common_items = {"log", "rocks", "flint", "cutgrass", "twigs"}
                    local rare_items = {"gears", "redgem", "bluegem", "purplegem", "orangegem", "yellowgem"}
                    local epic_items = {"cane", "orangestaff", "greenstaff", "yellowstaff", "orangeamulet", "greenamulet"}
                    
                    -- 随机选择物品类型
                    local rand = math.random()
                    local item_pool
                    if rand < 0.7 then
                        item_pool = common_items
                    elseif rand < 0.95 then
                        item_pool = rare_items
                    else
                        item_pool = epic_items
                        if player.components.talker then
                            player.components.talker:Say("噢！这是什么稀有物品？")
                        end
                    end
                    
                    -- 随机选择物品并生成
                    local item_prefab = item_pool[math.random(#item_pool)]
                    local item = SpawnPrefab(item_prefab)
                    if item then
                        local x, y, z = data.victim.Transform:GetWorldPosition()
                        item.Transform:SetPosition(x, y, z)
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnKilledOther = old_onkilledother
                end
                DebugLog(3, "清理随机掉落效果")
            end
        end
    },
    {
        id = "BUFF_025",
        name = "超级跳跃",
        description = "你可以跳得超级高，跳跃时会暂时离开地面！",
        fn = function(player)
            -- 添加跳跃功能
            local jump_ready = true
            local jump_key = _G.KEY_SPACE
            
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_SECONDARY and down and jump_ready then
                    jump_ready = false
                    
                    -- 跳跃效果
                    local jump_height = 5
                    local jump_time = 1
                    local start_time = _G.GetTime()
                    local start_pos = player:GetPosition()
                    
                    player:StartThread(function()
                        while _G.GetTime() - start_time < jump_time do
                            local t = (_G.GetTime() - start_time) / jump_time
                            local height = math.sin(t * math.pi) * jump_height
                            
                            local curr_pos = player:GetPosition()
                            player.Transform:SetPosition(curr_pos.x, height, curr_pos.z)
                            
                            _G.Sleep(_G.FRAMES)
                        end
                        
                        -- 确保回到地面
                        local x, _, z = player.Transform:GetWorldPosition()
                        player.Transform:SetPosition(x, 0, z)
                        
                        -- 跳跃冷却
                        player:DoTaskInTime(0.5, function() 
                            jump_ready = true 
                        end)
                    end)
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("我感觉我能跳到天上去！试试按下右键！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理超级跳跃效果")
            end
        end
    },
    {
        id = "BUFF_026",
        name = "神奇种子",
        description = "你走过的地方有机会长出各种植物和资源！",
        fn = function(player)
            local growables = {"flower", "grass", "sapling", "berrybush", "rock1", "flint"}
            
            local grow_task = player:DoPeriodicTask(2, function()
                if player:IsValid() and player:HasTag("moving") then
                    if math.random() < 0.2 then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local offset = 2
                        local growth_x = x + math.random(-offset, offset)
                        local growth_z = z + math.random(-offset, offset)
                        
                        local prefab = growables[math.random(#growables)]
                        local growth = SpawnPrefab(prefab)
                        if growth then
                            growth.Transform:SetPosition(growth_x, 0, growth_z)
                            
                            -- 添加生长效果
                            local fx = SpawnPrefab("splash_ocean")
                            if fx then
                                fx.Transform:SetPosition(growth_x, 0.5, growth_z)
                                fx:DoTaskInTime(1, function() fx:Remove() end)
                            end
                        end
                    end
                end
            end)
            
            return function()
                if grow_task then
                    grow_task:Cancel()
                end
                DebugLog(3, "清理神奇种子效果")
            end
        end
    },
    {
        id = "BUFF_027",
        name = "材料加倍",
        description = "采集资源时有50%几率获得双倍材料！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                
                if act.doer == player and act.target and act.target.components.pickable and math.random() < 0.5 then
                    -- 尝试再次收获
                    local product = act.target.components.pickable.product
                    if product then
                        local item = SpawnPrefab(product)
                        if item then
                            if item.components.stackable then
                                item.components.stackable:SetStackSize(act.target.components.pickable.numtoharvest or 1)
                            end
                            player.components.inventory:GiveItem(item)
                            
                            if player.components.talker then
                                player.components.talker:Say("额外收获！")
                            end
                        end
                    end
                end
                
                return result
            end
            
            local old_pick = ACTIONS.PICK.fn
            ACTIONS.PICK.fn = function(act)
                local result = old_pick(act)
                
                if act.doer == player and act.target and act.target.components.pickable and math.random() < 0.5 then
                    -- 尝试再次采集
                    local product = act.target.components.pickable.product
                    if product then
                        local item = SpawnPrefab(product)
                        if item then
                            if item.components.stackable then
                                item.components.stackable:SetStackSize(act.target.components.pickable.numtoharvest or 1)
                            end
                            player.components.inventory:GiveItem(item)
                            
                            if player.components.talker then
                                player.components.talker:Say("收获加倍！")
                            end
                        end
                    end
                end
                
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                ACTIONS.PICK.fn = old_pick
                DebugLog(3, "清理材料加倍效果")
            end
        end
    },
    {
        id = "BUFF_028",
        name = "动物语言",
        description = "你获得了和动物交流的能力，小动物不再害怕你！",
        fn = function(player)
            player:AddTag("animal_friend")
            
            -- 动物看到玩家不再害怕
            local old_IsScaredOfCreature = _G.IsScaredOfCreature
            _G.IsScaredOfCreature = function(creature, target)
                if target == player then
                    return false
                end
                return old_IsScaredOfCreature(creature, target)
            end
            
            -- 随机显示动物对话
            local animal_phrases = {
                "你好，人类朋友！",
                "今天天气真好啊！",
                "你能听懂我说话？太神奇了！",
                "我一直在找好吃的，你有吗？",
                "这片森林是我的家，你也住在这里吗？",
                "小心那些怪物，它们很危险！"
            }
            
            local chat_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 10, nil, {"player", "monster"}, {"animal", "rabbit", "bird"})
                    
                    if #animals > 0 then
                        local animal = animals[math.random(#animals)]
                        if animal and animal:IsValid() then
                            local phrase = animal_phrases[math.random(#animal_phrases)]
                            
                            local speech = SpawnPrefab("speech_bubble_saying")
                            if speech then
                                speech.Transform:SetPosition(animal.Transform:GetWorldPosition())
                                speech:SetUp(phrase)
                                speech:DoTaskInTime(2.5, speech.Kill)
                            end
                        end
                    end
                end
            end)
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("animal_friend")
                end
                _G.IsScaredOfCreature = old_IsScaredOfCreature
                if chat_task then
                    chat_task:Cancel()
                end
                DebugLog(3, "清理动物语言效果")
            end
        end
    },
    {
        id = "BUFF_029",
        name = "瞬移能力",
        description = "双击方向键可以向该方向瞬移一段距离！",
        fn = function(player)
            -- 瞬移能力
            local last_click_time = 0
            local last_click_dir = nil
            local teleport_distance = 8
            local teleport_cooldown = 3
            local last_teleport_time = 0
            
            local old_locomotor_update = player.components.locomotor.OnUpdate
            player.components.locomotor.OnUpdate = function(self, dt, ...)
                if old_locomotor_update then
                    old_locomotor_update(self, dt, ...)
                end
                
                local curr_time = _G.GetTime()
                
                -- 检测双击
                local curr_dir = nil
                if self:WantsToMoveForward() then curr_dir = "forward"
                elseif self:WantsToMoveLeft() then curr_dir = "left"
                elseif self:WantsToMoveRight() then curr_dir = "right"
                elseif self:WantsToMoveBack() then curr_dir = "back"
                end
                
                if curr_dir then
                    if curr_dir == last_click_dir and (curr_time - last_click_time) < 0.3 and (curr_time - last_teleport_time) > teleport_cooldown then
                        -- 执行瞬移
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = nil
                        
                        if curr_dir == "forward" then angle = 0
                        elseif curr_dir == "right" then angle = -90
                        elseif curr_dir == "back" then angle = 180
                        elseif curr_dir == "left" then angle = 90
                        end
                        
                        if angle then
                            angle = angle * DEGREES
                            local facing_angle = player.Transform:GetRotation() * DEGREES
                            local final_angle = facing_angle + angle
                            
                            local new_x = x + teleport_distance * math.cos(final_angle)
                            local new_z = z - teleport_distance * math.sin(final_angle)
                            
                            -- 瞬移特效
                            local fx1 = SpawnPrefab("statue_transition")
                            if fx1 then
                                fx1.Transform:SetPosition(x, y, z)
                                fx1:DoTaskInTime(1.5, function() fx1:Remove() end)
                            end
                            
                            -- 执行瞬移
                            player.Physics:Teleport(new_x, 0, new_z)
                            
                            -- 瞬移后特效
                            local fx2 = SpawnPrefab("statue_transition")
                            if fx2 then
                                fx2.Transform:SetPosition(new_x, y, new_z)
                                fx2:DoTaskInTime(1.5, function() fx2:Remove() end)
                            end
                            
                            last_teleport_time = curr_time
                            
                            if player.components.talker then
                                player.components.talker:Say("瞬移！")
                            end
                        end
                    end
                    
                    last_click_time = curr_time
                    last_click_dir = curr_dir
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("试试快速双击方向键瞬移！")
            end
            
            return function()
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.OnUpdate = old_locomotor_update
                end
                DebugLog(3, "清理瞬移能力效果")
            end
        end
    },
    {
        id = "BUFF_030",
        name = "元素护盾",
        description = "你获得了一个元素护盾，可以抵挡伤害并反弹给敌人！",
        fn = function(player)
            -- 创建护盾效果
            local shield = SpawnPrefab("forcefield")
            if shield then
                shield.entity:SetParent(player.entity)
                shield.Transform:SetPosition(0, 0, 0)
                
                -- 修改护盾颜色
                local color = {r = 0.2, g = 0.6, b = 1}
                shield.Light:SetColour(color.r, color.g, color.b)
                
                -- 添加反弹伤害效果
                local old_combat = player.components.combat
                if old_combat then
                    local old_GetAttacked = old_combat.GetAttacked
                    old_combat.GetAttacked = function(self, attacker, damage, ...)
                        if attacker and attacker.components.combat then
                            -- 反弹30%伤害
                            local reflect_damage = damage * 0.3
                            attacker.components.combat:GetAttacked(player, reflect_damage)
                            
                            -- 反弹特效
                            local fx = SpawnPrefab("electric_charged")
                            if fx then
                                local x, y, z = attacker.Transform:GetWorldPosition()
                                fx.Transform:SetPosition(x, y, z)
                            end
                        end
                        return old_GetAttacked(self, attacker, damage, ...)
                    end
                end
                
                return function()
                    if shield and shield:IsValid() then
                        shield:Remove()
                    end
                    if player:IsValid() and player.components.combat then
                        player.components.combat.GetAttacked = old_GetAttacked
                    end
                    DebugLog(3, "清理元素护盾效果")
                end
            end
        end
    },
    {
        id = "BUFF_031",
        name = "资源再生",
        description = "你采集过的资源会在一段时间后重新生长！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                
                if act.doer == player and act.target then
                    local target = act.target
                    -- 记录原始状态
                    local original_state = {
                        prefab = target.prefab,
                        position = target:GetPosition()
                    }
                    
                    -- 一段时间后重新生成
                    target:DoTaskInTime(60, function()
                        if not target:IsValid() then
                            local new_resource = SpawnPrefab(original_state.prefab)
                            if new_resource then
                                new_resource.Transform:SetPosition(original_state.position:Get())
                            end
                        end
                    end)
                end
                
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                DebugLog(3, "清理资源再生效果")
            end
        end
    },
    {
        id = "BUFF_032",
        name = "天气掌控",
        description = "你可以控制周围的天气，让雨停或让雨下！",
        fn = function(player)
            local weather_control = false
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    weather_control = not weather_control
                    if weather_control then
                        -- 停止下雨
                        if _G.TheWorld.components.rain then
                            _G.TheWorld.components.rain:StopRain()
                            if player.components.talker then
                                player.components.talker:Say("雨停了！")
                            end
                        end
                    else
                        -- 开始下雨
                        if _G.TheWorld.components.rain then
                            _G.TheWorld.components.rain:StartRain()
                            if player.components.talker then
                                player.components.talker:Say("下雨了！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键控制天气！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理天气掌控效果")
            end
        end
    },
    {
        id = "BUFF_033",
        name = "动物驯服",
        description = "你可以立即驯服任何动物，让它们成为你的伙伴！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 10, {"animal"}, {"player", "monster"})
                    
                    for _, animal in ipairs(animals) do
                        if animal.components.tameable then
                            animal.components.tameable:Tame()
                            if player.components.talker then
                                player.components.talker:Say("新朋友！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键驯服附近的动物！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物驯服效果")
            end
        end
    },
    {
        id = "BUFF_034",
        name = "物品复制",
        description = "你可以复制手中的物品，获得一个完全相同的副本！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local item = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if item then
                        local copy = SpawnPrefab(item.prefab)
                        if copy then
                            if copy.components.stackable and item.components.stackable then
                                copy.components.stackable:SetStackSize(item.components.stackable.stacksize)
                            end
                            player.components.inventory:GiveItem(copy)
                            if player.components.talker then
                                player.components.talker:Say("复制成功！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键复制手中的物品！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理物品复制效果")
            end
        end
    },
    {
        id = "BUFF_035",
        name = "时间加速",
        description = "你可以让时间加速，加快作物生长和资源再生！",
        fn = function(player)
            local time_speed = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    time_speed = time_speed * 2
                    if time_speed > 4 then time_speed = 1 end
                    
                    -- 修改世界时间流速
                    if _G.TheWorld.components.clock then
                        _G.TheWorld.components.clock:SetTimeScale(time_speed)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("时间流速: " .. time_speed .. "x")
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键调整时间流速！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.clock then
                    _G.TheWorld.components.clock:SetTimeScale(1)
                end
                DebugLog(3, "清理时间加速效果")
            end
        end
    },
    {
        id = "BUFF_036",
        name = "元素召唤",
        description = "你可以召唤元素精灵来帮助你战斗！",
        fn = function(player)
            local elementals = {}
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local elements = {"fire", "ice", "lightning"}
                    local element = elements[math.random(#elements)]
                    
                    local elemental = SpawnPrefab(element .. "_elemental")
                    if elemental then
                        elemental.Transform:SetPosition(x, y, z)
                        if elemental.components.combat then
                            elemental.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 30秒后消失
                        elemental:DoTaskInTime(30, function()
                            if elemental and elemental:IsValid() then
                                elemental:Remove()
                            end
                        end)
                        
                        table.insert(elementals, elemental)
                        
                        if player.components.talker then
                            player.components.talker:Say("元素精灵，现身！")
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键召唤元素精灵！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                for _, elemental in ipairs(elementals) do
                    if elemental and elemental:IsValid() then
                        elemental:Remove()
                    end
                end
                DebugLog(3, "清理元素召唤效果")
            end
        end
    },
    {
        id = "BUFF_037",
        name = "生命共享",
        description = "你可以与其他玩家共享生命值，互相治疗！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local players = TheSim:FindEntities(x, y, z, 10, {"player"}, {"playerghost"})
                    
                    for _, other_player in ipairs(players) do
                        if other_player ~= player and other_player.components.health then
                            -- 平均生命值
                            local my_health = player.components.health.currenthealth
                            local their_health = other_player.components.health.currenthealth
                            local avg_health = (my_health + their_health) / 2
                            
                            player.components.health:SetCurrentHealth(avg_health)
                            other_player.components.health:SetCurrentHealth(avg_health)
                            
                            -- 治疗特效
                            local fx = SpawnPrefab("heal_fx")
                            if fx then
                                fx.entity:SetParent(other_player.entity)
                                fx.Transform:SetPosition(0, 0, 0)
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("生命共享！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键与附近玩家共享生命！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理生命共享效果")
            end
        end
    },
    {
        id = "BUFF_038",
        name = "资源探测",
        description = "你可以探测到附近的资源位置，它们会发出光芒！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local resources = TheSim:FindEntities(x, y, z, 30, {"resource"}, {"INLIMBO"})
                    
                    for _, resource in ipairs(resources) do
                        -- 创建探测标记
                        local marker = SpawnPrefab("minimapicon")
                        if marker then
                            marker.entity:SetParent(resource.entity)
                            marker.Transform:SetPosition(0, 0, 0)
                            
                            -- 5秒后消失
                            marker:DoTaskInTime(5, function()
                                if marker and marker:IsValid() then
                                    marker:Remove()
                                end
                            end)
                        end
                        
                        -- 添加发光效果
                        local light = SpawnPrefab("minerhatlight")
                        if light then
                            light.entity:SetParent(resource.entity)
                            light.Transform:SetPosition(0, 1, 0)
                            light.Light:SetRadius(2)
                            light.Light:SetIntensity(0.8)
                            
                            -- 5秒后消失
                            light:DoTaskInTime(5, function()
                                if light and light:IsValid() then
                                    light:Remove()
                                end
                            end)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("探测到资源！")
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键探测附近资源！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理资源探测效果")
            end
        end
    },
    {
        id = "BUFF_039",
        name = "天气护盾",
        description = "你获得了一个可以抵挡恶劣天气的护盾！",
        fn = function(player)
            -- 创建护盾效果
            local shield = SpawnPrefab("forcefield")
            if shield then
                shield.entity:SetParent(player.entity)
                shield.Transform:SetPosition(0, 0, 0)
                
                -- 修改护盾颜色
                local color = {r = 0.8, g = 0.8, b = 1}
                shield.Light:SetColour(color.r, color.g, color.b)
                
                -- 免疫天气效果
                if player.components.temperature then
                    local old_GetTemp = player.components.temperature.GetTemp
                    player.components.temperature.GetTemp = function(self)
                        return 20 -- 保持舒适温度
                    end
                end
                
                -- 免疫雨雪
                if player.components.moisture then
                    local old_GetMoisture = player.components.moisture.GetMoisture
                    player.components.moisture.GetMoisture = function(self)
                        return 0 -- 保持干燥
                    end
                end
                
                return function()
                    if shield and shield:IsValid() then
                        shield:Remove()
                    end
                    if player:IsValid() then
                        if player.components.temperature then
                            player.components.temperature.GetTemp = old_GetTemp
                        end
                        if player.components.moisture then
                            player.components.moisture.GetMoisture = old_GetMoisture
                        end
                    end
                    DebugLog(3, "清理天气护盾效果")
                end
            end
        end
    },
    {
        id = "BUFF_040",
        name = "幸运之星",
        description = "你获得了幸运之星的祝福，所有行动都有机会获得额外奖励！",
        fn = function(player)
            -- 添加幸运效果
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                -- 随机触发幸运效果
                if math.random() < 0.3 then
                    local effects = {
                        function() -- 恢复生命
                            if player.components.health then
                                player.components.health:DoDelta(5)
                                if player.components.talker then
                                    player.components.talker:Say("幸运之星治愈了我！")
                                end
                            end
                        end,
                        function() -- 恢复理智
                            if player.components.sanity then
                                player.components.sanity:DoDelta(10)
                                if player.components.talker then
                                    player.components.talker:Say("感觉头脑清醒多了！")
                                end
                            end
                        end,
                        function() -- 恢复饥饿
                            if player.components.hunger then
                                player.components.hunger:DoDelta(15)
                                if player.components.talker then
                                    player.components.talker:Say("突然感觉不饿了！")
                                end
                            end
                        end,
                        function() -- 获得随机物品
                            local items = {"goldnugget", "gears", "redgem", "bluegem"}
                            local item = items[math.random(#items)]
                            local new_item = SpawnPrefab(item)
                            if new_item then
                                player.components.inventory:GiveItem(new_item)
                                if player.components.talker then
                                    player.components.talker:Say("幸运之星给了我礼物！")
                                end
                            end
                        end
                    }
                    
                    -- 随机选择一个效果触发
                    effects[math.random(#effects)]()
                end
            end
            
            -- 添加幸运光环
            local star = SpawnPrefab("stafflight")
            if star then
                star.entity:SetParent(player.entity)
                star.Transform:SetPosition(0, 2, 0)
                star.Light:SetColour(1, 1, 0.5)
                star.Light:SetIntensity(0.8)
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if star and star:IsValid() then
                    star:Remove()
                end
                DebugLog(3, "清理幸运之星效果")
            end
        end
    },
    {
        id = "BUFF_041",
        name = "元素共鸣",
        description = "你可以与周围的元素产生共鸣，获得强大的元素能力！",
        fn = function(player)
            -- 创建元素光环
            local elements = {
                {name = "火", color = {r=1, g=0.3, b=0.3}, effect = "fire"},
                {name = "冰", color = {r=0.3, g=0.7, b=1}, effect = "ice"},
                {name = "雷", color = {r=0.8, g=0.8, b=0.2}, effect = "lightning"}
            }
            
            local current_element = elements[math.random(#elements)]
            local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
            
            if fx then
                fx.entity:SetParent(player.entity)
                fx.Transform:SetPosition(0, 0, 0)
                fx.Light:SetColour(current_element.color.r, current_element.color.g, current_element.color.b)
                
                -- 添加元素效果
                local element_task = player:DoPeriodicTask(5, function()
                    if player:IsValid() then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local ents = TheSim:FindEntities(x, y, z, 10, nil, {"INLIMBO"})
                        
                        for _, ent in pairs(ents) do
                            if current_element.effect == "fire" and ent.components.burnable then
                                ent.components.burnable:Ignite()
                            elseif current_element.effect == "ice" and ent.components.freezable then
                                ent.components.freezable:AddColdness(1)
                            elseif current_element.effect == "lightning" and math.random() < 0.3 then
                                TheWorld:PushEvent("ms_sendlightningstrike", Vector3(ent.Transform:GetWorldPosition()))
                            end
                        end
                    end
                end)
                
                return function()
                    if element_task then
                        element_task:Cancel()
                    end
                    if fx and fx:IsValid() then
                        fx:Remove()
                    end
                    DebugLog(3, "清理元素共鸣效果")
                end
            end
        end
    },
    {
        id = "BUFF_042",
        name = "生命之泉",
        description = "你周围会形成一个生命之泉，持续恢复生命值！",
        fn = function(player)
            -- 创建生命之泉效果
            local heal_task = player:DoPeriodicTask(2, function()
                if player:IsValid() and player.components.health then
                    -- 恢复生命值
                    player.components.health:DoDelta(1)
                    
                    -- 创建治疗特效
                    local fx = SpawnPrefab("heal_fx")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    -- 同时治疗周围的玩家
                    local x, y, z = player.Transform:GetWorldPosition()
                    local players = TheSim:FindEntities(x, y, z, 5, {"player"}, {"playerghost"})
                    for _, other_player in pairs(players) do
                        if other_player ~= player and other_player.components.health then
                            other_player.components.health:DoDelta(1)
                        end
                    end
                end
            end)
            
            -- 创建生命之泉视觉效果
            local spring = SpawnPrefab("pond")
            if spring then
                spring.entity:SetParent(player.entity)
                spring.Transform:SetPosition(0, 0, 0)
                
                return function()
                    if heal_task then
                        heal_task:Cancel()
                    end
                    if spring and spring:IsValid() then
                        spring:Remove()
                    end
                    DebugLog(3, "清理生命之泉效果")
                end
            end
        end
    },
    {
        id = "BUFF_043",
        name = "资源之眼",
        description = "你能看到地下埋藏的珍贵资源，并可以轻松挖掘它们！",
        fn = function(player)
            -- 创建资源探测效果
            local detect_task = player:DoPeriodicTask(5, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                    
                    for _, ent in pairs(ents) do
                        if ent:HasTag("buried") or ent:HasTag("underground") then
                            -- 创建标记效果
                            local marker = SpawnPrefab("minimapicon")
                            if marker then
                                marker.entity:SetParent(ent.entity)
                                marker.Transform:SetPosition(0, 0, 0)
                                
                                -- 3秒后消失
                                marker:DoTaskInTime(3, function()
                                    if marker and marker:IsValid() then
                                        marker:Remove()
                                    end
                                end)
                            end
                            
                            -- 自动挖掘
                            if ent.components.workable then
                                ent.components.workable:WorkedBy(player, 1)
                            end
                        end
                    end
                end
            end)
            
            return function()
                if detect_task then
                    detect_task:Cancel()
                end
                DebugLog(3, "清理资源之眼效果")
            end
        end
    },
    {
        id = "BUFF_044",
        name = "动物之王",
        description = "所有动物都会听从你的命令，成为你的忠实伙伴！",
        fn = function(player)
            -- 添加动物控制能力
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 20, {"animal"}, {"player", "monster"})
                    
                    for _, animal in pairs(animals) do
                        -- 让动物跟随玩家
                        if animal.components.follower then
                            animal.components.follower:StartFollowing(player)
                        end
                        
                        -- 让动物攻击玩家的目标
                        if animal.components.combat and player.components.combat and player.components.combat.target then
                            animal.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止动物被攻击
                        if animal.components.health then
                            animal.components.health:SetInvincible(true)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("来吧，我的动物朋友们！")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物之王效果")
            end
        end
    },
    {
        id = "BUFF_045",
        name = "时间掌控",
        description = "你可以控制周围的时间流速，让时间变快或变慢！",
        fn = function(player)
            local time_scale = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    time_scale = time_scale * 2
                    if time_scale > 4 then time_scale = 0.25 end
                    
                    -- 修改时间流速
                    if _G.TheWorld.components.clock then
                        _G.TheWorld.components.clock:SetTimeScale(time_scale)
                    end
                    
                    -- 创建时间效果
                    local fx = SpawnPrefab("statue_transition")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("时间流速: " .. time_scale .. "x")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.clock then
                    _G.TheWorld.components.clock:SetTimeScale(1)
                end
                DebugLog(3, "清理时间掌控效果")
            end
        end
    },
    {
        id = "BUFF_046",
        name = "元素护盾",
        description = "你获得了一个强大的元素护盾，可以抵挡伤害并反弹给敌人！",
        fn = function(player)
            -- 创建护盾效果
            local shield = SpawnPrefab("forcefield")
            if shield then
                shield.entity:SetParent(player.entity)
                shield.Transform:SetPosition(0, 0, 0)
                
                -- 修改护盾颜色
                local color = {r = 0.2, g = 0.6, b = 1}
                shield.Light:SetColour(color.r, color.g, color.b)
                
                -- 添加反弹伤害效果
                local old_combat = player.components.combat
                if old_combat then
                    local old_GetAttacked = old_combat.GetAttacked
                    old_combat.GetAttacked = function(self, attacker, damage, ...)
                        if attacker and attacker.components.combat then
                            -- 反弹50%伤害
                            local reflect_damage = damage * 0.5
                            attacker.components.combat:GetAttacked(player, reflect_damage)
                            
                            -- 反弹特效
                            local fx = SpawnPrefab("electric_charged")
                            if fx then
                                local x, y, z = attacker.Transform:GetWorldPosition()
                                fx.Transform:SetPosition(x, y, z)
                            end
                        end
                        return old_GetAttacked(self, attacker, damage, ...)
                    end
                end
                
                return function()
                    if shield and shield:IsValid() then
                        shield:Remove()
                    end
                    if player:IsValid() and player.components.combat then
                        player.components.combat.GetAttacked = old_GetAttacked
                    end
                    DebugLog(3, "清理元素护盾效果")
                end
            end
        end
    },
    {
        id = "BUFF_047",
        name = "资源再生",
        description = "你采集过的资源会在一段时间后重新生长！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                
                if act.doer == player and act.target then
                    local target = act.target
                    -- 记录原始状态
                    local original_state = {
                        prefab = target.prefab,
                        position = target:GetPosition()
                    }
                    
                    -- 30秒后重新生成
                    target:DoTaskInTime(30, function()
                        if not target:IsValid() then
                            local new_resource = SpawnPrefab(original_state.prefab)
                            if new_resource then
                                new_resource.Transform:SetPosition(original_state.position:Get())
                            end
                        end
                    end)
                end
                
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                DebugLog(3, "清理资源再生效果")
            end
        end
    },
    {
        id = "BUFF_048",
        name = "天气掌控",
        description = "你可以控制周围的天气，让雨停或让雨下！",
        fn = function(player)
            local weather_control = false
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    weather_control = not weather_control
                    if weather_control then
                        -- 停止下雨
                        if _G.TheWorld.components.rain then
                            _G.TheWorld.components.rain:StopRain()
                            if player.components.talker then
                                player.components.talker:Say("雨停了！")
                            end
                        end
                    else
                        -- 开始下雨
                        if _G.TheWorld.components.rain then
                            _G.TheWorld.components.rain:StartRain()
                            if player.components.talker then
                                player.components.talker:Say("下雨了！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键控制天气！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理天气掌控效果")
            end
        end
    },
    {
        id = "BUFF_049",
        name = "动物驯服",
        description = "你可以立即驯服任何动物，让它们成为你的伙伴！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 10, {"animal"}, {"player", "monster"})
                    
                    for _, animal in ipairs(animals) do
                        if animal.components.tameable then
                            animal.components.tameable:Tame()
                            if player.components.talker then
                                player.components.talker:Say("新朋友！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键驯服附近的动物！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物驯服效果")
            end
        end
    },
    {
        id = "BUFF_050",
        name = "物品复制",
        description = "你可以复制手中的物品，获得一个完全相同的副本！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local item = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if item then
                        local copy = SpawnPrefab(item.prefab)
                        if copy then
                            if copy.components.stackable and item.components.stackable then
                                copy.components.stackable:SetStackSize(item.components.stackable.stacksize)
                            end
                            player.components.inventory:GiveItem(copy)
                            if player.components.talker then
                                player.components.talker:Say("复制成功！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键复制手中的物品！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理物品复制效果")
            end
        end
    },
    {
        id = "BUFF_051",
        name = "元素大师",
        description = "你可以同时掌控所有元素，成为真正的元素大师！",
        fn = function(player)
            -- 创建元素光环
            local elements = {
                {name = "火", color = {r=1, g=0.3, b=0.3}, effect = "fire"},
                {name = "冰", color = {r=0.3, g=0.7, b=1}, effect = "ice"},
                {name = "雷", color = {r=0.8, g=0.8, b=0.2}, effect = "lightning"},
                {name = "风", color = {r=0.5, g=0.8, b=0.5}, effect = "wind"}
            }
            
            local element_tasks = {}
            local element_fx = {}
            
            -- 为每个元素创建效果
            for _, element in ipairs(elements) do
                local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                if fx then
                    fx.entity:SetParent(player.entity)
                    fx.Transform:SetPosition(0, 0, 0)
                    fx.Light:SetColour(element.color.r, element.color.g, element.color.b)
                    table.insert(element_fx, fx)
                end
                
                local task = player:DoPeriodicTask(5, function()
                    if player:IsValid() then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local ents = TheSim:FindEntities(x, y, z, 10, nil, {"INLIMBO"})
                        
                        for _, ent in pairs(ents) do
                            if element.effect == "fire" and ent.components.burnable then
                                ent.components.burnable:Ignite()
                            elseif element.effect == "ice" and ent.components.freezable then
                                ent.components.freezable:AddColdness(1)
                            elseif element.effect == "lightning" and math.random() < 0.3 then
                                TheWorld:PushEvent("ms_sendlightningstrike", Vector3(ent.Transform:GetWorldPosition()))
                            elseif element.effect == "wind" then
                                local angle = math.random() * 2 * math.pi
                                local speed = 5
                                local vx = math.cos(angle) * speed
                                local vz = math.sin(angle) * speed
                                ent.Physics:SetVelocity(vx, 0, vz)
                            end
                        end
                    end
                end)
                table.insert(element_tasks, task)
            end
            
            return function()
                for _, task in ipairs(element_tasks) do
                    if task then
                        task:Cancel()
                    end
                end
                for _, fx in ipairs(element_fx) do
                    if fx and fx:IsValid() then
                        fx:Remove()
                    end
                end
                DebugLog(3, "清理元素大师效果")
            end
        end
    },
    {
        id = "BUFF_052",
        name = "生命之源",
        description = "你成为了生命的源泉，可以治愈任何生物！",
        fn = function(player)
            -- 创建治疗光环
            local heal_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                    
                    for _, ent in pairs(ents) do
                        if ent.components.health then
                            -- 恢复生命值
                            ent.components.health:DoDelta(2)
                            
                            -- 创建治疗特效
                            local fx = SpawnPrefab("heal_fx")
                            if fx then
                                fx.Transform:SetPosition(ent.Transform:GetWorldPosition())
                            end
                            
                            -- 移除负面状态
                            if ent.components.freezable then
                                ent.components.freezable:Unfreeze()
                            end
                            if ent.components.burnable and ent.components.burnable:IsBurning() then
                                ent.components.burnable:Extinguish()
                            end
                        end
                    end
                end
            end)
            
            -- 创建生命之源视觉效果
            local source = SpawnPrefab("pond")
            if source then
                source.entity:SetParent(player.entity)
                source.Transform:SetPosition(0, 0, 0)
                
                return function()
                    if heal_task then
                        heal_task:Cancel()
                    end
                    if source and source:IsValid() then
                        source:Remove()
                    end
                    DebugLog(3, "清理生命之源效果")
                end
            end
        end
    },
    {
        id = "BUFF_053",
        name = "资源掌控",
        description = "你可以控制所有资源的生长和采集！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            local old_pick = ACTIONS.PICK.fn
            local old_chop = ACTIONS.CHOP.fn
            local old_mine = ACTIONS.MINE.fn
            
            -- 修改采集行为
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.PICK.fn = function(act)
                local result = old_pick(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.CHOP.fn = function(act)
                local result = old_chop(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.MINE.fn = function(act)
                local result = old_mine(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                ACTIONS.PICK.fn = old_pick
                ACTIONS.CHOP.fn = old_chop
                ACTIONS.MINE.fn = old_mine
                DebugLog(3, "清理资源掌控效果")
            end
        end
    },
    {
        id = "BUFF_054",
        name = "动物统领",
        description = "你可以统领所有动物，让它们为你战斗！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 30, {"animal"}, {"player", "monster"})
                    
                    for _, animal in pairs(animals) do
                        -- 让动物跟随玩家
                        if animal.components.follower then
                            animal.components.follower:StartFollowing(player)
                        end
                        
                        -- 让动物攻击玩家的目标
                        if animal.components.combat and player.components.combat and player.components.combat.target then
                            animal.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 增强动物属性
                        if animal.components.health then
                            animal.components.health:SetInvincible(true)
                            animal.components.health.maxhealth = animal.components.health.maxhealth * 2
                            animal.components.health:DoDelta(animal.components.health.maxhealth)
                        end
                        
                        if animal.components.combat then
                            animal.components.combat.damagemultiplier = 2
                        end
                        
                        -- 添加光环效果
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            fx.entity:SetParent(animal.entity)
                            fx.Transform:SetPosition(0, 0, 0)
                            fx.Light:SetColour(0.5, 0.8, 0.5)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("我的动物军团，出击！")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物统领效果")
            end
        end
    },
    {
        id = "BUFF_055",
        name = "时间主宰",
        description = "你可以完全控制时间，让时间停止或加速！",
        fn = function(player)
            local time_scale = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    time_scale = time_scale * 2
                    if time_scale > 8 then time_scale = 0.125 end
                    
                    -- 修改时间流速
                    if _G.TheWorld.components.clock then
                        _G.TheWorld.components.clock:SetTimeScale(time_scale)
                    end
                    
                    -- 创建时间效果
                    local fx = SpawnPrefab("statue_transition")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("时间流速: " .. time_scale .. "x")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.clock then
                    _G.TheWorld.components.clock:SetTimeScale(1)
                end
                DebugLog(3, "清理时间主宰效果")
            end
        end
    },
    {
        id = "BUFF_056",
        name = "元素护体",
        description = "你获得了一个强大的元素护盾，可以抵挡所有伤害！",
        fn = function(player)
            -- 创建护盾效果
            local shield = SpawnPrefab("forcefield")
            if shield then
                shield.entity:SetParent(player.entity)
                shield.Transform:SetPosition(0, 0, 0)
                
                -- 修改护盾颜色
                local color = {r = 0.2, g = 0.6, b = 1}
                shield.Light:SetColour(color.r, color.g, color.b)
                
                -- 添加反弹伤害效果
                local old_combat = player.components.combat
                if old_combat then
                    local old_GetAttacked = old_combat.GetAttacked
                    old_combat.GetAttacked = function(self, attacker, damage, ...)
                        if attacker and attacker.components.combat then
                            -- 反弹100%伤害
                            local reflect_damage = damage
                            attacker.components.combat:GetAttacked(player, reflect_damage)
                            
                            -- 反弹特效
                            local fx = SpawnPrefab("electric_charged")
                            if fx then
                                local x, y, z = attacker.Transform:GetWorldPosition()
                                fx.Transform:SetPosition(x, y, z)
                            end
                        end
                        return old_GetAttacked(self, attacker, damage, ...)
                    end
                end
                
                return function()
                    if shield and shield:IsValid() then
                        shield:Remove()
                    end
                    if player:IsValid() and player.components.combat then
                        player.components.combat.GetAttacked = old_GetAttacked
                    end
                    DebugLog(3, "清理元素护体效果")
                end
            end
        end
    },
    {
        id = "BUFF_057",
        name = "资源掌控者",
        description = "你可以控制所有资源的生长和采集，并且资源会立即重生！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                
                if act.doer == player and act.target then
                    local target = act.target
                    -- 记录原始状态
                    local original_state = {
                        prefab = target.prefab,
                        position = target:GetPosition()
                    }
                    
                    -- 立即重新生成
                    local new_resource = SpawnPrefab(original_state.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(original_state.position:Get())
                    end
                end
                
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                DebugLog(3, "清理资源掌控者效果")
            end
        end
    },
    {
        id = "BUFF_058",
        name = "天气主宰",
        description = "你可以完全控制天气，让天气随心所欲！",
        fn = function(player)
            local weather_states = {
                {name = "晴天", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StopRain()
                    end
                end},
                {name = "雨天", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StartRain()
                    end
                end},
                {name = "雷暴", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StartRain()
                        _G.TheWorld.components.lightning:StartLightning()
                    end
                end}
            }
            
            local current_state = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    current_state = current_state % #weather_states + 1
                    weather_states[current_state].fn()
                    
                    if player.components.talker then
                        player.components.talker:Say("天气变为" .. weather_states[current_state].name)
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键切换天气！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StopRain()
                end
                DebugLog(3, "清理天气主宰效果")
            end
        end
    },
    {
        id = "BUFF_059",
        name = "动物之王",
        description = "你可以立即驯服任何动物，让它们成为你的忠实伙伴！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 15, {"animal"}, {"player", "monster"})
                    
                    for _, animal in ipairs(animals) do
                        if animal.components.tameable then
                            animal.components.tameable:Tame()
                            -- 增强动物属性
                            if animal.components.health then
                                animal.components.health.maxhealth = animal.components.health.maxhealth * 2
                                animal.components.health:DoDelta(animal.components.health.maxhealth)
                            end
                            if animal.components.combat then
                                animal.components.combat.damagemultiplier = 2
                            end
                            if player.components.talker then
                                player.components.talker:Say("新朋友！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键驯服附近的动物！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物之王效果")
            end
        end
    },
    {
        id = "BUFF_060",
        name = "物品复制大师",
        description = "你可以复制任何物品，获得完全相同的副本！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local item = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if item then
                        local copy = SpawnPrefab(item.prefab)
                        if copy then
                            -- 复制所有属性
                            if copy.components.stackable and item.components.stackable then
                                copy.components.stackable:SetStackSize(item.components.stackable.stacksize)
                            end
                            if copy.components.fueled and item.components.fueled then
                                copy.components.fueled:SetPercent(item.components.fueled:GetPercent())
                            end
                            if copy.components.armor and item.components.armor then
                                copy.components.armor:SetCondition(item.components.armor.condition)
                            end
                            player.components.inventory:GiveItem(copy)
                            if player.components.talker then
                                player.components.talker:Say("复制成功！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键复制手中的物品！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理物品复制大师效果")
            end
        end
    },
    {
        id = "BUFF_061",
        name = "元素掌控者",
        description = "你可以完全掌控所有元素，成为真正的元素掌控者！",
        fn = function(player)
            -- 创建元素光环
            local elements = {
                {name = "火", color = {r=1, g=0.3, b=0.3}, effect = "fire"},
                {name = "冰", color = {r=0.3, g=0.7, b=1}, effect = "ice"},
                {name = "雷", color = {r=0.8, g=0.8, b=0.2}, effect = "lightning"},
                {name = "风", color = {r=0.5, g=0.8, b=0.5}, effect = "wind"},
                {name = "土", color = {r=0.6, g=0.4, b=0.2}, effect = "earth"}
            }
            
            local element_tasks = {}
            local element_fx = {}
            
            -- 为每个元素创建效果
            for _, element in ipairs(elements) do
                local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                if fx then
                    fx.entity:SetParent(player.entity)
                    fx.Transform:SetPosition(0, 0, 0)
                    fx.Light:SetColour(element.color.r, element.color.g, element.color.b)
                    table.insert(element_fx, fx)
                end
                
                local task = player:DoPeriodicTask(3, function()
                    if player:IsValid() then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local ents = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                        
                        for _, ent in pairs(ents) do
                            if element.effect == "fire" and ent.components.burnable then
                                ent.components.burnable:Ignite()
                            elseif element.effect == "ice" and ent.components.freezable then
                                ent.components.freezable:AddColdness(1)
                            elseif element.effect == "lightning" and math.random() < 0.5 then
                                TheWorld:PushEvent("ms_sendlightningstrike", Vector3(ent.Transform:GetWorldPosition()))
                            elseif element.effect == "wind" then
                                local angle = math.random() * 2 * math.pi
                                local speed = 8
                                local vx = math.cos(angle) * speed
                                local vz = math.sin(angle) * speed
                                ent.Physics:SetVelocity(vx, 0, vz)
                            elseif element.effect == "earth" then
                                if ent.components.workable then
                                    ent.components.workable:WorkedBy(player, 1)
                                end
                            end
                        end
                    end
                end)
                table.insert(element_tasks, task)
            end
            
            return function()
                for _, task in ipairs(element_tasks) do
                    if task then
                        task:Cancel()
                    end
                end
                for _, fx in ipairs(element_fx) do
                    if fx and fx:IsValid() then
                        fx:Remove()
                    end
                end
                DebugLog(3, "清理元素掌控者效果")
            end
        end
    },
    {
        id = "BUFF_062",
        name = "生命主宰",
        description = "你成为了生命的主宰，可以治愈任何生物并赋予它们力量！",
        fn = function(player)
            -- 创建治疗光环
            local heal_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 20, nil, {"INLIMBO"})
                    
                    for _, ent in pairs(ents) do
                        if ent.components.health then
                            -- 恢复生命值
                            ent.components.health:DoDelta(3)
                            
                            -- 创建治疗特效
                            local fx = SpawnPrefab("heal_fx")
                            if fx then
                                fx.Transform:SetPosition(ent.Transform:GetWorldPosition())
                            end
                            
                            -- 移除负面状态
                            if ent.components.freezable then
                                ent.components.freezable:Unfreeze()
                            end
                            if ent.components.burnable and ent.components.burnable:IsBurning() then
                                ent.components.burnable:Extinguish()
                            end
                            
                            -- 增强属性
                            if ent.components.combat then
                                ent.components.combat.damagemultiplier = 1.5
                            end
                            if ent.components.locomotor then
                                ent.components.locomotor.walkspeed = ent.components.locomotor.walkspeed * 1.2
                            end
                        end
                    end
                end
            end)
            
            -- 创建生命主宰视觉效果
            local source = SpawnPrefab("pond")
            if source then
                source.entity:SetParent(player.entity)
                source.Transform:SetPosition(0, 0, 0)
                
                return function()
                    if heal_task then
                        heal_task:Cancel()
                    end
                    if source and source:IsValid() then
                        source:Remove()
                    end
                    DebugLog(3, "清理生命主宰效果")
                end
            end
        end
    },
    {
        id = "BUFF_063",
        name = "资源之王",
        description = "你可以控制所有资源的生长和采集，并且资源会立即重生！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            local old_pick = ACTIONS.PICK.fn
            local old_chop = ACTIONS.CHOP.fn
            local old_mine = ACTIONS.MINE.fn
            
            -- 修改采集行为
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.PICK.fn = function(act)
                local result = old_pick(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.CHOP.fn = function(act)
                local result = old_chop(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            ACTIONS.MINE.fn = function(act)
                local result = old_mine(act)
                if act.doer == player and act.target then
                    -- 立即重新生长
                    local new_resource = SpawnPrefab(act.target.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(act.target:GetPosition():Get())
                    end
                end
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                ACTIONS.PICK.fn = old_pick
                ACTIONS.CHOP.fn = old_chop
                ACTIONS.MINE.fn = old_mine
                DebugLog(3, "清理资源之王效果")
            end
        end
    },
    {
        id = "BUFF_064",
        name = "动物统领者",
        description = "你可以统领所有动物，让它们为你战斗并保护你！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 40, {"animal"}, {"player", "monster"})
                    
                    for _, animal in pairs(animals) do
                        -- 让动物跟随玩家
                        if animal.components.follower then
                            animal.components.follower:StartFollowing(player)
                        end
                        
                        -- 让动物攻击玩家的目标
                        if animal.components.combat and player.components.combat and player.components.combat.target then
                            animal.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 增强动物属性
                        if animal.components.health then
                            animal.components.health:SetInvincible(true)
                            animal.components.health.maxhealth = animal.components.health.maxhealth * 3
                            animal.components.health:DoDelta(animal.components.health.maxhealth)
                        end
                        
                        if animal.components.combat then
                            animal.components.combat.damagemultiplier = 3
                        end
                        
                        -- 添加光环效果
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            fx.entity:SetParent(animal.entity)
                            fx.Transform:SetPosition(0, 0, 0)
                            fx.Light:SetColour(0.5, 0.8, 0.5)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("我的动物军团，出击！")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物统领者效果")
            end
        end
    },
    {
        id = "BUFF_065",
        name = "时间掌控者",
        description = "你可以完全控制时间，让时间停止或加速！",
        fn = function(player)
            local time_scale = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    time_scale = time_scale * 2
                    if time_scale > 16 then time_scale = 0.0625 end
                    
                    -- 修改时间流速
                    if _G.TheWorld.components.clock then
                        _G.TheWorld.components.clock:SetTimeScale(time_scale)
                    end
                    
                    -- 创建时间效果
                    local fx = SpawnPrefab("statue_transition")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("时间流速: " .. time_scale .. "x")
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.clock then
                    _G.TheWorld.components.clock:SetTimeScale(1)
                end
                DebugLog(3, "清理时间掌控者效果")
            end
        end
    },
    {
        id = "BUFF_066",
        name = "元素护体大师",
        description = "你获得了一个强大的元素护盾，可以抵挡所有伤害并反弹！",
        fn = function(player)
            -- 创建护盾效果
            local shield = SpawnPrefab("forcefield")
            if shield then
                shield.entity:SetParent(player.entity)
                shield.Transform:SetPosition(0, 0, 0)
                
                -- 修改护盾颜色
                local color = {r = 0.2, g = 0.6, b = 1}
                shield.Light:SetColour(color.r, color.g, color.b)
                
                -- 添加反弹伤害效果
                local old_combat = player.components.combat
                if old_combat then
                    local old_GetAttacked = old_combat.GetAttacked
                    old_combat.GetAttacked = function(self, attacker, damage, ...)
                        if attacker and attacker.components.combat then
                            -- 反弹200%伤害
                            local reflect_damage = damage * 2
                            attacker.components.combat:GetAttacked(player, reflect_damage)
                            
                            -- 反弹特效
                            local fx = SpawnPrefab("electric_charged")
                            if fx then
                                local x, y, z = attacker.Transform:GetWorldPosition()
                                fx.Transform:SetPosition(x, y, z)
                            end
                        end
                        return old_GetAttacked(self, attacker, damage, ...)
                    end
                end
                
                return function()
                    if shield and shield:IsValid() then
                        shield:Remove()
                    end
                    if player:IsValid() and player.components.combat then
                        player.components.combat.GetAttacked = old_GetAttacked
                    end
                    DebugLog(3, "清理元素护体大师效果")
                end
            end
        end
    },
    {
        id = "BUFF_067",
        name = "资源掌控大师",
        description = "你可以控制所有资源的生长和采集，并且资源会立即重生！",
        fn = function(player)
            local old_harvest = ACTIONS.HARVEST.fn
            ACTIONS.HARVEST.fn = function(act)
                local result = old_harvest(act)
                
                if act.doer == player and act.target then
                    local target = act.target
                    -- 记录原始状态
                    local original_state = {
                        prefab = target.prefab,
                        position = target:GetPosition()
                    }
                    
                    -- 立即重新生成
                    local new_resource = SpawnPrefab(original_state.prefab)
                    if new_resource then
                        new_resource.Transform:SetPosition(original_state.position:Get())
                    end
                end
                
                return result
            end
            
            return function()
                ACTIONS.HARVEST.fn = old_harvest
                DebugLog(3, "清理资源掌控大师效果")
            end
        end
    },
    {
        id = "BUFF_068",
        name = "天气掌控大师",
        description = "你可以完全控制天气，让天气随心所欲！",
        fn = function(player)
            local weather_states = {
                {name = "晴天", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StopRain()
                    end
                end},
                {name = "雨天", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StartRain()
                    end
                end},
                {name = "雷暴", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StartRain()
                        _G.TheWorld.components.lightning:StartLightning()
                    end
                end},
                {name = "暴风雪", fn = function() 
                    if _G.TheWorld.components.rain then
                        _G.TheWorld.components.rain:StartRain()
                        _G.TheWorld.components.snow:StartSnow()
                    end
                end}
            }
            
            local current_state = 1
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    current_state = current_state % #weather_states + 1
                    weather_states[current_state].fn()
                    
                    if player.components.talker then
                        player.components.talker:Say("天气变为" .. weather_states[current_state].name)
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键切换天气！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                if _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StopRain()
                end
                DebugLog(3, "清理天气掌控大师效果")
            end
        end
    },
    {
        id = "BUFF_069",
        name = "动物之王大师",
        description = "你可以立即驯服任何动物，让它们成为你的忠实伙伴！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local animals = TheSim:FindEntities(x, y, z, 20, {"animal"}, {"player", "monster"})
                    
                    for _, animal in ipairs(animals) do
                        if animal.components.tameable then
                            animal.components.tameable:Tame()
                            -- 增强动物属性
                            if animal.components.health then
                                animal.components.health.maxhealth = animal.components.health.maxhealth * 3
                                animal.components.health:DoDelta(animal.components.health.maxhealth)
                            end
                            if animal.components.combat then
                                animal.components.combat.damagemultiplier = 3
                            end
                            if player.components.talker then
                                player.components.talker:Say("新朋友！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键驯服附近的动物！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理动物之王大师效果")
            end
        end
    },
    {
        id = "BUFF_070",
        name = "物品复制大师",
        description = "你可以复制任何物品，获得完全相同的副本！",
        fn = function(player)
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    local item = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if item then
                        local copy = SpawnPrefab(item.prefab)
                        if copy then
                            -- 复制所有属性
                            if copy.components.stackable and item.components.stackable then
                                copy.components.stackable:SetStackSize(item.components.stackable.stacksize)
                            end
                            if copy.components.fueled and item.components.fueled then
                                copy.components.fueled:SetPercent(item.components.fueled:GetPercent())
                            end
                            if copy.components.armor and item.components.armor then
                                copy.components.armor:SetCondition(item.components.armor.condition)
                            end
                            player.components.inventory:GiveItem(copy)
                            if player.components.talker then
                                player.components.talker:Say("复制成功！")
                            end
                        end
                    end
                end
            end
            
            if player.components.talker then
                player.components.talker:Say("按F键复制手中的物品！")
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理物品复制大师效果")
            end
        end
    },
    {
        id = "BUFF_071",
        name = "暗影伙伴",
        description = "暗影生物会主动跟随你，成为你的忠实伙伴！",
        fn = function(player)
            -- 创建暗影生物
            local shadow_creatures = {
                "shadowmerm",
                "shadowtentacle",
                "shadowleech",
                "shadowwaxwell"
            }
            
            local shadows = {}
            local spawn_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    -- 随机选择一个暗影生物
                    local creature = shadow_creatures[math.random(#shadow_creatures)]
                    local shadow = SpawnPrefab(creature)
                    
                    if shadow then
                        local x, y, z = player.Transform:GetWorldPosition()
                        shadow.Transform:SetPosition(x, y, z)
                        
                        -- 让暗影生物跟随玩家
                        if shadow.components.follower then
                            shadow.components.follower:StartFollowing(player)
                        end
                        
                        -- 防止暗影生物攻击玩家
                        if shadow.components.combat then
                            shadow.components.combat:SetTarget(nil)
                        end
                        
                        table.insert(shadows, shadow)
                        
                        -- 最多保持3个暗影生物
                        if #shadows > 3 then
                            local old_shadow = table.remove(shadows, 1)
                            if old_shadow and old_shadow:IsValid() then
                                old_shadow:Remove()
                            end
                        end
                    end
                end
            end)
            
            return function()
                if spawn_task then
                    spawn_task:Cancel()
                end
                for _, shadow in ipairs(shadows) do
                    if shadow and shadow:IsValid() then
                        shadow:Remove()
                    end
                end
                DebugLog(3, "清理暗影伙伴效果")
            end
        end
    },
    {
        id = "BUFF_072",
        name = "远古科技",
        description = "你可以使用远古科技，获得强大的能力！",
        fn = function(player)
            -- 添加远古科技效果
            local old_oncontrol = player.OnControl
            player.OnControl = function(inst, control, down)
                if old_oncontrol then
                    old_oncontrol(inst, control, down)
                end
                
                if control == _G.CONTROL_ACTION and down then
                    -- 随机选择一个远古科技效果
                    local effects = {
                        function() -- 远古护盾
                            local shield = SpawnPrefab("forcefield")
                            if shield then
                                shield.entity:SetParent(player.entity)
                                shield.Transform:SetPosition(0, 0, 0)
                                shield.Light:SetColour(0.5, 0.2, 0.8)
                            end
                        end,
                        function() -- 远古传送
                            local x, y, z = player.Transform:GetWorldPosition()
                            local angle = math.random() * 2 * math.pi
                            local distance = 20
                            local new_x = x + math.cos(angle) * distance
                            local new_z = z + math.sin(angle) * distance
                            player.Transform:SetPosition(new_x, y, new_z)
                        end,
                        function() -- 远古治疗
                            if player.components.health then
                                player.components.health:DoDelta(50)
                                local fx = SpawnPrefab("heal_fx")
                                if fx then
                                    fx.Transform:SetPosition(player.Transform:GetWorldPosition())
                                end
                            end
                        end
                    }
                    
                    effects[math.random(#effects)]()
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnControl = old_oncontrol
                end
                DebugLog(3, "清理远古科技效果")
            end
        end
    },
    {
        id = "BUFF_073",
        name = "月岛之力",
        description = "你获得了月岛的神秘力量，可以控制月亮能量！",
        fn = function(player)
            -- 添加月岛效果
            local moon_task = player:DoPeriodicTask(5, function()
                if player:IsValid() then
                    -- 创建月亮能量效果
                    local fx = SpawnPrefab("moon_altar_light_rays")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    -- 恢复理智值
                    if player.components.sanity then
                        player.components.sanity:DoDelta(5)
                    end
                    
                    -- 增强属性
                    if player.components.combat then
                        player.components.combat.damagemultiplier = 1.5
                    end
                end
            end)
            
            return function()
                if moon_task then
                    moon_task:Cancel()
                end
                DebugLog(3, "清理月岛之力效果")
            end
        end
    },
    {
        id = "BUFF_074",
        name = "蜂后之友",
        description = "你成为了蜂后的朋友，可以控制蜜蜂！",
        fn = function(player)
            -- 添加蜜蜂控制效果
            local bee_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bees = TheSim:FindEntities(x, y, z, 20, {"bee"}, {"player", "monster"})
                    
                    for _, bee in pairs(bees) do
                        -- 让蜜蜂跟随玩家
                        if bee.components.follower then
                            bee.components.follower:StartFollowing(player)
                        end
                        
                        -- 让蜜蜂攻击玩家的目标
                        if bee.components.combat and player.components.combat and player.components.combat.target then
                            bee.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止蜜蜂攻击玩家
                        if bee.components.combat then
                            bee.components.combat:SetTarget(nil)
                        end
                    end
                end
            end)
            
            return function()
                if bee_task then
                    bee_task:Cancel()
                end
                DebugLog(3, "清理蜂后之友效果")
            end
        end
    },
    {
        id = "BUFF_075",
        name = "猪人之王",
        description = "你成为了猪人之王，可以控制所有猪人！",
        fn = function(player)
            -- 添加猪人控制效果
            local pig_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 30, {"pig"}, {"player", "monster"})
                    
                    for _, pig in pairs(pigs) do
                        -- 让猪人跟随玩家
                        if pig.components.follower then
                            pig.components.follower:StartFollowing(player)
                        end
                        
                        -- 让猪人攻击玩家的目标
                        if pig.components.combat and player.components.combat and player.components.combat.target then
                            pig.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止猪人攻击玩家
                        if pig.components.combat then
                            pig.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强猪人属性
                        if pig.components.health then
                            pig.components.health.maxhealth = pig.components.health.maxhealth * 2
                            pig.components.health:DoDelta(pig.components.health.maxhealth)
                        end
                        
                        if pig.components.combat then
                            pig.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if pig_task then
                    pig_task:Cancel()
                end
                DebugLog(3, "清理猪人之王效果")
            end
        end
    },
    {
        id = "BUFF_076",
        name = "鱼人之友",
        description = "你成为了鱼人的朋友，可以在水下呼吸！",
        fn = function(player)
            -- 添加水下呼吸效果
            local old_onupdate = player.OnUpdate
            player.OnUpdate = function(inst, dt)
                if old_onupdate then
                    old_onupdate(inst, dt)
                end
                
                -- 在水下时恢复生命值
                if player:IsValid() and player:GetIsWet() then
                    if player.components.health then
                        player.components.health:DoDelta(1 * dt)
                    end
                    
                    -- 创建水下呼吸特效
                    local fx = SpawnPrefab("bubble")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnUpdate = old_onupdate
                end
                DebugLog(3, "清理鱼人之友效果")
            end
        end
    },
    {
        id = "BUFF_077",
        name = "蜘蛛女王",
        description = "你成为了蜘蛛女王，可以控制所有蜘蛛！",
        fn = function(player)
            -- 添加蜘蛛控制效果
            local spider_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local spiders = TheSim:FindEntities(x, y, z, 30, {"spider"}, {"player", "monster"})
                    
                    for _, spider in pairs(spiders) do
                        -- 让蜘蛛跟随玩家
                        if spider.components.follower then
                            spider.components.follower:StartFollowing(player)
                        end
                        
                        -- 让蜘蛛攻击玩家的目标
                        if spider.components.combat and player.components.combat and player.components.combat.target then
                            spider.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止蜘蛛攻击玩家
                        if spider.components.combat then
                            spider.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强蜘蛛属性
                        if spider.components.health then
                            spider.components.health.maxhealth = spider.components.health.maxhealth * 2
                            spider.components.health:DoDelta(spider.components.health.maxhealth)
                        end
                        
                        if spider.components.combat then
                            spider.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if spider_task then
                    spider_task:Cancel()
                end
                DebugLog(3, "清理蜘蛛女王效果")
            end
        end
    },
    {
        id = "BUFF_078",
        name = "树人守护",
        description = "树人会主动保护你，成为你的守护者！",
        fn = function(player)
            -- 添加树人守护效果
            local treeguard_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    -- 创建树人
                    local treeguard = SpawnPrefab("treeguard")
                    if treeguard then
                        local x, y, z = player.Transform:GetWorldPosition()
                        treeguard.Transform:SetPosition(x, y, z)
                        
                        -- 让树人跟随玩家
                        if treeguard.components.follower then
                            treeguard.components.follower:StartFollowing(player)
                        end
                        
                        -- 让树人攻击玩家的目标
                        if treeguard.components.combat and player.components.combat and player.components.combat.target then
                            treeguard.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止树人攻击玩家
                        if treeguard.components.combat then
                            treeguard.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强树人属性
                        if treeguard.components.health then
                            treeguard.components.health.maxhealth = treeguard.components.health.maxhealth * 2
                            treeguard.components.health:DoDelta(treeguard.components.health.maxhealth)
                        end
                        
                        if treeguard.components.combat then
                            treeguard.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if treeguard_task then
                    treeguard_task:Cancel()
                end
                DebugLog(3, "清理树人守护效果")
            end
        end
    },
    {
        id = "BUFF_079",
        name = "触手之王",
        description = "你可以控制触手，让它们为你战斗！",
        fn = function(player)
            -- 添加触手控制效果
            local tentacle_task = player:DoPeriodicTask(20, function()
                if player:IsValid() then
                    -- 创建触手
                    local tentacle = SpawnPrefab("tentacle")
                    if tentacle then
                        local x, y, z = player.Transform:GetWorldPosition()
                        tentacle.Transform:SetPosition(x, y, z)
                        
                        -- 让触手攻击玩家的目标
                        if tentacle.components.combat and player.components.combat and player.components.combat.target then
                            tentacle.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止触手攻击玩家
                        if tentacle.components.combat then
                            tentacle.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强触手属性
                        if tentacle.components.health then
                            tentacle.components.health.maxhealth = tentacle.components.health.maxhealth * 2
                            tentacle.components.health:DoDelta(tentacle.components.health.maxhealth)
                        end
                        
                        if tentacle.components.combat then
                            tentacle.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if tentacle_task then
                    tentacle_task:Cancel()
                end
                DebugLog(3, "清理触手之王效果")
            end
        end
    },
    {
        id = "BUFF_080",
        name = "鱼人之王",
        description = "你成为了鱼人之王，可以控制所有鱼人！",
        fn = function(player)
            -- 添加鱼人控制效果
            local merm_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 30, {"merm"}, {"player", "monster"})
                    
                    for _, merm in pairs(merms) do
                        -- 让鱼人跟随玩家
                        if merm.components.follower then
                            merm.components.follower:StartFollowing(player)
                        end
                        
                        -- 让鱼人攻击玩家的目标
                        if merm.components.combat and player.components.combat and player.components.combat.target then
                            merm.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止鱼人攻击玩家
                        if merm.components.combat then
                            merm.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强鱼人属性
                        if merm.components.health then
                            merm.components.health.maxhealth = merm.components.health.maxhealth * 2
                            merm.components.health:DoDelta(merm.components.health.maxhealth)
                        end
                        
                        if merm.components.combat then
                            merm.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if merm_task then
                    merm_task:Cancel()
                end
                DebugLog(3, "清理鱼人之王效果")
            end
        end
    },
    {
        id = "BUFF_081",
        name = "兔人之友",
        description = "你成为了兔人的朋友，可以控制所有兔人！",
        fn = function(player)
            -- 添加兔人控制效果
            local bunnyman_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnymans = TheSim:FindEntities(x, y, z, 30, {"bunnyman"}, {"player", "monster"})
                    
                    for _, bunnyman in pairs(bunnymans) do
                        -- 让兔人跟随玩家
                        if bunnyman.components.follower then
                            bunnyman.components.follower:StartFollowing(player)
                        end
                        
                        -- 让兔人攻击玩家的目标
                        if bunnyman.components.combat and player.components.combat and player.components.combat.target then
                            bunnyman.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止兔人攻击玩家
                        if bunnyman.components.combat then
                            bunnyman.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强兔人属性
                        if bunnyman.components.health then
                            bunnyman.components.health.maxhealth = bunnyman.components.health.maxhealth * 2
                            bunnyman.components.health:DoDelta(bunnyman.components.health.maxhealth)
                        end
                        
                        if bunnyman.components.combat then
                            bunnyman.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if bunnyman_task then
                    bunnyman_task:Cancel()
                end
                DebugLog(3, "清理兔人之友效果")
            end
        end
    },
    {
        id = "BUFF_082",
        name = "猪人之友",
        description = "你成为了猪人的朋友，可以控制所有猪人！",
        fn = function(player)
            -- 添加猪人控制效果
            local pigman_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigmans = TheSim:FindEntities(x, y, z, 30, {"pigman"}, {"player", "monster"})
                    
                    for _, pigman in pairs(pigmans) do
                        -- 让猪人跟随玩家
                        if pigman.components.follower then
                            pigman.components.follower:StartFollowing(player)
                        end
                        
                        -- 让猪人攻击玩家的目标
                        if pigman.components.combat and player.components.combat and player.components.combat.target then
                            pigman.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止猪人攻击玩家
                        if pigman.components.combat then
                            pigman.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强猪人属性
                        if pigman.components.health then
                            pigman.components.health.maxhealth = pigman.components.health.maxhealth * 2
                            pigman.components.health:DoDelta(pigman.components.health.maxhealth)
                        end
                        
                        if pigman.components.combat then
                            pigman.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if pigman_task then
                    pigman_task:Cancel()
                end
                DebugLog(3, "清理猪人之友效果")
            end
        end
    },
    {
        id = "BUFF_083",
        name = "鱼人之友",
        description = "你成为了鱼人的朋友，可以控制所有鱼人！",
        fn = function(player)
            -- 添加鱼人控制效果
            local merm_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 30, {"merm"}, {"player", "monster"})
                    
                    for _, merm in pairs(merms) do
                        -- 让鱼人跟随玩家
                        if merm.components.follower then
                            merm.components.follower:StartFollowing(player)
                        end
                        
                        -- 让鱼人攻击玩家的目标
                        if merm.components.combat and player.components.combat and player.components.combat.target then
                            merm.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止鱼人攻击玩家
                        if merm.components.combat then
                            merm.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强鱼人属性
                        if merm.components.health then
                            merm.components.health.maxhealth = merm.components.health.maxhealth * 2
                            merm.components.health:DoDelta(merm.components.health.maxhealth)
                        end
                        
                        if merm.components.combat then
                            merm.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if merm_task then
                    merm_task:Cancel()
                end
                DebugLog(3, "清理鱼人之友效果")
            end
        end
    },
    {
        id = "BUFF_084",
        name = "兔人之友",
        description = "你成为了兔人的朋友，可以控制所有兔人！",
        fn = function(player)
            -- 添加兔人控制效果
            local bunnyman_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnymans = TheSim:FindEntities(x, y, z, 30, {"bunnyman"}, {"player", "monster"})
                    
                    for _, bunnyman in pairs(bunnymans) do
                        -- 让兔人跟随玩家
                        if bunnyman.components.follower then
                            bunnyman.components.follower:StartFollowing(player)
                        end
                        
                        -- 让兔人攻击玩家的目标
                        if bunnyman.components.combat and player.components.combat and player.components.combat.target then
                            bunnyman.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止兔人攻击玩家
                        if bunnyman.components.combat then
                            bunnyman.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强兔人属性
                        if bunnyman.components.health then
                            bunnyman.components.health.maxhealth = bunnyman.components.health.maxhealth * 2
                            bunnyman.components.health:DoDelta(bunnyman.components.health.maxhealth)
                        end
                        
                        if bunnyman.components.combat then
                            bunnyman.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if bunnyman_task then
                    bunnyman_task:Cancel()
                end
                DebugLog(3, "清理兔人之友效果")
            end
        end
    },
    {
        id = "BUFF_085",
        name = "猪人之友",
        description = "你成为了猪人的朋友，可以控制所有猪人！",
        fn = function(player)
            -- 添加猪人控制效果
            local pigman_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigmans = TheSim:FindEntities(x, y, z, 30, {"pigman"}, {"player", "monster"})
                    
                    for _, pigman in pairs(pigmans) do
                        -- 让猪人跟随玩家
                        if pigman.components.follower then
                            pigman.components.follower:StartFollowing(player)
                        end
                        
                        -- 让猪人攻击玩家的目标
                        if pigman.components.combat and player.components.combat and player.components.combat.target then
                            pigman.components.combat:SetTarget(player.components.combat.target)
                        end
                        
                        -- 防止猪人攻击玩家
                        if pigman.components.combat then
                            pigman.components.combat:SetTarget(nil)
                        end
                        
                        -- 增强猪人属性
                        if pigman.components.health then
                            pigman.components.health.maxhealth = pigman.components.health.maxhealth * 2
                            pigman.components.health:DoDelta(pigman.components.health.maxhealth)
                        end
                        
                        if pigman.components.combat then
                            pigman.components.combat.damagemultiplier = 2
                        end
                    end
                end
            end)
            
            return function()
                if pigman_task then
                    pigman_task:Cancel()
                end
                DebugLog(3, "清理猪人之友效果")
            end
        end
    },
    {
        id = "BUFF_086",
        name = "随机传送",
        description = "你会在随机时间被传送到随机位置！",
        fn = function(player)
            -- 添加随机传送效果
            local teleport_task = player:DoPeriodicTask(math.random(5, 15), function()
                if player:IsValid() then
                    -- 随机选择一个位置
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(10, 30)
                    local new_x = x + math.cos(angle) * distance
                    local new_z = z + math.sin(angle) * distance
                    
                    -- 创建传送特效
                    local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx then
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    -- 传送玩家
                    player.Transform:SetPosition(new_x, y, new_z)
                    
                    -- 创建传送特效
                    local fx2 = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx2 then
                        fx2.Transform:SetPosition(new_x, y, new_z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("哇！我被传送了！")
                    end
                end
            end)
            
            return function()
                if teleport_task then
                    teleport_task:Cancel()
                end
                DebugLog(3, "清理随机传送效果")
            end
        end
    },
    {
        id = "BUFF_087",
        name = "随机变身",
        description = "你会在随机时间变成随机生物！",
        fn = function(player)
            -- 添加随机变身效果
            local transform_task = player:DoPeriodicTask(math.random(10, 20), function()
                if player:IsValid() then
                    -- 随机选择一个生物
                    local creatures = {
                        "pigman",
                        "merm",
                        "bunnyman",
                        "spider",
                        "bee",
                        "tentacle",
                        "treeguard"
                    }
                    
                    local creature = creatures[math.random(#creatures)]
                    
                    -- 创建变身特效
                    local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    -- 变身玩家
                    local new_creature = SpawnPrefab(creature)
                    if new_creature then
                        local x, y, z = player.Transform:GetWorldPosition()
                        new_creature.Transform:SetPosition(x, y, z)
                        
                        -- 保存玩家状态
                        local player_state = {
                            health = player.components.health and player.components.health.currenthealth or 100,
                            sanity = player.components.sanity and player.components.sanity.current or 100,
                            hunger = player.components.hunger and player.components.hunger.current or 100
                        }
                        
                        -- 移除玩家
                        player:Remove()
                        
                        -- 5秒后恢复玩家
                        new_creature:DoTaskInTime(5, function()
                            if new_creature:IsValid() then
                                -- 创建恢复特效
                                local fx2 = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                                if fx2 then
                                    local x, y, z = new_creature.Transform:GetWorldPosition()
                                    fx2.Transform:SetPosition(x, y, z)
                                end
                                
                                -- 恢复玩家
                                local new_player = SpawnPrefab("wilson")
                                if new_player then
                                    local x, y, z = new_creature.Transform:GetWorldPosition()
                                    new_player.Transform:SetPosition(x, y, z)
                                    
                                    -- 恢复玩家状态
                                    if new_player.components.health then
                                        new_player.components.health:SetCurrentHealth(player_state.health)
                                    end
                                    if new_player.components.sanity then
                                        new_player.components.sanity:SetCurrent(player_state.sanity)
                                    end
                                    if new_player.components.hunger then
                                        new_player.components.hunger:SetCurrent(player_state.hunger)
                                    end
                                end
                                
                                -- 移除生物
                                new_creature:Remove()
                            end
                        end)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("哇！我变成了" .. creature .. "！")
                    end
                end
            end)
            
            return function()
                if transform_task then
                    transform_task:Cancel()
                end
                DebugLog(3, "清理随机变身效果")
            end
        end
    },
    {
        id = "BUFF_088",
        name = "随机天气",
        description = "天气会随机变化，让你体验不同的天气！",
        fn = function(player)
            -- 添加随机天气效果
            local weather_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    -- 随机选择一个天气
                    local weathers = {
                        {name = "晴天", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StopRain()
                            end
                        end},
                        {name = "雨天", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                            end
                        end},
                        {name = "雷暴", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                                _G.TheWorld.components.lightning:StartLightning()
                            end
                        end},
                        {name = "暴风雪", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                                _G.TheWorld.components.snow:StartSnow()
                            end
                        end}
                    }
                    
                    local weather = weathers[math.random(#weathers)]
                    weather.fn()
                    
                    if player.components.talker then
                        player.components.talker:Say("天气变成了" .. weather.name .. "！")
                    end
                end
            end)
            
            return function()
                if weather_task then
                    weather_task:Cancel()
                end
                if _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StopRain()
                end
                DebugLog(3, "清理随机天气效果")
            end
        end
    },
    {
        id = "BUFF_089",
        name = "随机物品",
        description = "你会在随机时间获得随机物品！",
        fn = function(player)
            -- 添加随机物品效果
            local item_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个物品
                    local items = {
                        "goldnugget",
                        "gears",
                        "thulecite",
                        "livinglog",
                        "nightmarefuel",
                        "spidergland",
                        "spidereggsack",
                        "beefalowool",
                        "beefalohair",
                        "tentaclespots"
                    }
                    
                    local item = items[math.random(#items)]
                    
                    -- 给予玩家物品
                    local new_item = SpawnPrefab(item)
                    if new_item then
                        player.components.inventory:GiveItem(new_item)
                        
                        -- 创建物品特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. item .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if item_task then
                    item_task:Cancel()
                end
                DebugLog(3, "清理随机物品效果")
            end
        end
    },
    {
        id = "BUFF_090",
        name = "随机生物",
        description = "你会在随机时间遇到随机生物！",
        fn = function(player)
            -- 添加随机生物效果
            local creature_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    -- 随机选择一个生物
                    local creatures = {
                        "pigman",
                        "merm",
                        "bunnyman",
                        "spider",
                        "bee",
                        "tentacle",
                        "treeguard",
                        "deerclops",
                        "bearger",
                        "dragonfly"
                    }
                    
                    local creature = creatures[math.random(#creatures)]
                    
                    -- 创建生物
                    local new_creature = SpawnPrefab(creature)
                    if new_creature then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local distance = math.random(5, 15)
                        local new_x = x + math.cos(angle) * distance
                        local new_z = z + math.sin(angle) * distance
                        
                        new_creature.Transform:SetPosition(new_x, y, new_z)
                        
                        -- 创建生物特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            fx.Transform:SetPosition(new_x, y, new_z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我遇到了" .. creature .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if creature_task then
                    creature_task:Cancel()
                end
                DebugLog(3, "清理随机生物效果")
            end
        end
    },
    {
        id = "BUFF_091",
        name = "随机事件",
        description = "你会在随机时间触发随机事件！",
        fn = function(player)
            -- 添加随机事件效果
            local event_task = player:DoPeriodicTask(math.random(30, 60), function()
                if player:IsValid() then
                    -- 随机选择一个事件
                    local events = {
                        function() -- 地震
                            TheWorld:PushEvent("ms_sendlightningstrike", Vector3(player.Transform:GetWorldPosition()))
                            if player.components.talker then
                                player.components.talker:Say("地震了！")
                            end
                        end,
                        function() -- 火山爆发
                            local x, y, z = player.Transform:GetWorldPosition()
                            local ents = TheSim:FindEntities(x, y, z, 10, nil, {"INLIMBO"})
                            for _, ent in pairs(ents) do
                                if ent.components.burnable then
                                    ent.components.burnable:Ignite()
                                end
                            end
                            if player.components.talker then
                                player.components.talker:Say("火山爆发了！")
                            end
                        end,
                        function() -- 海啸
                            local x, y, z = player.Transform:GetWorldPosition()
                            local ents = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
                            for _, ent in pairs(ents) do
                                if ent.components.locomotor then
                                    local angle = math.random() * 2 * math.pi
                                    local speed = 10
                                    local vx = math.cos(angle) * speed
                                    local vz = math.sin(angle) * speed
                                    ent.Physics:SetVelocity(vx, 0, vz)
                                end
                            end
                            if player.components.talker then
                                player.components.talker:Say("海啸来了！")
                            end
                        end,
                        function() -- 陨石雨
                            local x, y, z = player.Transform:GetWorldPosition()
                            for i = 1, 5 do
                                local angle = math.random() * 2 * math.pi
                                local distance = math.random(5, 15)
                                local new_x = x + math.cos(angle) * distance
                                local new_z = z + math.sin(angle) * distance
                                TheWorld:PushEvent("ms_sendlightningstrike", Vector3(new_x, y, new_z))
                            end
                            if player.components.talker then
                                player.components.talker:Say("陨石雨来了！")
                            end
                        end
                    }
                    
                    events[math.random(#events)]()
                end
            end)
            
            return function()
                if event_task then
                    event_task:Cancel()
                end
                DebugLog(3, "清理随机事件效果")
            end
        end
    },
    {
        id = "BUFF_092",
        name = "随机状态",
        description = "你会在随机时间获得随机状态！",
        fn = function(player)
            -- 添加随机状态效果
            local state_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() then
                    -- 随机选择一个状态
                    local states = {
                        function() -- 无敌
                            if player.components.health then
                                player.components.health:SetInvincible(true)
                                if player.components.talker then
                                    player.components.talker:Say("我无敌了！")
                                end
                            end
                        end,
                        function() -- 隐身
                            if player.components.health then
                                player.components.health:SetInvincible(true)
                                player.AnimState:SetMultColour(0, 0, 0, 0.5)
                                if player.components.talker then
                                    player.components.talker:Say("我隐身了！")
                                end
                            end
                        end,
                        function() -- 加速
                            if player.components.locomotor then
                                player.components.locomotor.walkspeed = player.components.locomotor.walkspeed * 2
                                if player.components.talker then
                                    player.components.talker:Say("我加速了！")
                                end
                            end
                        end,
                        function() -- 减速
                            if player.components.locomotor then
                                player.components.locomotor.walkspeed = player.components.locomotor.walkspeed * 0.5
                                if player.components.talker then
                                    player.components.talker:Say("我减速了！")
                                end
                            end
                        end,
                        function() -- 变大
                            if player.components.health then
                                player.components.health:SetMaxHealth(player.components.health.maxhealth * 2)
                                player.components.health:DoDelta(player.components.health.maxhealth)
                                player.Transform:SetScale(2, 2, 2)
                                if player.components.talker then
                                    player.components.talker:Say("我变大了！")
                                end
                            end
                        end,
                        function() -- 变小
                            if player.components.health then
                                player.components.health:SetMaxHealth(player.components.health.maxhealth * 0.5)
                                player.components.health:DoDelta(player.components.health.maxhealth)
                                player.Transform:SetScale(0.5, 0.5, 0.5)
                                if player.components.talker then
                                    player.components.talker:Say("我变小了！")
                                end
                            end
                        end
                    }
                    
                    states[math.random(#states)]()
                    
                    -- 5秒后恢复
                    player:DoTaskInTime(5, function()
                        if player:IsValid() then
                            if player.components.health then
                                player.components.health:SetInvincible(false)
                            end
                            if player.components.locomotor then
                                player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                            end
                            player.AnimState:SetMultColour(1, 1, 1, 1)
                            player.Transform:SetScale(1, 1, 1)
                        end
                    end)
                end
            end)
            
            return function()
                if state_task then
                    state_task:Cancel()
                end
                if player:IsValid() then
                    if player.components.health then
                        player.components.health:SetInvincible(false)
                    end
                    if player.components.locomotor then
                        player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                    end
                    player.AnimState:SetMultColour(1, 1, 1, 1)
                    player.Transform:SetScale(1, 1, 1)
                end
                DebugLog(3, "清理随机状态效果")
            end
        end
    },
    {
        id = "BUFF_093",
        name = "随机技能",
        description = "你会在随机时间获得随机技能！",
        fn = function(player)
            -- 添加随机技能效果
            local skill_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    -- 随机选择一个技能
                    local skills = {
                        function() -- 火球术
                            local old_oncontrol = player.OnControl
                            player.OnControl = function(inst, control, down)
                                if old_oncontrol then
                                    old_oncontrol(inst, control, down)
                                end
                                
                                if control == _G.CONTROL_ACTION and down then
                                    local x, y, z = player.Transform:GetWorldPosition()
                                    local angle = player.Transform:GetRotation()
                                    local rad = math.rad(angle)
                                    local vx = math.cos(rad)
                                    local vz = math.sin(rad)
                                    
                                    local fireball = SpawnPrefab("fireball")
                                    if fireball then
                                        fireball.Transform:SetPosition(x, y, z)
                                        fireball.Physics:SetVelocity(vx * 10, 0, vz * 10)
                                    end
                                end
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我学会了火球术！")
                            end
                            
                            -- 5秒后恢复
                            player:DoTaskInTime(5, function()
                                if player:IsValid() then
                                    player.OnControl = old_oncontrol
                                end
                            end)
                        end,
                        function() -- 冰箭术
                            local old_oncontrol = player.OnControl
                            player.OnControl = function(inst, control, down)
                                if old_oncontrol then
                                    old_oncontrol(inst, control, down)
                                end
                                
                                if control == _G.CONTROL_ACTION and down then
                                    local x, y, z = player.Transform:GetWorldPosition()
                                    local angle = player.Transform:GetRotation()
                                    local rad = math.rad(angle)
                                    local vx = math.cos(rad)
                                    local vz = math.sin(rad)
                                    
                                    local iceball = SpawnPrefab("iceball")
                                    if iceball then
                                        iceball.Transform:SetPosition(x, y, z)
                                        iceball.Physics:SetVelocity(vx * 10, 0, vz * 10)
                                    end
                                end
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我学会了冰箭术！")
                            end
                            
                            -- 5秒后恢复
                            player:DoTaskInTime(5, function()
                                if player:IsValid() then
                                    player.OnControl = old_oncontrol
                                end
                            end)
                        end,
                        function() -- 闪电链
                            local old_oncontrol = player.OnControl
                            player.OnControl = function(inst, control, down)
                                if old_oncontrol then
                                    old_oncontrol(inst, control, down)
                                end
                                
                                if control == _G.CONTROL_ACTION and down then
                                    local x, y, z = player.Transform:GetWorldPosition()
                                    local ents = TheSim:FindEntities(x, y, z, 10, nil, {"INLIMBO"})
                                    
                                    for _, ent in pairs(ents) do
                                        if ent.components.combat then
                                            ent.components.combat:GetAttacked(player, 20)
                                            local fx = SpawnPrefab("electric_charged")
                                            if fx then
                                                fx.Transform:SetPosition(ent.Transform:GetWorldPosition())
                                            end
                                        end
                                    end
                                end
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我学会了闪电链！")
                            end
                            
                            -- 5秒后恢复
                            player:DoTaskInTime(5, function()
                                if player:IsValid() then
                                    player.OnControl = old_oncontrol
                                end
                            end)
                        end
                    }
                    
                    skills[math.random(#skills)]()
                end
            end)
            
            return function()
                if skill_task then
                    skill_task:Cancel()
                end
                DebugLog(3, "清理随机技能效果")
            end
        end
    },
    {
        id = "BUFF_094",
        name = "随机装备",
        description = "你会在随机时间获得随机装备！",
        fn = function(player)
            -- 添加随机装备效果
            local equip_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个装备
                    local equips = {
                        "armorwood",
                        "armorgrass",
                        "armormarble",
                        "armorslurper",
                        "armorsnurtleshell",
                        "armorruins",
                        "armorskeleton",
                        "armor_sanity",
                        "armor_metalplate",
                        "armor_metalplate_high"
                    }
                    
                    local equip = equips[math.random(#equips)]
                    
                    -- 给予玩家装备
                    local new_equip = SpawnPrefab(equip)
                    if new_equip then
                        player.components.inventory:GiveItem(new_equip)
                        
                        -- 创建装备特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. equip .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if equip_task then
                    equip_task:Cancel()
                end
                DebugLog(3, "清理随机装备效果")
            end
        end
    },
    {
        id = "BUFF_095",
        name = "随机食物",
        description = "你会在随机时间获得随机食物！",
        fn = function(player)
            -- 添加随机食物效果
            local food_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个食物
                    local foods = {
                        "meat",
                        "fish",
                        "froglegs",
                        "monstermeat",
                        "drumstick",
                        "berries",
                        "carrot",
                        "corn",
                        "pumpkin",
                        "watermelon"
                    }
                    
                    local food = foods[math.random(#foods)]
                    
                    -- 给予玩家食物
                    local new_food = SpawnPrefab(food)
                    if new_food then
                        player.components.inventory:GiveItem(new_food)
                        
                        -- 创建食物特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. food .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if food_task then
                    food_task:Cancel()
                end
                DebugLog(3, "清理随机食物效果")
            end
        end
    },
    {
        id = "BUFF_096",
        name = "随机工具",
        description = "你会在随机时间获得随机工具！",
        fn = function(player)
            -- 添加随机工具效果
            local tool_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个工具
                    local tools = {
                        "axe",
                        "pickaxe",
                        "shovel",
                        "hammer",
                        "bugnet",
                        "fishingrod",
                        "goldenaxe",
                        "goldenpickaxe",
                        "goldenshovel",
                        "goldenhammer"
                    }
                    
                    local tool = tools[math.random(#tools)]
                    
                    -- 给予玩家工具
                    local new_tool = SpawnPrefab(tool)
                    if new_tool then
                        player.components.inventory:GiveItem(new_tool)
                        
                        -- 创建工具特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. tool .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if tool_task then
                    tool_task:Cancel()
                end
                DebugLog(3, "清理随机工具效果")
            end
        end
    },
    {
        id = "BUFF_097",
        name = "随机材料",
        description = "你会在随机时间获得随机材料！",
        fn = function(player)
            -- 添加随机材料效果
            local material_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个材料
                    local materials = {
                        "twigs",
                        "cutgrass",
                        "log",
                        "rocks",
                        "goldnugget",
                        "nitre",
                        "flint",
                        "charcoal",
                        "ash",
                        "boneshard"
                    }
                    
                    local material = materials[math.random(#materials)]
                    
                    -- 给予玩家材料
                    local new_material = SpawnPrefab(material)
                    if new_material then
                        player.components.inventory:GiveItem(new_material)
                        
                        -- 创建材料特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. material .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if material_task then
                    material_task:Cancel()
                end
                DebugLog(3, "清理随机材料效果")
            end
        end
    },
    {
        id = "BUFF_098",
        name = "随机宝石",
        description = "你会在随机时间获得随机宝石！",
        fn = function(player)
            -- 添加随机宝石效果
            local gem_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() and player.components.inventory then
                    -- 随机选择一个宝石
                    local gems = {
                        "redgem",
                        "bluegem",
                        "greengem",
                        "yellowgem",
                        "orangegem",
                        "purplegem"
                    }
                    
                    local gem = gems[math.random(#gems)]
                    
                    -- 给予玩家宝石
                    local new_gem = SpawnPrefab(gem)
                    if new_gem then
                        player.components.inventory:GiveItem(new_gem)
                        
                        -- 创建宝石特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            local x, y, z = player.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我获得了" .. gem .. "！")
                        end
                    end
                end
            end)
            
            return function()
                if gem_task then
                    gem_task:Cancel()
                end
                DebugLog(3, "清理随机宝石效果")
            end
        end
    },
    {
        id = "BUFF_099",
        name = "随机魔法",
        description = "你会在随机时间获得随机魔法！",
        fn = function(player)
            -- 添加随机魔法效果
            local magic_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    -- 随机选择一个魔法
                    local magics = {
                        function() -- 治疗魔法
                            if player.components.health then
                                player.components.health:DoDelta(50)
                                local fx = SpawnPrefab("heal_fx")
                                if fx then
                                    local x, y, z = player.Transform:GetWorldPosition()
                                    fx.Transform:SetPosition(x, y, z)
                                end
                                if player.components.talker then
                                    player.components.talker:Say("我使用了治疗魔法！")
                                end
                            end
                        end,
                        function() -- 传送魔法
                            local x, y, z = player.Transform:GetWorldPosition()
                            local angle = math.random() * 2 * math.pi
                            local distance = math.random(10, 30)
                            local new_x = x + math.cos(angle) * distance
                            local new_z = z + math.sin(angle) * distance
                            
                            local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                            if fx then
                                fx.Transform:SetPosition(x, y, z)
                            end
                            
                            player.Transform:SetPosition(new_x, y, new_z)
                            
                            local fx2 = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                            if fx2 then
                                fx2.Transform:SetPosition(new_x, y, new_z)
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我使用了传送魔法！")
                            end
                        end,
                        function() -- 火球魔法
                            local x, y, z = player.Transform:GetWorldPosition()
                            local angle = player.Transform:GetRotation()
                            local rad = math.rad(angle)
                            local vx = math.cos(rad)
                            local vz = math.sin(rad)
                            
                            local fireball = SpawnPrefab("fireball")
                            if fireball then
                                fireball.Transform:SetPosition(x, y, z)
                                fireball.Physics:SetVelocity(vx * 10, 0, vz * 10)
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我使用了火球魔法！")
                            end
                        end,
                        function() -- 冰箭魔法
                            local x, y, z = player.Transform:GetWorldPosition()
                            local angle = player.Transform:GetRotation()
                            local rad = math.rad(angle)
                            local vx = math.cos(rad)
                            local vz = math.sin(rad)
                            
                            local iceball = SpawnPrefab("iceball")
                            if iceball then
                                iceball.Transform:SetPosition(x, y, z)
                                iceball.Physics:SetVelocity(vx * 10, 0, vz * 10)
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我使用了冰箭魔法！")
                            end
                        end,
                        function() -- 闪电魔法
                            local x, y, z = player.Transform:GetWorldPosition()
                            local ents = TheSim:FindEntities(x, y, z, 10, nil, {"INLIMBO"})
                            
                            for _, ent in pairs(ents) do
                                if ent.components.combat then
                                    ent.components.combat:GetAttacked(player, 20)
                                    local fx = SpawnPrefab("electric_charged")
                                    if fx then
                                        fx.Transform:SetPosition(ent.Transform:GetWorldPosition())
                                    end
                                end
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我使用了闪电魔法！")
                            end
                        end
                    }
                    
                    magics[math.random(#magics)]()
                end
            end)
            
            return function()
                if magic_task then
                    magic_task:Cancel()
                end
                DebugLog(3, "清理随机魔法效果")
            end
        end
    },
    {
        id = "BUFF_100",
        name = "随机惊喜",
        description = "你会在随机时间获得随机惊喜！",
        fn = function(player)
            -- 添加随机惊喜效果
            local surprise_task = player:DoPeriodicTask(math.random(30, 60), function()
                if player:IsValid() then
                    -- 随机选择一个惊喜
                    local surprises = {
                        function() -- 生命恢复
                            if player.components.health then
                                player.components.health:DoDelta(100)
                                local fx = SpawnPrefab("heal_fx")
                                if fx then
                                    local x, y, z = player.Transform:GetWorldPosition()
                                    fx.Transform:SetPosition(x, y, z)
                                end
                                if player.components.talker then
                                    player.components.talker:Say("我恢复了100点生命值！")
                                end
                            end
                        end,
                        function() -- 理智恢复
                            if player.components.sanity then
                                player.components.sanity:DoDelta(100)
                                if player.components.talker then
                                    player.components.talker:Say("我恢复了100点理智值！")
                                end
                            end
                        end,
                        function() -- 饥饿恢复
                            if player.components.hunger then
                                player.components.hunger:DoDelta(100)
                                if player.components.talker then
                                    player.components.talker:Say("我恢复了100点饥饿值！")
                                end
                            end
                        end,
                        function() -- 获得黄金
                            if player.components.inventory then
                                local gold = SpawnPrefab("goldnugget")
                                if gold then
                                    player.components.inventory:GiveItem(gold, 10)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了10个黄金！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得宝石
                            if player.components.inventory then
                                local gems = {"redgem", "bluegem", "greengem", "yellowgem", "orangegem", "purplegem"}
                                local gem = gems[math.random(#gems)]
                                local new_gem = SpawnPrefab(gem)
                                if new_gem then
                                    player.components.inventory:GiveItem(new_gem, 5)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了5个" .. gem .. "！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得装备
                            if player.components.inventory then
                                local equips = {"armorwood", "armorgrass", "armormarble", "armorslurper", "armorsnurtleshell", "armoruins", "armorskeleton", "armor_sanity", "armor_metalplate", "armor_metalplate_high"}
                                local equip = equips[math.random(#equips)]
                                local new_equip = SpawnPrefab(equip)
                                if new_equip then
                                    player.components.inventory:GiveItem(new_equip)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了" .. equip .. "！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得食物
                            if player.components.inventory then
                                local foods = {"meat", "fish", "froglegs", "monstermeat", "drumstick", "berries", "carrot", "corn", "pumpkin", "watermelon"}
                                local food = foods[math.random(#foods)]
                                local new_food = SpawnPrefab(food)
                                if new_food then
                                    player.components.inventory:GiveItem(new_food, 5)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了5个" .. food .. "！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得工具
                            if player.components.inventory then
                                local tools = {"axe", "pickaxe", "shovel", "hammer", "bugnet", "fishingrod", "goldenaxe", "goldenpickaxe", "goldenshovel", "goldenhammer"}
                                local tool = tools[math.random(#tools)]
                                local new_tool = SpawnPrefab(tool)
                                if new_tool then
                                    player.components.inventory:GiveItem(new_tool)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了" .. tool .. "！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得材料
                            if player.components.inventory then
                                local materials = {"twigs", "cutgrass", "log", "rocks", "goldnugget", "nitre", "flint", "charcoal", "ash", "boneshard"}
                                local material = materials[math.random(#materials)]
                                local new_material = SpawnPrefab(material)
                                if new_material then
                                    player.components.inventory:GiveItem(new_material, 10)
                                    if player.components.talker then
                                        player.components.talker:Say("我获得了10个" .. material .. "！")
                                    end
                                end
                            end
                        end,
                        function() -- 获得生物
                            local creatures = {"pigman", "merm", "bunnyman", "spider", "bee", "tentacle", "treeguard"}
                            local creature = creatures[math.random(#creatures)]
                            local new_creature = SpawnPrefab(creature)
                            if new_creature then
                                local x, y, z = player.Transform:GetWorldPosition()
                                new_creature.Transform:SetPosition(x, y, z)
                                
                                if new_creature.components.follower then
                                    new_creature.components.follower:StartFollowing(player)
                                end
                                
                                if player.components.talker then
                                    player.components.talker:Say("我获得了" .. creature .. "！")
                                end
                            end
                        end
                    }
                    
                    surprises[math.random(#surprises)]()
                end
            end)
            
            return function()
                if surprise_task then
                    surprise_task:Cancel()
                end
                DebugLog(3, "清理随机惊喜效果")
            end
        end
    },
    {
        id = "BUFF_101",
        name = "光环生产者",
        description = "你周围散发着柔和的光芒，照亮黑暗...",
        fn = function(player)
            local light = SpawnPrefab("minerhatlight")
            if light then
                light.entity:SetParent(player.entity)
                light.Light:SetRadius(3)
                light.Light:SetFalloff(0.7)
                light.Light:SetIntensity(0.8)
                light.Light:Enable(true)
            end
            
            return function()
                if light then
                    light:Remove()
                end
                DebugLog(3, "清理光环生产者效果")
            end
        end
    },
    {
        id = "BUFF_102",
        name = "荧光皮肤",
        description = "你的皮肤在黑暗中发出柔和的光芒...",
        fn = function(player)
            local fx = SpawnPrefab("wormlight_light")
            if fx then
                fx.entity:SetParent(player.entity)
            end
            
            return function()
                if fx then
                    fx:Remove()
                end
                DebugLog(3, "清理荧光皮肤效果")
            end
        end
    },
    {
        id = "BUFF_103",
        name = "勤劳工蚁",
        description = "你变得更加勤劳，砍树/挖矿效率提升50%！",
        fn = function(player)
            local old_chop = ACTIONS.CHOP.fn
            ACTIONS.CHOP.fn = function(act)
                local result = old_chop(act)
                if act.doer == player and act.target and act.target.components.workable then
                    act.target.components.workable:WorkedBy(player, act.target.components.workable.workleft * 0.5)
                end
                return result
            end
            
            local old_mine = ACTIONS.MINE.fn
            ACTIONS.MINE.fn = function(act)
                local result = old_mine(act)
                if act.doer == player and act.target and act.target.components.workable then
                    act.target.components.workable:WorkedBy(player, act.target.components.workable.workleft * 0.5)
                end
                return result
            end
            
            return function()
                ACTIONS.CHOP.fn = old_chop
                ACTIONS.MINE.fn = old_mine
                DebugLog(3, "清理勤劳工蚁效果")
            end
        end
    },
    {
        id = "BUFF_104",
        name = "美食家",
        description = "你变得更能品尝美食，食物回复效果提升25%！",
        fn = function(player)
            local old_eat = ACTIONS.EAT.fn
            ACTIONS.EAT.fn = function(act)
                local result = old_eat(act)
                if act.doer == player and act.target and act.target.components.edible then
                    local health = act.target.components.edible.healthvalue
                    local hunger = act.target.components.edible.hungervalue
                    local sanity = act.target.components.edible.sanityvalue
                    
                    if health > 0 and player.components.health then
                        player.components.health:DoDelta(health * 0.25)
                    end
                    
                    if hunger > 0 and player.components.hunger then
                        player.components.hunger:DoDelta(hunger * 0.25)
                    end
                    
                    if sanity > 0 and player.components.sanity then
                        player.components.sanity:DoDelta(sanity * 0.25)
                    end
                end
                return result
            end
            
            return function()
                ACTIONS.EAT.fn = old_eat
                DebugLog(3, "清理美食家效果")
            end
        end
    },
    {
        id = "BUFF_105",
        name = "轻盈步伐",
        description = "你的脚步变得轻盈，不受减速地形影响！",
        fn = function(player)
            player:AddTag("snowwalker") -- 雪地不减速
            player:AddTag("roadwalker") -- 道路加速
            player:AddTag("spiderwhisperer") -- 蜘蛛网不减速
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("snowwalker")
                    player:RemoveTag("roadwalker")
                    player:RemoveTag("spiderwhisperer")
                end
                DebugLog(3, "清理轻盈步伐效果")
            end
        end
    },
    {
        id = "BUFF_106",
        name = "灵魂收集者",
        description = "你能收集被杀生物的灵魂，暂时获得它们的能力！",
        fn = function(player)
            local soul_task = nil
            local soul_buff = nil
            
            local old_onkilledother = player.OnKilledOther
            player.OnKilledOther = function(inst, data)
                if old_onkilledother then
                    old_onkilledother(inst, data)
                end
                
                if data and data.victim then
                    -- 移除之前的灵魂效果
                    if soul_task then
                        soul_task:Cancel()
                        soul_task = nil
                    end
                    
                    if soul_buff then
                        soul_buff()
                        soul_buff = nil
                    end
                    
                    -- 根据不同生物给予不同能力
                    local victim = data.victim
                    if victim:HasTag("spider") then
                        -- 蜘蛛能力：蜘蛛不攻击
                        player:AddTag("spiderwhisperer")
                        if player.components.talker then
                            player.components.talker:Say("我获得了蜘蛛的灵魂！")
                        end
                        
                        soul_buff = function()
                            player:RemoveTag("spiderwhisperer")
                        end
                    elseif victim:HasTag("rabbit") then
                        -- 兔子能力：移动速度提升
                        player.components.locomotor:SetExternalSpeedMultiplier(player, "soulbuff", 1.5)
                        if player.components.talker then
                            player.components.talker:Say("我获得了兔子的灵魂！")
                        end
                        
                        soul_buff = function()
                            player.components.locomotor:RemoveExternalSpeedMultiplier(player, "soulbuff")
                        end
                    elseif victim:HasTag("pig") then
                        -- 猪人能力：攻击力提升
                        if player.components.combat then
                            local old_damage = player.components.combat.damagemultiplier or 1
                            player.components.combat.damagemultiplier = old_damage * 1.5
                            if player.components.talker then
                                player.components.talker:Say("我获得了猪人的灵魂！")
                            end
                            
                            soul_buff = function()
                                player.components.combat.damagemultiplier = old_damage
                            end
                        end
                    elseif victim:HasTag("bird") then
                        -- 鸟类能力：跳跃能力
                        player:AddTag("jumper")
                        if player.components.talker then
                            player.components.talker:Say("我获得了鸟类的灵魂！")
                        end
                        
                        soul_buff = function()
                            player:RemoveTag("jumper")
                        end
                    end
                    
                    -- 30秒后移除灵魂效果
                    soul_task = player:DoTaskInTime(30, function()
                        if soul_buff then
                            soul_buff()
                            soul_buff = nil
                        end
                        if player.components.talker then
                            player.components.talker:Say("灵魂效果消失了...")
                        end
                    end)
                end
            end
            
            return function()
                player.OnKilledOther = old_onkilledother
                if soul_task then
                    soul_task:Cancel()
                end
                if soul_buff then
                    soul_buff()
                end
                DebugLog(3, "清理灵魂收集者效果")
            end
        end
    },
    {
        id = "BUFF_107",
        name = "雨伞效果",
        description = "你不再惧怕雨水，不会被淋湿！",
        fn = function(player)
            player:AddTag("waterproofer")
            
            local old_GetWaterproofness = player.components.moisture.GetWaterproofness
            player.components.moisture.GetWaterproofness = function(self)
                return 1
            end
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("waterproofer")
                    if player.components.moisture then
                        player.components.moisture.GetWaterproofness = old_GetWaterproofness
                    end
                end
                DebugLog(3, "清理雨伞效果")
            end
        end
    },
    {
        id = "BUFF_108",
        name = "温暖血液",
        description = "你的血液变得温暖，冬季不会结冰！",
        fn = function(player)
            player:AddTag("frostresistant")
            
            local old_temp_fn = player.components.temperature.GetCurrentTemperature
            player.components.temperature.GetCurrentTemperature = function(self)
                local temp = old_temp_fn(self)
                if temp < 5 then
                    return 5 -- 确保温度不会太低
                end
                return temp
            end
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("frostresistant")
                    if player.components.temperature then
                        player.components.temperature.GetCurrentTemperature = old_temp_fn
                    end
                end
                DebugLog(3, "清理温暖血液效果")
            end
        end
    },
    {
        id = "BUFF_109",
        name = "冰爽体质",
        description = "你的体质变得冰爽，夏季不会过热！",
        fn = function(player)
            player:AddTag("heatresistant")
            
            local old_temp_fn = player.components.temperature.GetCurrentTemperature
            player.components.temperature.GetCurrentTemperature = function(self)
                local temp = old_temp_fn(self)
                if temp > 70 then
                    return 70 -- 确保温度不会太高
                end
                return temp
            end
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("heatresistant")
                    if player.components.temperature then
                        player.components.temperature.GetCurrentTemperature = old_temp_fn
                    end
                end
                DebugLog(3, "清理冰爽体质效果")
            end
        end
    },
    {
        id = "BUFF_110",
        name = "弹跳高手",
        description = "你能短暂跳跃，躲避攻击！",
        fn = function(player)
            local jumping = false
            
            local jump_fn = function()
                if jumping then return end
                jumping = true
                
                -- 创建跳跃效果
                local fx = SpawnPrefab("halloween_moonpuff")
                if fx then
                    local x, y, z = player.Transform:GetWorldPosition()
                    fx.Transform:SetPosition(x, y, z)
                end
                
                -- 短暂无敌
                player:AddTag("notarget")
                
                -- 跳跃动画
                local scale = player.Transform:GetScale()
                player:DoTaskInTime(0.1, function() 
                    player.Transform:SetScale(scale*1.2, scale*1.2, scale*1.2) 
                end)
                player:DoTaskInTime(0.2, function() 
                    player.Transform:SetScale(scale*1.4, scale*1.4, scale*1.4) 
                end)
                player:DoTaskInTime(0.3, function() 
                    player.Transform:SetScale(scale*1.2, scale*1.2, scale*1.2) 
                end)
                player:DoTaskInTime(0.4, function() 
                    player.Transform:SetScale(scale, scale, scale) 
                    player:RemoveTag("notarget")
                    jumping = false
                end)
            end
            
            -- 监听受击事件
            player:ListenForEvent("attacked", function(inst, data)
                if math.random() < 0.3 then -- 30%几率触发跳跃
                    jump_fn()
                    if player.components.talker then
                        player.components.talker:Say("跳跃！")
                    end
                end
            end)
            
            -- 添加跳跃按键
            local jumpkey = TheInput:AddKeyUpHandler(KEY_SPACE, jump_fn)
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("notarget")
                    player:RemoveEventCallback("attacked", jump_fn)
                    TheInput:RemoveKeyUpHandler(jumpkey)
                end
                DebugLog(3, "清理弹跳高手效果")
            end
        end
    },
    {
    id = "BUFF_111",
    name = "采集专家",
    description = "你变成了采集专家，从植物中获得双倍资源！",
    fn = function(player)
        local old_pick = ACTIONS.PICK.fn
        ACTIONS.PICK.fn = function(act)
            local result = old_pick(act)
            
            if act.doer == player and act.target and act.target.components.pickable then
                local product = act.target.components.pickable.product
                if product and player.components.inventory then
                    local item = SpawnPrefab(product)
                    if item then
                        player.components.inventory:GiveItem(item)
                        if player.components.talker then
                            player.components.talker:Say("额外收获了" .. product)
                        end
                    end
                end
            end
            
            return result
        end
        
        return function()
            ACTIONS.PICK.fn = old_pick
            DebugLog(3, "清理采集专家效果")
        end
    end
},
{
    id = "BUFF_112",
    name = "节约能手",
    description = "你变成了节约能手，工具耐久消耗减半！",
    fn = function(player)
        local old_chop = ACTIONS.CHOP.fn
        ACTIONS.CHOP.fn = function(act)
            local result = old_chop(act)
            if act.doer == player and act.invobject and act.invobject.components.finiteuses then
                local old_percent = act.invobject.components.finiteuses:GetPercent()
                act.invobject.components.finiteuses:SetPercent(old_percent + 0.01) -- 添加1%耐久度抵消部分消耗
            end
            return result
        end
        
        local old_mine = ACTIONS.MINE.fn
        ACTIONS.MINE.fn = function(act)
            local result = old_mine(act)
            if act.doer == player and act.invobject and act.invobject.components.finiteuses then
                local old_percent = act.invobject.components.finiteuses:GetPercent()
                act.invobject.components.finiteuses:SetPercent(old_percent + 0.01)
            end
            return result
        end
        
        local old_hammer = ACTIONS.HAMMER.fn
        ACTIONS.HAMMER.fn = function(act)
            local result = old_hammer(act)
            if act.doer == player and act.invobject and act.invobject.components.finiteuses then
                local old_percent = act.invobject.components.finiteuses:GetPercent()
                act.invobject.components.finiteuses:SetPercent(old_percent + 0.01)
            end
            return result
        end
        
        return function()
            ACTIONS.CHOP.fn = old_chop
            ACTIONS.MINE.fn = old_mine
            ACTIONS.HAMMER.fn = old_hammer
            DebugLog(3, "清理节约能手效果")
        end
    end
},
{
    id = "BUFF_113",
    name = "蝴蝶朋友",
    description = "蝴蝶被你吸引，环绕着你飞行并提供微弱治疗！",
    fn = function(player)
        local butterflies = {}
        local max_butterflies = 5
        
        local function spawn_butterfly()
            if #butterflies >= max_butterflies then return end
            
            local butterfly = SpawnPrefab("butterfly")
            if butterfly then
                table.insert(butterflies, butterfly)
                
                -- 设置蝴蝶环绕玩家
                local angle = math.random() * 2 * math.pi
                local radius = 2 + math.random()
                local x, y, z = player.Transform:GetWorldPosition()
                butterfly.Transform:SetPosition(x + radius * math.cos(angle), y, z + radius * math.sin(angle))
                
                -- 让蝴蝶跟随玩家
                butterfly:DoPeriodicTask(0.5, function()
                    if not butterfly:IsValid() or not player:IsValid() then return end
                    
                    local px, py, pz = player.Transform:GetWorldPosition()
                    local bx, by, bz = butterfly.Transform:GetWorldPosition()
                    local dist = math.sqrt((px-bx)^2 + (pz-bz)^2)
                    
                    if dist > 10 then
                        -- 如果距离太远，直接传送到玩家附近
                        angle = math.random() * 2 * math.pi
                        radius = 2 + math.random()
                        butterfly.Transform:SetPosition(px + radius * math.cos(angle), py, pz + radius * math.sin(angle))
                    else
                        -- 缓慢跟随玩家
                        local move_x = px + (math.random() - 0.5) * 4
                        local move_z = pz + (math.random() - 0.5) * 4
                        butterfly.Transform:SetPosition(move_x, py, move_z)
                    end
                end)
                
                -- 让蝴蝶治疗玩家
                butterfly:DoPeriodicTask(10, function()
                    if player:IsValid() and player.components.health then
                        player.components.health:DoDelta(1)
                        local fx = SpawnPrefab("honey_heal")
                        if fx then
                            fx.entity:SetParent(player.entity)
                        end
                    end
                end)
            end
        end
        
        -- 初始生成一些蝴蝶
        for i = 1, max_butterflies do
            spawn_butterfly()
        end
        
        -- 定期检查蝴蝶数量，如果减少就重新生成
        local check_task = player:DoPeriodicTask(5, function()
            local valid_butterflies = {}
            for i, butterfly in ipairs(butterflies) do
                if butterfly:IsValid() then
                    table.insert(valid_butterflies, butterfly)
                end
            end
            
            butterflies = valid_butterflies
            
            while #butterflies < max_butterflies do
                spawn_butterfly()
            end
        end)
        
        return function()
            if check_task then
                check_task:Cancel()
            end
            
            for i, butterfly in ipairs(butterflies) do
                if butterfly:IsValid() then
                    butterfly:Remove()
                end
            end
            
            DebugLog(3, "清理蝴蝶朋友效果")
        end
    end
},
{
    id = "BUFF_114",
    name = "蘑菇农夫",
    description = "你周围的蘑菇生长更快！",
    fn = function(player)
        local task = player:DoPeriodicTask(5, function()
            local x, y, z = player.Transform:GetWorldPosition()
            local mushrooms = TheSim:FindEntities(x, y, z, 10, {"mushroom"})
            
            for _, mushroom in ipairs(mushrooms) do
                if mushroom.components.pickable and not mushroom.components.pickable.canbepicked then
                    mushroom.components.pickable.targettime = mushroom.components.pickable.targettime - 30
                    if mushroom.components.pickable.targettime <= GetTime() then
                        mushroom.components.pickable:Regen()
                    end
                end
            end
        end)
        
        -- 有几率在玩家周围生成蘑菇
        local spawn_task = player:DoPeriodicTask(60, function()
            if math.random() < 0.3 then
                local x, y, z = player.Transform:GetWorldPosition()
                local mushroom_types = {"red_mushroom", "green_mushroom", "blue_mushroom"}
                local mushroom_type = mushroom_types[math.random(#mushroom_types)]
                local mushroom = SpawnPrefab(mushroom_type)
                
                if mushroom then
                    local angle = math.random() * 2 * math.pi
                    local radius = 5 + math.random() * 3
                    mushroom.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                    
                    if player.components.talker then
                        player.components.talker:Say("蘑菇生长出来了！")
                    end
                end
            end
        end)
        
        return function()
            if task then
                task:Cancel()
            end
            
            if spawn_task then
                spawn_task:Cancel()
            end
            
            DebugLog(3, "清理蘑菇农夫效果")
        end
    end
},
{
    id = "BUFF_115",
    name = "沙尘暴",
    description = "你移动时会留下沙尘，减缓敌人速度！",
    fn = function(player)
        local last_pos = {x=0, z=0}
        local sandstorm_entities = {}
        
        -- 获取玩家位置
        local x, y, z = player.Transform:GetWorldPosition()
        last_pos.x = x
        last_pos.z = z
        
        -- 定期检查玩家是否移动
        local task = player:DoPeriodicTask(0.5, function()
            local cur_x, cur_y, cur_z = player.Transform:GetWorldPosition()
            local dist = math.sqrt((cur_x - last_pos.x)^2 + (cur_z - last_pos.z)^2)
            
            -- 如果玩家移动了一定距离
            if dist > 1 then
                -- 创建沙尘效果
                local sandstorm = SpawnPrefab("sandstorm")
                if sandstorm then
                    sandstorm.Transform:SetPosition(last_pos.x, 0, last_pos.z)
                    table.insert(sandstorm_entities, sandstorm)
                    
                    -- 让沙尘缓慢消散
                    sandstorm:DoTaskInTime(5, function()
                        if sandstorm:IsValid() then
                            sandstorm:Remove()
                        end
                    end)
                    
                    -- 沙尘减缓敌人速度
                    local ents = TheSim:FindEntities(last_pos.x, 0, last_pos.z, 3, {"_combat"}, {"player", "companion", "INLIMBO"})
                    for _, ent in ipairs(ents) do
                        if ent.components.locomotor then
                            ent.components.locomotor:SetExternalSpeedMultiplier(ent, "sandstorm_debuff", 0.7)
                            
                            -- 5秒后恢复速度
                            ent:DoTaskInTime(5, function()
                                if ent:IsValid() and ent.components.locomotor then
                                    ent.components.locomotor:RemoveExternalSpeedMultiplier(ent, "sandstorm_debuff")
                                end
                            end)
                        end
                    end
                end
                
                -- 更新上一次位置
                last_pos.x = cur_x
                last_pos.z = cur_z
            end
        end)
        
        return function()
            if task then
                task:Cancel()
            end
            
            -- 清理所有沙尘
            for _, sandstorm in ipairs(sandstorm_entities) do
                if sandstorm:IsValid() then
                    sandstorm:Remove()
                end
            end
            
            DebugLog(3, "清理沙尘暴效果")
        end
    end
},
{
    id = "BUFF_116",
    name = "老练猎手",
    description = "你的陷阱捕获效率提升！",
    fn = function(player)
        -- 增强陷阱效果
        local trap_boost_tag = "trap_boost"
        player:AddTag(trap_boost_tag)
        
        -- 监听放置陷阱事件
        local old_ondeploy = ACTIONS.DEPLOY.fn
        ACTIONS.DEPLOY.fn = function(act)
            local result = old_ondeploy(act)
            
            if act.doer == player and act.invobject and 
               (act.invobject.prefab == "trap" or act.invobject.prefab == "birdtrap") then
                if act.pos then
                    local x, y, z = act.pos:Get()
                    local traps = TheSim:FindEntities(x, y, z, 1, {"trap"})
                    
                    for _, trap in ipairs(traps) do
                        if trap.components.trap then
                            -- 增加诱饵价值
                            trap.components.trap.attractradius = trap.components.trap.attractradius * 1.5
                            -- 标记是被增强的陷阱
                            trap:AddTag(trap_boost_tag)
                            
                            if player.components.talker then
                                player.components.talker:Say("这个陷阱被强化了！")
                            end
                        end
                    end
                end
            end
            
            return result
        end
        
        return function()
            player:RemoveTag(trap_boost_tag)
            ACTIONS.DEPLOY.fn = old_ondeploy
            
            -- 恢复所有被增强的陷阱
            local traps = TheSim:FindEntities(0, 0, 0, 1000, {trap_boost_tag})
            for _, trap in ipairs(traps) do
                if trap.components.trap then
                    trap.components.trap.attractradius = trap.components.trap.attractradius / 1.5
                    trap:RemoveTag(trap_boost_tag)
                end
            end
            
            DebugLog(3, "清理老练猎手效果")
        end
    end
},
{
    id = "BUFF_117",
    name = "花朵使者",
    description = "你周围会长出美丽的花朵！",
    fn = function(player)
        local flowers = {}
        local max_flowers = 10
        
        local function spawn_flower()
            if #flowers >= max_flowers then return end
            
            local x, y, z = player.Transform:GetWorldPosition()
            local angle = math.random() * 2 * math.pi
            local radius = 2 + math.random() * 3
            
            local flower = SpawnPrefab("flower")
            if flower then
                table.insert(flowers, flower)
                flower.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                
                -- 一段时间后消失
                flower:DoTaskInTime(300, function()
                    if flower:IsValid() then
                        flower:Remove()
                        for i, f in ipairs(flowers) do
                            if f == flower then
                                table.remove(flowers, i)
                                break
                            end
                        end
                    end
                end)
            end
        end
        
        -- 初始生成一些花
        for i = 1, max_flowers/2 do
            spawn_flower()
        end
        
        -- 定期生成新花
        local spawn_task = player:DoPeriodicTask(30, function()
            spawn_flower()
        end)
        
        -- 花朵带来的理智恢复效果
        local sanity_task = player:DoPeriodicTask(10, function()
            local x, y, z = player.Transform:GetWorldPosition()
            local nearby_flowers = TheSim:FindEntities(x, y, z, 10, {"flower"})
            
            if #nearby_flowers >= 5 and player.components.sanity then
                player.components.sanity:DoDelta(1)
                if player.components.talker and math.random() < 0.3 then
                    player.components.talker:Say("这些花真美！")
                end
            end
        end)
        
        return function()
            if spawn_task then
                spawn_task:Cancel()
            end
            
            if sanity_task then
                sanity_task:Cancel()
            end
            
            for _, flower in ipairs(flowers) do
                if flower:IsValid() then
                    flower:Remove()
                end
            end
            
            DebugLog(3, "清理花朵使者效果")
        end
    end
},
{
    id = "BUFF_118",
    name = "影子模仿者",
    description = "你的影子会模仿你的动作！",
    fn = function(player)
        local shadow = SpawnPrefab("shadowchanneler")
        if shadow then
            shadow:AddTag("notarget") -- 防止被攻击
            shadow:AddTag("notraptrigger") -- 不触发陷阱
            
            -- 跟随玩家
            shadow:DoPeriodicTask(0.1, function()
                if not shadow:IsValid() or not player:IsValid() then return end
                
                local x, y, z = player.Transform:GetWorldPosition()
                local angle = math.random() * 2 * math.pi
                local radius = 1.5
                
                shadow.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                
                -- 模仿玩家动作
                local anim = player.AnimState:GetCurrentAnimation()
                if anim and shadow.AnimState then
                    shadow.AnimState:PlayAnimation(anim)
                    shadow.AnimState:SetTime(player.AnimState:GetCurrentAnimationTime())
                end
            end)
            
            -- 有几率让影子说话
            shadow:DoPeriodicTask(30, function()
                if math.random() < 0.3 and player.components.talker then
                    local messages = {
                        "我是你的影子...",
                        "我会一直跟着你...",
                        "我们是一体的...",
                        "别怕，我只是你的另一面..."
                    }
                    
                    shadow.components.talker:Say(messages[math.random(#messages)])
                end
            end)
        end
        
        return function()
            if shadow and shadow:IsValid() then
                shadow:Remove()
            end
            
            DebugLog(3, "清理影子模仿者效果")
        end
    end
},
{
    id = "BUFF_119",
    name = "树木情人",
    description = "你与树木建立了特殊联系，砍树有几率不消耗树木！",
    fn = function(player)
        -- 监听砍树动作
        local old_chop = ACTIONS.CHOP.fn
        ACTIONS.CHOP.fn = function(act)
            if act.doer == player and act.target and act.target.components.workable and math.random() < 0.3 then
                -- 30%几率不消耗树木
                local old_workleft = act.target.components.workable.workleft
                local result = old_chop(act)
                
                if act.target and act.target:IsValid() and act.target.components.workable then
                    act.target.components.workable.workleft = old_workleft
                    
                    if player.components.talker then
                        player.components.talker:Say("树木原谅了我的伤害！")
                    end
                    
                    -- 创建治愈效果
                    local fx = SpawnPrefab("treeheal")
                    if fx then
                        local x, y, z = act.target.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                end
                
                return result
            else
                return old_chop(act)
            end
        end
        
        -- 树木有几率给予额外礼物
        player:ListenForEvent("finishedwork", function(inst, data)
            if data.target and data.target:HasTag("tree") and math.random() < 0.1 then
                local gifts = {"log", "acorn", "pinecone", "twigs", "petals"}
                local gift = gifts[math.random(#gifts)]
                
                local item = SpawnPrefab(gift)
                if item and player.components.inventory then
                    player.components.inventory:GiveItem(item)
                    
                    if player.components.talker then
                        player.components.talker:Say("树木给了我" .. gift .. "作为礼物！")
                    end
                end
            end
        end)
        
        return function()
            ACTIONS.CHOP.fn = old_chop
            player:RemoveEventCallback("finishedwork")
            
            DebugLog(3, "清理树木情人效果")
        end
    end
},
{
    id = "BUFF_120",
    name = "闪电避雷针",
    description = "你不会被闪电击中，反而会吸收闪电的能量！",
    fn = function(player)
        -- 防止被闪电击中
        player:AddTag("lightningrod")
        
        -- 监听闪电击中事件
        player:ListenForEvent("lightningstrike", function(world, data)
            if data and data.pos then
                local px, py, pz = player.Transform:GetWorldPosition()
                local lx, ly, lz = data.pos:Get()
                local dist = math.sqrt((px-lx)^2 + (pz-lz)^2)
                
                if dist < 10 then
                    -- 吸收闪电能量
                    if player.components.sanity then
                        player.components.sanity:DoDelta(10)
                    end
                    
                    -- 临时提升移动速度
                    player.components.locomotor:SetExternalSpeedMultiplier(player, "lightning_boost", 1.5)
                    
                    player:DoTaskInTime(10, function()
                        player.components.locomotor:RemoveExternalSpeedMultiplier(player, "lightning_boost")
                    end)
                    
                    if player.components.talker then
                        player.components.talker:Say("我吸收了闪电的能量！")
                    end
                    
                    -- 创建闪电效果
                    local fx = SpawnPrefab("electrichitsparks")
                    if fx then
                        fx.entity:SetParent(player.entity)
                    end
                end
            end
        end)
        
        return function()
            player:RemoveTag("lightningrod")
            player.components.locomotor:RemoveExternalSpeedMultiplier(player, "lightning_boost")
            player:RemoveEventCallback("lightningstrike")
            
            DebugLog(3, "清理闪电避雷针效果")
        end
    end
},
{
    id = "BUFF_121",
    name = "自然呼吸",
    description = "你的氧气消耗减少，潜水时间延长！",
    fn = function(player)
        -- 增加氧气容量
        if player.components.oxygen then
            local old_max = player.components.oxygen.max
            player.components.oxygen.max = old_max * 2
            player.components.oxygen:SetPercent(1)
            
            -- 降低氧气消耗
            local old_rate = player.components.oxygen.rate
            player.components.oxygen.rate = old_rate * 0.5
            
            return function()
                if player:IsValid() and player.components.oxygen then
                    player.components.oxygen.max = old_max
                    player.components.oxygen.rate = old_rate
                end
            end
        else
            -- 如果玩家没有氧气组件，则添加潜水标签
            player:AddTag("diver")
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("diver")
                end
            end
        end
    end
},
{
    id = "BUFF_122",
    name = "音乐家",
    description = "你行走时会产生音符效果，吸引友好生物！",
    fn = function(player)
        local last_pos = {x=0, z=0}
        local note_prefabs = {"musical_note"}
        
        -- 获取玩家位置
        local x, y, z = player.Transform:GetWorldPosition()
        last_pos.x = x
        last_pos.z = z
        
        -- 定期检查玩家是否移动
        local task = player:DoPeriodicTask(0.5, function()
            local cur_x, cur_y, cur_z = player.Transform:GetWorldPosition()
            local dist = math.sqrt((cur_x - last_pos.x)^2 + (cur_z - last_pos.z)^2)
            
            -- 如果玩家移动了一定距离
            if dist > 1 then
                -- 创建音符效果
                local note = SpawnPrefab(note_prefabs[math.random(#note_prefabs)])
                if note then

                    note.Transform:SetPosition(cur_x, cur_y + 1, cur_z)
                    
                    -- 让音符上升并消失
                    note:DoTaskInTime(2, function()
                        if note:IsValid() then
                            note:Remove()
                        end
                    end)
                end
                
                -- 吸引附近友好生物
                local ents = TheSim:FindEntities(cur_x, cur_y, cur_z, 20, nil, {"hostile", "INLIMBO"}, {"animal", "character", "critter", "bird"})
                for _, ent in ipairs(ents) do
                    if ent.components.follower and math.random() < 0.1 then
                        ent.components.follower:SetLeader(player)
                        break -- 每次只吸引一个生物
                    end
                end
                
                -- 更新上一次位置
                last_pos.x = cur_x
                last_pos.z = cur_z
            end
        end)
        
        return function()
            if task then
                task:Cancel()
            end
            DebugLog(3, "清理音乐家效果")
        end
    end
},
{
    id = "BUFF_123",
    name = "贮藏大师",
    description = "你是贮藏大师，食物腐烂速度减慢50%！",
    fn = function(player)
        -- 监听获取物品事件
        local function on_item_get(inst, data)
            if data and data.item and data.item.components.perishable then
                -- 减缓腐烂速度
                data.item.components.perishable.perishremainingtime = data.item.components.perishable.perishremainingtime * 1.5
                data.item:AddTag("preserved_by_buff")
            end
        end
        
        player:ListenForEvent("itemget", on_item_get)
        
        -- 处理背包中已有的物品
        if player.components.inventory then
            local items = player.components.inventory:GetItems()
            for _, item in pairs(items) do
                if item.components.perishable and not item:HasTag("preserved_by_buff") then
                    item.components.perishable.perishremainingtime = item.components.perishable.perishremainingtime * 1.5
                    item:AddTag("preserved_by_buff")
                end
            end
            
            -- 处理背包容器中的物品
            local containers = player.components.inventory:GetOpenContainers()
            for container, _ in pairs(containers) do
                if container.components.container then
                    local container_items = container.components.container:GetItems()
                    for _, item in pairs(container_items) do
                        if item.components.perishable and not item:HasTag("preserved_by_buff") then
                            item.components.perishable.perishremainingtime = item.components.perishable.perishremainingtime * 1.5
                            item:AddTag("preserved_by_buff")
                        end
                    end
                end
            end
        end
        
        return function()
            player:RemoveEventCallback("itemget", on_item_get)
            
            -- 恢复已被修改的物品
            if player.components.inventory then
                local items = player.components.inventory:GetItems()
                for _, item in pairs(items) do
                    if item:HasTag("preserved_by_buff") then
                        item:RemoveTag("preserved_by_buff")
                    end
                end
                
                local containers = player.components.inventory:GetOpenContainers()
                for container, _ in pairs(containers) do
                    if container.components.container then
                        local container_items = container.components.container:GetItems()
                        for _, item in pairs(container_items) do
                            if item:HasTag("preserved_by_buff") then
                                item:RemoveTag("preserved_by_buff")
                            end
                        end
                    end
                end
            end
            
            DebugLog(3, "清理贮藏大师效果")
        end
    end
},
{
    id = "BUFF_124",
    name = "幽灵漫步",
    description = "你变得半透明，有几率躲避攻击！",
    fn = function(player)
        -- 让玩家变得半透明
        if player.AnimState then
            player.AnimState:SetMultColour(1, 1, 1, 0.6)
        end
        
        -- 监听受击事件
        local function on_attacked(inst, data)
            if math.random() < 0.3 then -- 30%几率躲避攻击
                if data and data.attacker and data.damage then
                    -- 取消伤害
                    if player.components.health then
                        player.components.health:DoDelta(data.damage)
                    end
                    
                    -- 显示躲避效果
                    local fx = SpawnPrefab("sleep_puff")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("穿越攻击！")
                    end
                    
                    -- 让攻击者困惑
                    if data.attacker.components.combat then
                        data.attacker.components.combat:DropTarget()
                    end
                end
            end
        end
        
        player:ListenForEvent("attacked", on_attacked)
        
        -- 添加幽灵移动效果
        local ghost_task = player:DoPeriodicTask(0.3, function()
            if player:IsValid() and player.components.locomotor:IsMoving() then
                local fx = SpawnPrefab("wortox_soul_spawn")
                if fx then
                    local x, y, z = player.Transform:GetWorldPosition()
                    fx.Transform:SetPosition(x, y, z)
                    fx:DoTaskInTime(1, function()
                        if fx:IsValid() then
                            fx:Remove()
                        end
                    end)
                end
            end
        end)
        
        return function()
            if player:IsValid() then
                player.AnimState:SetMultColour(1, 1, 1, 1)
                player:RemoveEventCallback("attacked", on_attacked)
                
                if ghost_task then
                    ghost_task:Cancel()
                end
            end
            DebugLog(3, "清理幽灵漫步效果")
        end
    end
},
{
    id = "BUFF_125",
    name = "季节适应",
    description = "你对当前季节的负面效果有更强的抵抗力！",
    fn = function(player)
        -- 处理季节相关的负面效果
        if TheWorld.state.iswinter then
            -- 冬季：提高保暖
            if player.components.temperature then
                local old_insulation = player.components.temperature.inherentinsulation or 0
                player.components.temperature.inherentinsulation = old_insulation + 120
                
                return function()
                    if player:IsValid() and player.components.temperature then
                        player.components.temperature.inherentinsulation = old_insulation
                    end
                end
            end
        elseif TheWorld.state.issummer then
            -- 夏季：提高散热
            if player.components.temperature then
                local old_insulation = player.components.temperature.inherentsummerinsulation or 0
                player.components.temperature.inherentsummerinsulation = old_insulation + 120
                
                return function()
                    if player:IsValid() and player.components.temperature then
                        player.components.temperature.inherentsummerinsulation = old_insulation
                    end
                end
            end
        elseif TheWorld.state.isspring then
            -- 春季：雨水抵抗
            player:AddTag("waterproofer")
            
            local old_moisture_rate = player.components.moisture.ratescale
            player.components.moisture.ratescale = old_moisture_rate * 0.5
            
            return function()
                if player:IsValid() then
                    player:RemoveTag("waterproofer")
                    if player.components.moisture then
                        player.components.moisture.ratescale = old_moisture_rate
                    end
                end
            end
        elseif TheWorld.state.isautumn then
            -- 秋季：理智提升
            if player.components.sanity then
                local old_neg_aura_mult = player.components.sanity.neg_aura_mult or 1
                player.components.sanity.neg_aura_mult = old_neg_aura_mult * 0.5
                
                return function()
                    if player:IsValid() and player.components.sanity then
                        player.components.sanity.neg_aura_mult = old_neg_aura_mult
                    end
                end
            end
        end
        
        -- 默认效果
        return function()
            DebugLog(3, "清理季节适应效果")
        end
    end
},
{
    id = "BUFF_126",
    name = "壮硕身躯",
    description = "你的身体变得更加壮硕，可以携带更多物品！",
    fn = function(player)
        if player.components.inventory then
            local old_slots = player.components.inventory.numslots
            player.components.inventory.numslots = old_slots + 4
            
            -- 需要重建背包UI
            if player.HUD and player.HUD.controls and player.HUD.controls.inv then
                player.HUD.controls.inv:Rebuild()
            end
            
            -- 增加负重能力
            if player.components.locomotor then
                player.components.locomotor:SetExternalSpeedMultiplier(player, "strength_buff", 1.1)
            end
            
            return function()
                if player:IsValid() then
                    if player.components.inventory then
                        player.components.inventory.numslots = old_slots
                        if player.HUD and player.HUD.controls and player.HUD.controls.inv then
                            player.HUD.controls.inv:Rebuild()
                        end
                    end
                    
                    if player.components.locomotor then
                        player.components.locomotor:RemoveExternalSpeedMultiplier(player, "strength_buff")
                    end
                end
            end
        end
    end
},
{
    id = "BUFF_127",
    name = "弹性皮肤",
    description = "你的皮肤具有弹性，有几率反弹部分伤害！",
    fn = function(player)
        -- 监听受击事件
        local function on_attacked(inst, data)
            if data and data.attacker and data.damage and math.random() < 0.4 then
                -- 40%几率反弹30%的伤害
                local reflected_damage = data.damage * 0.3
                
                if data.attacker.components.health and data.attacker ~= player then
                    data.attacker.components.health:DoDelta(-reflected_damage)
                    
                    -- 显示反弹效果
                    local fx = SpawnPrefab("splash_spiderweb")
                    if fx then
                        local x, y, z = data.attacker.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("反弹伤害！")
                    end
                end
            end
        end
        
        player:ListenForEvent("attacked", on_attacked)
        
        -- 增加减伤效果
        if player.components.health then
            local old_absorb = player.components.health.absorb or 0
            player.components.health.absorb = old_absorb + 0.1
            
            return function()
                if player:IsValid() then
                    player:RemoveEventCallback("attacked", on_attacked)
                    
                    if player.components.health then
                        player.components.health.absorb = old_absorb
                    end
                end
            end
        else
            return function()
                if player:IsValid() then
                    player:RemoveEventCallback("attacked", on_attacked)
                end
            end
        end
    end
},
{
    id = "BUFF_128",
    name = "宝藏探测器",
    description = "靠近宝藏时你的屏幕会闪烁！",
    fn = function(player)
        local treasures = {
            "blueprint", "redgem", "bluegem", "yellowgem", "greengem", "purplegem", 
            "orangegem", "opalpreciousgem", "moonrocknugget", "moonglass",
            "thulecite", "thulecite_pieces", "nightmare_timepiece"
        }
        
        local last_hint_time = 0
        
        local function is_treasure(item)
            if not item then return false end
            
            for _, treasure in ipairs(treasures) do
                if item.prefab == treasure then
                    return true
                end
            end
            
            return false
        end
        
        local task = player:DoPeriodicTask(1, function()
            local x, y, z = player.Transform:GetWorldPosition()
            local items = TheSim:FindEntities(x, y, z, 15, nil, {"INLIMBO"})
            
            local has_treasure = false
            local treasure_distance = 15
            
            for _, item in ipairs(items) do
                if is_treasure(item) then
                    has_treasure = true
                    
                    -- 计算距离
                    local ix, iy, iz = item.Transform:GetWorldPosition()
                    local dist = math.sqrt((x-ix)^2 + (z-iz)^2)
                    treasure_distance = math.min(treasure_distance, dist)
                end
            end
            
            -- 如果有宝藏，并且上次提示已经过去至少5秒
            if has_treasure and GetTime() - last_hint_time > 5 then
                last_hint_time = GetTime()
                
                -- 根据距离决定提示频率
                local hint_delay = math.max(1, treasure_distance / 3)
                
                -- 闪烁效果
                player:DoTaskInTime(0, function()
                    if player.HUD then
                        player.HUD.vignette:SetVignettePriority(6, 3)
                        player.HUD.vignette:SetVignetteIntensity(6, .7)
                        
                        player:DoTaskInTime(0.2, function()
                            player.HUD.vignette:SetVignetteIntensity(6, 0)
                        end)
                    end
                end)
                
                if treasure_distance < 5 and player.components.talker then
                    player.components.talker:Say("非常接近宝藏！")
                elseif treasure_distance < 10 and player.components.talker then
                    player.components.talker:Say("附近有宝藏...")
                end
            end
        end)
        
        return function()
            if task then
                task:Cancel()
            end
            
            if player:IsValid() and player.HUD then
                player.HUD.vignette:SetVignetteIntensity(6, 0)
            end
            
            DebugLog(3, "清理宝藏探测器效果")
        end
    end
},
{
    id = "BUFF_129",
    name = "生命共享",
    description = "你会缓慢吸收附近队友失去的生命值！",
    fn = function(player)
        local function on_health_delta(target, data)
            if target == player or not data or data.amount >= 0 then return end
            
            -- 队友失去生命值
            local x, y, z = player.Transform:GetWorldPosition()
            local tx, ty, tz = target.Transform:GetWorldPosition()
            local dist = math.sqrt((x-tx)^2 + (z-tz)^2)
            
            -- 在范围内的队友
            if dist < 30 and player.components.health and target.components.health then
                -- 吸收20%的伤害
                local heal_amount = -data.amount * 0.2
                player:DoTaskInTime(1, function()
                    if player:IsValid() and player.components.health then
                        player.components.health:DoDelta(heal_amount)
                        
                        -- 显示治疗效果
                        local fx = SpawnPrefab("lavaarena_heal_projectile")
                        if fx then
                            fx.Transform:SetPosition(tx, ty, tz)
                            fx:DoTaskInTime(0.5, function()
                                if fx:IsValid() then
                                    fx.Transform:SetPosition(x, y, z)
                                end
                            end)
                        end
                        
                        if player.components.talker and math.random() < 0.3 then
                            player.components.talker:Say("我感受到了" .. target.name .. "的痛苦...")
                        end
                    end
                end)
            end
        end
        
        -- 监听所有玩家的生命值变化
        for i, v in ipairs(AllPlayers) do
            if v ~= player then
                v:ListenForEvent("healthdelta", on_health_delta)
            end
        end
        
        return function()
            for i, v in ipairs(AllPlayers) do
                if v ~= player and v:IsValid() then
                    v:RemoveEventCallback("healthdelta", on_health_delta)
                end
            end
            DebugLog(3, "清理生命共享效果")
        end
    end
},
{
    id = "BUFF_130",
    name = "爆发力量",
    description = "你的攻击有几率造成爆发性伤害！",
    fn = function(player)
        -- 修改攻击伤害计算
        if player.components.combat then
            local old_calc_damage = player.components.combat.CalcDamage
            player.components.combat.CalcDamage = function(self, target, weapon, multiplier)
                local damage = old_calc_damage(self, target, weapon, multiplier)
                
                -- 20%几率造成双倍伤害
                if math.random() < 0.2 then
                    -- 显示暴击效果
                    local x, y, z = target.Transform:GetWorldPosition()
                    local fx = SpawnPrefab("explode_small")
                    if fx then
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("暴击！")
                    end
                    
                    return damage * 2
                end
                
                return damage
            end
            
            return function()
                if player:IsValid() and player.components.combat then
                    player.components.combat.CalcDamage = old_calc_damage
                end
            end
        end
    end
},
    {
        id = "BUFF_131",
        name = "雷电引导者",
        description = "你可以引导雷电攻击敌人！",
        fn = function(player)
            -- 添加雷电引导能力
            local lightning_target = nil
            
            -- 监听攻击事件
            local function on_attacked_other(inst, data)
                if data and data.target and data.target.components.health and not data.target:HasTag("player") then
                    lightning_target = data.target
                    
                    -- 30%几率触发雷电
                    if math.random() < 0.3 then
                        local tx, ty, tz = lightning_target.Transform:GetWorldPosition()
                        TheWorld:PushEvent("ms_sendlightningstrike", Vector3(tx, ty, tz))
                        
                        if player.components.talker then
                            player.components.talker:Say("雷霆万钧！")
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked_other)
            
            -- 雷电不会伤害玩家
            player:AddTag("lightningrod")
            
            return function()
                player:RemoveEventCallback("attacked", on_attacked_other)
                player:RemoveTag("lightningrod")
                DebugLog(3, "清理雷电引导者效果")
            end
        end
    },
    {
        id = "BUFF_132",
        name = "植物催生",
        description = "你可以加速植物生长！",
        fn = function(player)
            -- 为玩家添加光环效果
            local aura = SpawnPrefab("moonpulse_fx")
            if aura then
                aura.entity:SetParent(player.entity)
                aura.Transform:SetScale(0.5, 0.5, 0.5)
            end
            
            -- 定期加速周围植物生长
            local task = player:DoPeriodicTask(10, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local plants = TheSim:FindEntities(x, y, z, 8, nil, {"player", "monster"}, {"plant", "crop", "bush", "tree", "sapling"})
                
                local growth_count = 0
                for _, plant in ipairs(plants) do
                    if growth_count >= 3 then break end -- 每次最多催生3个植物
                    
                    local success = false
                    
                    -- 处理作物
                    if plant.components.crop and not plant.components.crop:IsReadyForHarvest() then
                        plant.components.crop:DoGrow(5)
                        success = true
                    -- 处理可采集的植物    
                    elseif plant.components.pickable and not plant.components.pickable.canbepicked then
                        plant.components.pickable.targettime = plant.components.pickable.targettime - 120
                        if plant.components.pickable.targettime <= GetTime() then
                            plant.components.pickable:Regen()
                        end
                        success = true
                    -- 处理树木
                    elseif plant.components.growable and not plant.components.growable:IsFullyGrown() then
                        plant.components.growable:DoGrowth()
                        success = true
                    end
                    
                    if success then
                        growth_count = growth_count + 1
                        -- 生成效果
                        local fx = SpawnPrefab("pollen_fx")
                        if fx then
                            local px, py, pz = plant.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(px, py, pz)
                        end
                    end
                end
                
                if growth_count > 0 and player.components.talker then
                    player.components.talker:Say("我感受到植物的生命在加速流动...")
                end
            end)
            
            return function()
                if aura and aura:IsValid() then
                    aura:Remove()
                end
                
                if task then
                    task:Cancel()
                end
                
                DebugLog(3, "清理植物催生效果")
            end
        end
    },
    {
        id = "BUFF_133",
        name = "危险感知",
        description = "你可以感知危险的靠近！",
        fn = function(player)
            -- 定期检查附近的危险
            local task = player:DoPeriodicTask(5, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local danger_range = 15
                
                -- 检查危险生物
                local monsters = TheSim:FindEntities(x, y, z, danger_range, {"hostile", "_combat"}, {"player", "companion", "wall", "INLIMBO"})
                
                for _, monster in ipairs(monsters) do
                    -- 只检查正在追击的敌人
                    if monster.components.combat and monster.components.combat.target == player then
                        -- 计算距离
                        local mx, my, mz = monster.Transform:GetWorldPosition()
                        local dist = math.sqrt((x-mx)^2 + (z-mz)^2)
                        
                        -- 距离越近警告越强烈
                        if dist < 5 and player.components.talker then
                            player.components.talker:Say("危险就在身边！")
                            
                            -- 屏幕闪红
                            if player.HUD then
                                player.HUD.vignette:SetVignettePriority(5, 3)
                                player.HUD.vignette:SetVignetteIntensity(5, .8)
                                
                                player:DoTaskInTime(0.5, function()
                                    player.HUD.vignette:SetVignetteIntensity(5, 0)
                                end)
                            end
                            
                            -- 只警告一次最近的敌人
                            break
                        elseif dist < 10 and player.components.talker and math.random() < 0.5 then
                            player.components.talker:Say("我感觉有东西在靠近...")
                            break
                        end
                    end
                end
            end)
            
            return function()
                if task then
                    task:Cancel()
                end
                
                if player:IsValid() and player.HUD then
                    player.HUD.vignette:SetVignetteIntensity(5, 0)
                end
                
                DebugLog(3, "清理危险感知效果")
            end
        end
    },
    {
        id = "BUFF_134",
        name = "火焰掌控",
        description = "你可以掌控火焰，并且不会被火伤害！",
        fn = function(player)
            -- 抵抗火焰伤害
            player:AddTag("fireimmune")
            
            -- 增强火焰伤害
            if player.components.combat then
                local old_calc_damage = player.components.combat.CalcDamage
                player.components.combat.CalcDamage = function(self, target, weapon, multiplier)
                    local damage = old_calc_damage(self, target, weapon, multiplier)
                    
                    -- 如果目标是可燃的，增加50%伤害
                    if target.components.burnable or target:HasTag("monster") then
                        return damage * 1.5
                    end
                    
                    return damage
                end
            end
            
            -- 攻击有概率点燃目标
            local function on_attacked_other(inst, data)
                if data and data.target and data.target.components.burnable and math.random() < 0.4 then
                    data.target.components.burnable:Ignite()
                    
                    if player.components.talker then
                        player.components.talker:Say("燃烧吧！")
                    end
                end
            end
            
            player:ListenForEvent("onhitother", on_attacked_other)
            
            -- 火焰环绕效果
            local flames = {}
            for i = 1, 3 do
                local flame = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                if flame then
                    flame.entity:SetParent(player.entity)
                    flame.Transform:SetPosition(0, 0, 0)
                    table.insert(flames, flame)
                end
            end
            
            return function()
                player:RemoveTag("fireimmune")
                
                if player.components.combat then
                    player.components.combat.CalcDamage = old_calc_damage
                end
                
                player:RemoveEventCallback("onhitother", on_attacked_other)
                
                for _, flame in ipairs(flames) do
                    if flame:IsValid() then
                        flame:Remove()
                    end
                end
                
                DebugLog(3, "清理火焰掌控效果")
            end
        end
    },
    {
        id = "BUFF_135",
        name = "冰霜掌控",
        description = "你可以掌控冰霜，并且不会被冻伤！",
        fn = function(player)
            -- 抵抗冻伤
            player:AddTag("frostimmune")
            
            -- 冰冻光环
            local task = player:DoPeriodicTask(3, function()
                local x, y, z = player.Transform:GetWorldPosition()
                local enemies = TheSim:FindEntities(x, y, z, 5, {"_combat"}, {"player", "companion", "wall", "INLIMBO"})
                
                for _, enemy in ipairs(enemies) do
                    if enemy.components.freezable then
                        enemy.components.freezable:AddColdness(1)
                        
                        -- 生成冻结效果
                        local fx = SpawnPrefab("ice_splash")
                        if fx then
                            local ex, ey, ez = enemy.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(ex, ey, ez)
                        end
                    end
                    
                    -- 减缓敌人速度
                    if enemy.components.locomotor then
                        enemy.components.locomotor:SetExternalSpeedMultiplier(enemy, "frost_aura", 0.8)
                        
                        -- 3秒后恢复
                        enemy:DoTaskInTime(3, function()
                            if enemy:IsValid() and enemy.components.locomotor then
                                enemy.components.locomotor:RemoveExternalSpeedMultiplier(enemy, "frost_aura")
                            end
                        end)
                    end
                end
            end)
            
            -- 冰霜环绕效果
            local fx = SpawnPrefab("icefishing_ice_fx")
            if fx then
                fx.entity:SetParent(player.entity)
                fx.Transform:SetPosition(0, 0, 0)
                fx.Transform:SetScale(0.5, 0.5, 0.5)
            end
            
            return function()
                player:RemoveTag("frostimmune")
                
                if task then
                    task:Cancel()
                end
                
                if fx and fx:IsValid() then
                    fx:Remove()
                end
                
                DebugLog(3, "清理冰霜掌控效果")
            end
        end
    },
    {
        id = "BUFF_136",
        name = "幸运星",
        description = "你的运气增加，有几率获得额外物品！",
        fn = function(player)
            -- 监听采集事件
            local old_pick = ACTIONS.PICK.fn
            ACTIONS.PICK.fn = function(act)
                local result = old_pick(act)
                
                if act.doer == player and math.random() < 0.15 then -- 15%几率额外收获
                    if act.target and act.target.components.pickable and act.target.components.pickable.product then
                        local product = act.target.components.pickable.product
                        local bonus = SpawnPrefab(product)
                        
                        if bonus and player.components.inventory then
                            player.components.inventory:GiveItem(bonus)
                            
                            if player.components.talker then
                                player.components.talker:Say("太幸运了，多收获了一个！")
                            end
                            
                            -- 生成幸运效果
                            local fx = SpawnPrefab("golden_item_fx")
                            if fx then
                                fx.entity:SetParent(player.entity)
                            end
                        end
                    end
                end
                
                return result
            end
            
            -- 监听采矿事件
            local old_mine = ACTIONS.MINE.fn
            ACTIONS.MINE.fn = function(act)
                local result = old_mine(act)
                
                if act.doer == player and act.target and act.target:HasTag("boulder") and math.random() < 0.15 then
                    local bonus_items = {"rocks", "nitre", "flint", "goldnugget"}
                    
                    -- 随机选择一种资源
                    local bonus_item = bonus_items[math.random(#bonus_items)]
                    local bonus = SpawnPrefab(bonus_item)
                    
                    if bonus and player.components.inventory then
                        player.components.inventory:GiveItem(bonus)
                        
                        if player.components.talker then
                            player.components.talker:Say("哇，意外收获！")
                        end
                    end
                end
                
                return result
            end
            
            -- 更好的钓鱼运气
            local old_fish = ACTIONS.FISH.fn
            ACTIONS.FISH.fn = function(act)
                if act.doer == player and math.random() < 0.2 then
                    -- 提高稀有鱼的几率
                    -- 实现依赖于游戏内部钓鱼机制
                end
                
                return old_fish(act)
            end
            
            return function()
                ACTIONS.PICK.fn = old_pick
                ACTIONS.MINE.fn = old_mine
                ACTIONS.FISH.fn = old_fish
                
                DebugLog(3, "清理幸运星效果")
            end
        end
    },
    {
        id = "BUFF_137",
        name = "夜视能力",
        description = "你获得了夜视能力，在夜晚也能看清周围！",
        fn = function(player)
            -- 添加夜视效果
            player:AddTag("nightvision")
            
            -- 减轻黑暗引起的理智损失
            if player.components.sanity then
                local old_night_drain = player.components.sanity.night_drain_mult or 1
                player.components.sanity.night_drain_mult = 0.1
            end
            
            -- 让玩家发光
            local light = SpawnPrefab("minerhatlight")
            if light then
                light.entity:SetParent(player.entity)
                light.Transform:SetPosition(0, 0, 0)
                
                -- 调整光照范围和强度
                if light.Light then
                    light.Light:SetRadius(6)
                    light.Light:SetFalloff(0.6)
                    light.Light:SetIntensity(0.6)
                    light.Light:SetColour(0.8, 0.8, 1)
                end
            end
            
            return function()
                player:RemoveTag("nightvision")
                
                if player.components.sanity then
                    player.components.sanity.night_drain_mult = old_night_drain
                end
                
                if light and light:IsValid() then
                    light:Remove()
                end
                
                DebugLog(3, "清理夜视能力效果")
            end
        end
    },
    {
        id = "BUFF_138",
        name = "暗影朋友",
        description = "暗影生物将不再敌视你，甚至可能成为你的朋友！",
        fn = function(player)
            -- 让暗影生物不再敌视玩家
            player:AddTag("shadowfriend")
            
            -- 暗影生物有几率跟随玩家
            local function on_attacked(inst, data)
                if data and data.attacker and data.attacker:HasTag("shadow") and math.random() < 0.3 then
                    if data.attacker.components.combat then
                        data.attacker.components.combat:SetTarget(nil)
                    end
                    
                    if data.attacker.components.follower then
                        data.attacker.components.follower:SetLeader(player)
                        
                        if player.components.talker then
                            player.components.talker:Say("这个暗影生物似乎对我有好感...")
                        end
                    end
                end
            end
            
            player:ListenForEvent("attacked", on_attacked)
            
            -- 理智值低时有几率生成友好暗影生物
            local shadow_task = player:DoPeriodicTask(30, function()
                if player.components.sanity and player.components.sanity:GetPercent() < 0.3 and math.random() < 0.2 then
                    local shadow_types = {"crawlinghorror", "terrorbeak"}
                    local shadow_type = shadow_types[math.random(#shadow_types)]
                    
                    local shadow = SpawnPrefab(shadow_type)
                    if shadow then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local radius = 3
                        
                        shadow.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                        
                        -- 让暗影生物友好
                        shadow:AddTag("companion")
                        shadow:RemoveTag("hostile")
                        
                        if shadow.components.combat then
                            shadow.components.combat:SetTarget(nil)
                        end
                        
                        if shadow.components.follower then
                            shadow.components.follower:SetLeader(player)
                        end
                        
                        -- 一段时间后消失
                        shadow:DoTaskInTime(120, function()
                            if shadow:IsValid() then
                                shadow:Remove()
                            end
                        end)
                        
                        if player.components.talker then
                            player.components.talker:Say("黑暗中的朋友来了...")
                        end
                    end
                end
            end)
            
            return function()
                player:RemoveTag("shadowfriend")
                player:RemoveEventCallback("attacked", on_attacked)
                
                if shadow_task then
                    shadow_task:Cancel()
                end
                
                DebugLog(3, "清理暗影朋友效果")
            end
        end
    },
    {
        id = "BUFF_139",
        name = "魔法工匠",
        description = "你制作的魔法物品更强大，耐久更长！",
        fn = function(player)
            -- 监听制作事件
            local function on_item_crafted(inst, data)
                if data and data.item then
                    local item = data.item
                    
                    -- 检查是否是魔法物品
                    local is_magical = false
                    if item:HasTag("sharp") or item:HasTag("weapon") or item:HasTag("tool") then
                        -- 魔法武器和工具的标签检查
                        if item.prefab:find("nightsword") or 
                           item.prefab:find("fire") or 
                           item.prefab:find("ice") or 
                           item.prefab:find("telestaff") or
                           item.prefab:find("orangestaff") or
                           item.prefab:find("yellowstaff") or
                           item.prefab:find("greenstaff") or
                           item.prefab:find("opalstaff") or
                           item.prefab:find("ruins") then
                            is_magical = true
                        end
                    end
                    
                    if is_magical then
                        -- 增加耐久度
                        if item.components.finiteuses then
                            item.components.finiteuses:SetMaxUses(item.components.finiteuses.total * 1.5)
                            item.components.finiteuses:SetUses(item.components.finiteuses.total * 1.5)
                        end
                        
                        -- 增加伤害
                        if item.components.weapon then
                            item.components.weapon.damage = item.components.weapon.damage * 1.2
                        end
                        
                        -- 增加效率
                        if item.components.tool then
                            for action, eff in pairs(item.components.tool.effectiveness) do
                                item.components.tool.effectiveness[action] = eff * 1.2
                            end
                        end
                        
                        -- 添加魔法效果
                        local fx = SpawnPrefab("lavaarena_player_revive_from_corpse_fx")
                        if fx then
                            fx.entity:SetParent(item.entity)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("我在这件物品中注入了强大的魔力！")
                        end
                    end
                end
            end
            
            player:ListenForEvent("itemcrafted", on_item_crafted)
            
            return function()
                player:RemoveEventCallback("itemcrafted", on_item_crafted)
                DebugLog(3, "清理魔法工匠效果")
            end
        end
    },
    {
        id = "BUFF_140",
        name = "灵魂链接",
        description = "你可以看到并与灵魂互动！",
        fn = function(player)
            -- 增加灵魂感知
            player:AddTag("ghostvision")
            
            -- 让玩家发光
            player.Light:Enable(true)
            player.Light:SetRadius(2)
            player.Light:SetFalloff(0.7)
            player.Light:SetIntensity(0.6)
            player.Light:SetColour(0.8, 0.5, 1.0)
            
            -- 有几率在死亡生物处生成灵魂
            local function on_entity_death(world, data)
                if data and data.inst and not data.inst:HasTag("player") and math.random() < 0.2 then
                    local x, y, z = data.inst.Transform:GetWorldPosition()
                    
                    -- 创建灵魂效果
                    local soul = SpawnPrefab("wortox_soul")
                    if soul then
                        soul.Transform:SetPosition(x, y + 1, z)
                        
                        -- 让灵魂飘向玩家
                        soul:DoTaskInTime(1, function()
                            if soul:IsValid() and player:IsValid() then
                                local px, py, pz = player.Transform:GetWorldPosition()
                                soul.Transform:SetPosition(px, py, pz)
                                
                                -- 给予玩家治疗
                                if player.components.health then
                                    player.components.health:DoDelta(5)
                                    
                                    if player.components.talker then
                                        player.components.talker:Say("我能感受到这个灵魂的力量...")
                                    end
                                end
                                
                                soul:DoTaskInTime(0.5, function()
                                    if soul:IsValid() then
                                        soul:Remove()
                                    end
                                end)
                            end
                        end)
                    end
                end
            end
            
            TheWorld:ListenForEvent("entity_death", on_entity_death)
            
            -- 允许玩家看到鬼魂
            local on_ghost_appeared = function(world, ghost)
                if ghost and ghost:HasTag("playerghost") then
                    ghost:DoTaskInTime(1, function()
                        if ghost:IsValid() and player:IsValid() and player.components.talker then
                            player.components.talker:Say("我能看到你的灵魂...")
                        end
                    end)
                end
            end
            
            TheWorld:ListenForEvent("ms_playerjoined", on_ghost_appeared)
            
            return function()
                player:RemoveTag("ghostvision")
                player.Light:Enable(false)
                
                TheWorld:RemoveEventCallback("entity_death", on_entity_death)
                TheWorld:RemoveEventCallback("ms_playerjoined", on_ghost_appeared)
                
                DebugLog(3, "清理灵魂链接效果")
            end
        end
    },
    {
        id = "BUFF_141",
        name = "瞬间移动",
        description = "你可以标记位置并传送回去！",
        fn = function(player)
            local marked_pos = nil
            local marker = nil
            
            -- 创建标记功能
            local function mark_position()
                local x, y, z = player.Transform:GetWorldPosition()
                marked_pos = {x=x, y=y, z=z}
                
                -- 移除旧标记
                if marker and marker:IsValid() then
                    marker:Remove()
                end
                
                -- 创建新标记
                marker = SpawnPrefab("staff_castinglight")
                if marker then
                    marker.Transform:SetPosition(x, y, z)
                    marker:DoTaskInTime(0.5, function()
                        if marker and marker.AnimState then
                            marker.AnimState:SetMultColour(0.8, 0.5, 1.0, 1)
                        end
                    end)
                end
                
                if player.components.talker then
                    player.components.talker:Say("我标记了这个位置！")
                end
            end
            
            -- 传送功能
            local function teleport_to_mark()
                if marked_pos then
                    -- 创建传送效果
                    local fx1 = SpawnPrefab("spawn_fx_medium")
                    if fx1 then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx1.Transform:SetPosition(x, y, z)
                    end
                    
                    -- 执行传送
                    player.Physics:Teleport(marked_pos.x, marked_pos.y, marked_pos.z)
                    
                    -- 到达效果
                    local fx2 = SpawnPrefab("spawn_fx_medium")
                    if fx2 then
                        fx2.Transform:SetPosition(marked_pos.x, marked_pos.y, marked_pos.z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("传送成功！")
                    end
                else
                    if player.components.talker then
                        player.components.talker:Say("我还没有标记位置！")
                    end
                end
            end
            
            -- 注册按键监听
            TheInput:AddKeyHandler(function(key, down)
                if down then
                    -- 按F键标记位置
                    if key == KEY_F then
                        mark_position()
                    -- 按R键传送到标记位置
                    elseif key == KEY_R then
                        teleport_to_mark()
                    end
                end
                return false
            end)
            
            return function()
                if marker and marker:IsValid() then
                    marker:Remove()
                end
                
                -- 移除按键监听（这里是模拟，实际需要保存handler并移除）
                -- TheInput:RemoveKeyHandler(key_handler)
                
                DebugLog(3, "清理瞬间移动效果")
            end
        end
    },
    {
        id = "BUFF_142",
        name = "宠物召唤师",
        description = "你可以召唤小动物跟随你！",
        fn = function(player)
            local pets = {}
            local max_pets = 3
            local pet_types = {"rabbit", "robin", "butterfly", "perdling", "grassgekko", "kitcoon"}
            
            -- 召唤宠物功能
            local function summon_pet()
                if #pets >= max_pets then
                    if player.components.talker then
                        player.components.talker:Say("我已经有太多宠物了！")
                    end
                    return
                end
                
                local pet_type = pet_types[math.random(#pet_types)]
                local pet = SpawnPrefab(pet_type)
                
                if pet then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local radius = 2
                    
                    pet.Transform:SetPosition(x + radius * math.cos(angle), 0, z + radius * math.sin(angle))
                    
                    -- 设置宠物行为
                    if pet.components.follower then
                        pet.components.follower:SetLeader(player)
                    end
                    
                    -- 设置宠物友好
                    if pet.components.combat then
                        pet.components.combat:SetDefaultDamage(15) -- 提高伤害
                    end
                    
                    -- 添加特殊效果
                    local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx then
                        fx.entity:SetParent(pet.entity)
                        fx:DoTaskInTime(1, function() 
                            if fx:IsValid() then fx:Remove() end 
                        end)
                    end
                    
                    pet:AddTag("summoned_pet")
                    table.insert(pets, pet)
                    
                    if player.components.talker then
                        player.components.talker:Say("来吧，小家伙！")
                    end
                    
                    -- 设置宠物寿命
                    pet:DoTaskInTime(300, function() -- 5分钟后消失
                        if pet:IsValid() then
                            local pfx = SpawnPrefab("spawn_fx_small")
                            if pfx then
                                local px, py, pz = pet.Transform:GetWorldPosition()
                                pfx.Transform:SetPosition(px, py, pz)
                            end
                            
                            for i, p in ipairs(pets) do
                                if p == pet then
                                    table.remove(pets, i)
                                    break
                                end
                            end
                            
                            pet:Remove()
                        end
                    end)
                end
            end
            
            -- 定期随机召唤
            local task = player:DoPeriodicTask(60, function() -- 每60秒尝试召唤
                if math.random() < 0.5 and #pets < max_pets then -- 50%几率
                    summon_pet()
                end
            end)
            
            -- 首次立即召唤一个
            summon_pet()
            
            return function()
                if task then
                    task:Cancel()
                end
                
                -- 移除所有召唤的宠物
                for _, pet in ipairs(pets) do
                    if pet:IsValid() then
                        local fx = SpawnPrefab("spawn_fx_small")
                        if fx then
                            local x, y, z = pet.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        pet:Remove()
                    end
                end
                
                DebugLog(3, "清理宠物召唤师效果")
            end
        end
    },
    {
        id = "BUFF_143",
        name = "腐化掌控",
        description = "你可以利用腐烂物制造毒素攻击！",
        fn = function(player)
            -- 添加毒素伤害到武器
            if player.components.combat then
                local old_calc_damage = player.components.combat.CalcDamage
                player.components.combat.CalcDamage = function(self, target, weapon, multiplier)
                    local damage = old_calc_damage(self, target, weapon, multiplier)
                    
                    -- 对生物造成额外毒素伤害
                    if target:HasTag("monster") or target:HasTag("animal") or target:HasTag("insect") then
                        -- 创建毒素效果
                        local fx = SpawnPrefab("poison_cloud")
                        if fx then
                            local x, y, z = target.Transform:GetWorldPosition()
                            fx.Transform:SetPosition(x, y, z)
                        end
                        
                        -- 让目标中毒
                        if target.components.health and not target.components.health:IsDead() then
                            target:DoTaskInTime(1, function()
                                if target:IsValid() and target.components.health then
                                    target.components.health:DoDelta(-5)
                                end
                            end)
                            
                            target:DoTaskInTime(3, function()
                                if target:IsValid() and target.components.health then
                                    target.components.health:DoDelta(-5)
                                end
                            end)
                        end
                        
                        return damage * 1.2 -- 额外20%伤害
                    end
                    
                    return damage
                end
            end
            
            -- 腐烂物光环
            local aura = player:DoPeriodicTask(0.5, function()
                local x, y, z = player.Transform:GetWorldPosition()
                
                -- 随机生成毒气效果
                if math.random() < 0.1 then
                    local angle = math.random() * 2 * math.pi
                    local radius = math.random() * 3
                    
                    local fx = SpawnPrefab("poison_cloud")
                    if fx then
                        fx.Transform:SetPosition(x + radius * math.cos(angle), y, z + radius * math.sin(angle))
                        fx:DoTaskInTime(2, function() 
                            if fx:IsValid() then fx:Remove() end 
                        end)
                    end
                end
                
                -- 检查附近敌人
                local targets = TheSim:FindEntities(x, y, z, 6, {"_combat"}, {"player", "companion", "INLIMBO"})
                for _, target in ipairs(targets) do
                    if target.components.health and math.random() < 0.2 then
                        -- 造成腐化伤害
                        target.components.health:DoDelta(-1)
                        
                        -- 减缓敌人速度
                        if target.components.locomotor then
                            target.components.locomotor:SetExternalSpeedMultiplier(target, "poison_effect", 0.8)
                            
                            target:DoTaskInTime(2, function()
                                if target:IsValid() and target.components.locomotor then
                                    target.components.locomotor:RemoveExternalSpeedMultiplier(target, "poison_effect")
                                end
                            end)
                        end
                    end
                end
            end)
            
            -- 玩家免疫毒素
            player:AddTag("poisonimmune")
            
            return function()
                if player.components.combat then
                    player.components.combat.CalcDamage = old_calc_damage
                end
                
                if aura then
                    aura:Cancel()
                end
                
                player:RemoveTag("poisonimmune")
                
                DebugLog(3, "清理腐化掌控效果")
            end
        end
    },
    {
        id = "BUFF_144",
        name = "虫群支配",
        description = "你可以控制昆虫为你战斗！",
        fn = function(player)
            local controlled_insects = {}
            local max_insects = 5
            
            -- 玩家不会被昆虫攻击
            player:AddTag("insectfriend")
            
            -- 控制昆虫函数
            local function attempt_control(insect)
                if #controlled_insects >= max_insects then return false end
                
                if insect:HasTag("insect") or insect.prefab == "spider" or insect.prefab == "beehive" then
                    -- 标记为已控制
                    insect:AddTag("controlled_insect")
                    
                    -- 改变颜色
                    if insect.AnimState then
                        insect.AnimState:SetMultColour(0.7, 1, 0.7, 1)
                    end
                    
                    -- 设置为友好
                    if insect.components.combat then
                        local old_target = insect.components.combat.target
                        
                        -- 如果正在攻击玩家，停止攻击
                        if old_target == player then
                            insect.components.combat:SetTarget(nil)
                        end
                        
                        -- 修改目标选择逻辑
                        local old_retarget = insect.components.combat.RetargetFunction
                        insect.components.combat.RetargetFunction = function(inst)
                            local x, y, z = inst.Transform:GetWorldPosition()
                            local targets = TheSim:FindEntities(x, y, z, 20, {"_combat"}, {"player", "controlled_insect", "insect", "INLIMBO"})
                            
                            for _, target in ipairs(targets) do
                                if target ~= player and (target:HasTag("monster") or target:HasTag("animal")) then
                                    return target
                                end
                            end
                            
                            return nil
                        end
                        
                        -- 保存原始函数以便清理
                        insect.old_retarget = old_retarget
                    end
                    
                    -- 跟随玩家
                    if insect.components.follower then
                        insect.components.follower:SetLeader(player)
                    end
                    
                    -- 增强昆虫
                    if insect.components.health then
                        insect.components.health:SetMaxHealth(insect.components.health.maxhealth * 1.5)
                        insect.components.health:SetPercent(1)
                    end
                    
                    if insect.components.combat then
                        insect.components.combat.defaultdamage = insect.components.combat.defaultdamage * 1.5
                    end
                    
                    -- 添加效果
                    local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx then
                        fx.entity:SetParent(insect.entity)
                        fx:DoTaskInTime(1, function() 
                            if fx:IsValid() then fx:Remove() end 
                        end)
                    end
                    
                    -- 添加到控制列表
                    table.insert(controlled_insects, insect)
                    
                    -- 一段时间后消失
                    insect:DoTaskInTime(120, function()
                        if insect:IsValid() then
                            -- 移除控制标记
                            insect:RemoveTag("controlled_insect")
                            
                            -- 恢复颜色
                            if insect.AnimState then
                                insect.AnimState:SetMultColour(1, 1, 1, 1)
                            end
                            
                            -- 恢复战斗逻辑
                            if insect.components.combat and insect.old_retarget then
                                insect.components.combat.RetargetFunction = insect.old_retarget
                                insect.old_retarget = nil
                            end
                            
                            -- 移除跟随
                            if insect.components.follower then
                                insect.components.follower:SetLeader(nil)
                            end
                            
                            -- 从列表移除
                            for i, controlled in ipairs(controlled_insects) do
                                if controlled == insect then
                                    table.remove(controlled_insects, i)
                                    break
                                end
                            end
                        end
                    end)
                    
                    return true
                end
                
                return false
            end
            
            -- 定期检查附近昆虫
            local control_task = player:DoPeriodicTask(5, function()
                if #controlled_insects >= max_insects then return end
                
                local x, y, z = player.Transform:GetWorldPosition()
                local insects = TheSim:FindEntities(x, y, z, 10, nil, {"controlled_insect", "INLIMBO"}, {"insect", "spider"})
                
                for _, insect in ipairs(insects) do
                    if attempt_control(insect) and player.components.talker then
                        player.components.talker:Say("这个小家伙现在为我服务了！")
                        break -- 每次只控制一个
                    end
                end
            end)
            
            -- 定期生成蜜蜂
            local spawn_task = player:DoPeriodicTask(30, function()
                if #controlled_insects < max_insects and math.random() < 0.5 then
                    local bee = SpawnPrefab("bee")
                    if bee then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local radius = 2
                        
                        bee.Transform:SetPosition(x + radius * math.cos(angle), y, z + radius * math.sin(angle))
                        
                        attempt_control(bee)
                    end
                end
            end)
            
            return function()
                player:RemoveTag("insectfriend")
                
                if control_task then
                    control_task:Cancel()
                end
                
                if spawn_task then
                    spawn_task:Cancel()
                end
                
                -- 释放所有控制的昆虫
                for _, insect in ipairs(controlled_insects) do
                    if insect:IsValid() then
                        -- 移除控制标记
                        insect:RemoveTag("controlled_insect")
                        
                        -- 恢复颜色
                        if insect.AnimState then
                            insect.AnimState:SetMultColour(1, 1, 1, 1)
                        end
                        
                        -- 恢复战斗逻辑
                        if insect.components.combat and insect.old_retarget then
                            insect.components.combat.RetargetFunction = insect.old_retarget
                            insect.old_retarget = nil
                        end
                        
                        -- 移除跟随
                        if insect.components.follower then
                            insect.components.follower:SetLeader(nil)
                        end
                    end
                end
                
                DebugLog(3, "清理虫群支配效果")
            end
        end
    },
    {
        id = "BUFF_145",
        name = "食物能量",
        description = "食物会给你提供额外的能量和效果！",
        fn = function(player)
            -- 监听进食事件
            local function on_eat_food(inst, data)
                if not data or not data.food then return end
                
                local food = data.food
                
                -- 创建能量效果
                local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                if fx then
                    fx.entity:SetParent(player.entity)
                    fx:DoTaskInTime(1, function() 
                        if fx:IsValid() then fx:Remove() end 
                    end)
                end
                
                -- 根据食物类型提供不同效果
                if food:HasTag("fruit") then
                    -- 水果提供移动速度
                    if player.components.locomotor then
                        player.components.locomotor:SetExternalSpeedMultiplier(player, "fruit_boost", 1.3)
                        
                        player:DoTaskInTime(30, function()
                            if player:IsValid() and player.components.locomotor then
                                player.components.locomotor:RemoveExternalSpeedMultiplier(player, "fruit_boost")
                            end
                        end)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("好清爽的果子，我感觉更敏捷了！")
                    end
                elseif food:HasTag("veggie") then
                    -- 蔬菜提供防御
                    if player.components.health then
                        local old_absorb = player.components.health.absorb or 0
                        player.components.health.absorb = old_absorb + 0.3
                        
                        player:DoTaskInTime(30, function()
                            if player:IsValid() and player.components.health then
                                player.components.health.absorb = old_absorb
                            end
                        end)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("蔬菜的力量让我更坚韧了！")
                    end
                elseif food:HasTag("meat") then
                    -- 肉类提供攻击力
                    if player.components.combat then
                        local old_damage_mult = player.components.combat.damagemultiplier or 1
                        player.components.combat.damagemultiplier = old_damage_mult * 1.3
                        
                        player:DoTaskInTime(30, function()
                            if player:IsValid() and player.components.combat then
                                player.components.combat.damagemultiplier = old_damage_mult
                            end
                        end)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("肉类让我充满了力量！")
                    end
                elseif food.components.edible and food.components.edible.foodtype == FOODTYPE.GOODIES then
                    -- 甜食提供理智恢复
                    if player.components.sanity then
                        player.components.sanity:DoDelta(20)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("甜食总能让人心情愉悦！")
                    end
                else
                    -- 其他食物提供小幅全面增益
                    if player.components.health then
                        player.components.health:DoDelta(5)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("吃饱了才有力气！")
                    end
                end
            end
            
            player:ListenForEvent("oneat", on_eat_food)
            
            -- 提高所有食物效果
            local old_get_hunger = GLOBAL.GetHunger
            GLOBAL.GetHunger = function(inst, item)
                local hunger_val = old_get_hunger(inst, item)
                if inst == player then
                    return hunger_val * 1.5
                end
                return hunger_val
            end
            
            local old_get_health = GLOBAL.GetHealth
            GLOBAL.GetHealth = function(inst, item)
                local health_val = old_get_health(inst, item)
                if inst == player then
                    return health_val * 1.5
                end
                return health_val
            end
            
            local old_get_sanity = GLOBAL.GetSanity
            GLOBAL.GetSanity = function(inst, item)
                local sanity_val = old_get_sanity(inst, item)
                if inst == player then
                    return sanity_val * 1.5
                end
                return sanity_val
            end
            
            return function()
                player:RemoveEventCallback("oneat", on_eat_food)
                
                -- 恢复原始函数
                GLOBAL.GetHunger = old_get_hunger
                GLOBAL.GetHealth = old_get_health
                GLOBAL.GetSanity = old_get_sanity
                
                DebugLog(3, "清理食物能量效果")
            end
        end
    },
    {
        id = "BUFF_146",
        name = "月光祝福",
        description = "你受到月亮的祝福，获得特殊能力！",
        fn = function(player)
            -- 玩家夜晚发光
            local light = nil
            
            -- 月相变化监听
            local function on_phase_changed(inst, phase)
                -- 根据月相调整效果强度
                local power_mult = 1
                
                if phase == "new" then
                    power_mult = 0.5 -- 新月效果弱
                elseif phase == "full" then
                    power_mult = 2 -- 满月效果强
                elseif phase == "quarter" or phase == "threequarter" then
                    power_mult = 1.5 -- 其他月相中等
                end
                
                -- 更新光效
                if light and light:IsValid() then
                    light:Remove()
                    light = nil
                end
                
                if TheWorld.state.isnight then
                    light = SpawnPrefab("minerhatlight")
                    if light then
                        light.entity:SetParent(player.entity)
                        light.Transform:SetPosition(0, 0, 0)
                        
                        if light.Light then
                            light.Light:SetRadius(3 * power_mult)
                            light.Light:SetFalloff(0.7)
                            light.Light:SetIntensity(0.6 * power_mult)
                            light.Light:SetColour(0.6, 0.6, 1)
                        end
                    end
                end
                
                -- 根据月相和时间更新能力
                if player.components.combat then
                    if TheWorld.state.isnewmoon then
                        -- 新月增强隐身能力
                        if TheWorld.state.isnight and player.AnimState then
                            player.AnimState:SetMultColour(1, 1, 1, 0.7)
                        else
                            player.AnimState:SetMultColour(1, 1, 1, 1)
                        end
                    elseif TheWorld.state.isfullmoon then
                        -- 满月增强战斗能力
                        player.components.combat.damagemultiplier = 1.5
                        
                        -- 满月特效
                        if TheWorld.state.isnight then
                            local fx = SpawnPrefab("moonpulse_fx")
                            if fx then
                                fx.entity:SetParent(player.entity)
                                fx.Transform:SetScale(0.5, 0.5, 0.5)
                                fx:DoTaskInTime(5, function() 
                                    if fx:IsValid() then fx:Remove() end 
                                end)
                            end
                            
                            if player.components.talker then
                                player.components.talker:Say("我感受到了满月的力量！")
                            end
                        end
                    else
                        -- 恢复正常
                        player.components.combat.damagemultiplier = 1
                        if player.AnimState then
                            player.AnimState:SetMultColour(1, 1, 1, 1)
                        end
                    end
                end
                
                -- 夜晚理智影响
                if player.components.sanity then
                    if TheWorld.state.isnight then
                        if TheWorld.state.isfullmoon then
                            -- 满月增加理智恢复
                            player.components.sanity.dapperness = 2
                        else
                            -- 其他月相减轻理智损失
                            player.components.sanity.night_drain_mult = 0.5
                        end
                    else
                        -- 白天恢复正常
                        player.components.sanity.dapperness = 0
                        player.components.sanity.night_drain_mult = 1
                    end
                end
            end
            
            -- 日夜变化监听
            local function on_day_changed(inst, isday)
                if isday then
                    -- 白天移除光效
                    if light and light:IsValid() then
                        light:Remove()
                        light = nil
                    end
                    
                    -- 恢复正常
                    if player.AnimState then
                        player.AnimState:SetMultColour(1, 1, 1, 1)
                    end
                else
                    -- 夜晚调用月相变化处理
                    on_phase_changed(inst, TheWorld.state.moonphase)
                end
            end
            
            TheWorld:ListenForEvent("moonphasechanged", on_phase_changed)
            TheWorld:ListenForEvent("dusktime", function() on_day_changed(player, false) end)
            TheWorld:ListenForEvent("daytime", function() on_day_changed(player, true) end)
            
            -- 初始化
            on_phase_changed(player, TheWorld.state.moonphase)
            
            return function()
                if light and light:IsValid() then
                    if light and light:IsValid() then
                        light:Remove()
                    end
                    
                    -- 恢复玩家状态
                    if player.components.combat then
                        player.components.combat.damagemultiplier = 1
                    end
                    
                    if player.AnimState then
                        player.AnimState:SetMultColour(1, 1, 1, 1)
                    end
                    
                    if player.components.sanity then
                        player.components.sanity.dapperness = 0
                        player.components.sanity.night_drain_mult = 1
                    end
                                             
                    TheWorld:RemoveEventCallback("moonphasechanged", on_phase_changed)
                    TheWorld:RemoveEventCallback("dusktime", function() on_day_changed(player, false) end)
                    TheWorld:RemoveEventCallback("daytime", function() on_day_changed(player, true) end)
                    
                    DebugLog(3, "清理月光祝福效果")
                end
            end
        end
    },
    {              
        id = "BUFF_147",
        name = "星辰指引",
        description = "夜晚时你能看到星星指引的方向！",
        fn = function(player)
                -- 夜晚移动速度加快
                local night_speed_task = nil
                
                -- 日夜更替处理
                local function on_day_changed(inst, isday)
                    if night_speed_task then
                        night_speed_task:Cancel()
                        night_speed_task = nil
                    end
                    
                    if not isday and player.components.locomotor then
                        -- 夜晚启动速度增益
                        player.components.locomotor:SetExternalSpeedMultiplier(player, "night_speed", 1.4)
                        
                        -- 创建星星效果
                        night_speed_task = player:DoPeriodicTask(3, function()
                            if not TheWorld.state.isnight then return end
                            
                            local x, y, z = player.Transform:GetWorldPosition()
                            
                            -- 创建星星粒子
                            for i = 1, 3 do
                                local fx = SpawnPrefab("sparklefx")
                                if fx then
                                    local angle = math.random() * 2 * math.pi
                                    local radius = math.random() * 2
                                    fx.Transform:SetPosition(x + radius * math.cos(angle), y + 2, z + radius * math.sin(angle))
                                    
                                    -- 一段时间后消失
                                    fx:DoTaskInTime(2, function()
                                        if fx:IsValid() then
                                            fx:Remove()
                                        end
                                    end)
                                end
                            end
                            
                            -- 偶尔说话
                            if math.random() < 0.2 and player.components.talker then
                                local messages = {
                                    "星星在为我指路...",
                                    "夜色如此美丽！",
                                    "星空下行走真是惬意！",
                                    "我能感觉到星星的能量！"
                                }
                                player.components.talker:Say(messages[math.random(#messages)])
                            end
                        end)
                    else
                        -- 白天移除速度增益
                        if player.components.locomotor then
                            player.components.locomotor:RemoveExternalSpeedMultiplier(player, "night_speed")
                        end
                    end
                end
                
                -- 添加夜视能力
                player:AddTag("nightvision")
                
                -- 监听日夜更替
                TheWorld:ListenForEvent("dusktime", function() on_day_changed(player, false) end)
                TheWorld:ListenForEvent("daytime", function() on_day_changed(player, true) end)
                
                -- 初始化
                on_day_changed(player, not TheWorld.state.isnight)
                
                -- 提高夜晚理智恢复
                if player.components.sanity then
                    player.components.sanity.night_drain_mult = 0
                end
                
                return function()
                    if night_speed_task then
                        night_speed_task:Cancel()
                    end
                    
                    if player.components.locomotor then
                        player.components.locomotor:RemoveExternalSpeedMultiplier(player, "night_speed")
                    end
                    
                    player:RemoveTag("nightvision")
                    
                    if player.components.sanity then
                        player.components.sanity.night_drain_mult = 1
                    end
                    
                    TheWorld:RemoveEventCallback("dusktime", function() on_day_changed(player, false) end)
                    TheWorld:RemoveEventCallback("daytime", function() on_day_changed(player, true) end)
                    
                    DebugLog(3, "清理星辰指引效果")
                end
            end
        },
        {
            id = "BUFF_148",
            name = "工具精通",
            description = "你使用工具的效率大大提高！",
            fn = function(player)
                -- 提高工具效率
                local tool_task = player:DoPeriodicTask(0.1, function()
                    local equipped = player.components.inventory and player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    
                    if equipped and equipped.components.tool then
                        -- 添加发光效果
                        if not equipped.tool_glow_fx and math.random() < 0.1 then
                            local fx = SpawnPrefab("deer_food_fx")
                            if fx then
                                fx.entity:SetParent(equipped.entity)
                                fx.Transform:SetPosition(0, 0, 0)
                                equipped.tool_glow_fx = fx
                            end
                        end
                        
                        -- 提高工作效率
                        for action, effectiveness in pairs(equipped.components.tool.effectiveness) do
                            equipped.components.tool.effectiveness[action] = 2.0
                        end
                        
                        -- 减少工具耐久消耗
                        if equipped.components.finiteuses and not equipped.original_consume_per_use then
                            equipped.original_consume_per_use = equipped.components.finiteuses.consumption_rate
                            equipped.components.finiteuses.consumption_rate = 0.5
                        end
                    elseif equipped and equipped.tool_glow_fx then
                        -- 移除不再装备的工具的发光效果
                        if equipped.tool_glow_fx:IsValid() then
                            equipped.tool_glow_fx:Remove()
                        end
                        equipped.tool_glow_fx = nil
                        
                        -- 恢复原始耐久消耗
                        if equipped.components.finiteuses and equipped.original_consume_per_use then
                            equipped.components.finiteuses.consumption_rate = equipped.original_consume_per_use
                            equipped.original_consume_per_use = nil
                        end
                    end
                end)
                
                -- 加快工作动作
                if player.components.worker then
                    player.original_min_action_time = player.components.worker.min_action_time or 0.5
                    player.components.worker.min_action_time = player.original_min_action_time * 0.5
                end
                
                -- 装备工具时的事件处理
                local function on_item_equipped(inst, data)
                    if data and data.item and data.item.components.tool then
                        -- 工具装备特效
                        local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                        if fx then
                            fx.entity:SetParent(data.item.entity)
                            fx:DoTaskInTime(1, function() 
                                if fx:IsValid() then fx:Remove() end 
                            end)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("这工具在我手里更称手了！")
                        end
                    end
                end
                
                player:ListenForEvent("equip", on_item_equipped)
                
                return function()
                    if tool_task then
                        tool_task:Cancel()
                    end
                    
                    -- 恢复工作时间
                    if player.components.worker and player.original_min_action_time then
                        player.components.worker.min_action_time = player.original_min_action_time
                        player.original_min_action_time = nil
                    end
                    
                    -- 恢复所有工具状态
                    if player.components.inventory then
                        for _, item in pairs(player.components.inventory.itemslots) do
                            if item and item.components.tool then
                                -- 恢复原始效率
                                for action, _ in pairs(item.components.tool.effectiveness) do
                                    item.components.tool.effectiveness[action] = 1.0
                                end
                                
                                -- 恢复原始耐久消耗
                                if item.components.finiteuses and item.original_consume_per_use then
                                    item.components.finiteuses.consumption_rate = item.original_consume_per_use
                                    item.original_consume_per_use = nil
                                end
                                
                                -- 移除发光效果
                                if item.tool_glow_fx and item.tool_glow_fx:IsValid() then
                                    item.tool_glow_fx:Remove()
                                    item.tool_glow_fx = nil
                                end
                            end
                        end
                    end
                    
                    player:RemoveEventCallback("equip", on_item_equipped)
                    
                    DebugLog(3, "清理工具精通效果")
                end
            end
        },
        {
            id = "BUFF_149",
            name = "防御反射",
            description = "你能反弹部分伤害回敌人身上！",
            fn = function(player)
                -- 增加基础防御
                if player.components.health then
                    player.original_absorb = player.components.health.absorb or 0
                    player.components.health.absorb = player.original_absorb + 0.3
                end
                
                -- 添加反伤效果
                local function on_attacked(inst, data)
                    if not data or not data.attacker or data.attacker:HasTag("player") then return end
                    
                    local attacker = data.attacker
                    local damage = data.damage or 0
                    
                    -- 创建反射效果
                    local fx = SpawnPrefab("round_puff_fx")
                    if fx then
                        local x, y, z = player.Transform:GetWorldPosition()
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    if attacker.components.health and not attacker.components.health:IsDead() then
                        -- 反弹30%伤害
                        local reflect_damage = damage * 0.3
                        attacker.components.health:DoDelta(-reflect_damage)
                        
                        -- 击退效果
                        if attacker.Physics then
                            local x1, y1, z1 = player.Transform:GetWorldPosition()
                            local x2, y2, z2 = attacker.Transform:GetWorldPosition()
                            
                            local angle = math.atan2(z2 - z1, x2 - x1)
                            local speed = 5
                            local knockback_speed = Vector3(math.cos(angle) * speed, 0, math.sin(angle) * speed)
                            
                            attacker.Physics:SetVel(knockback_speed.x, 0, knockback_speed.z)
                        end
                        
                        -- 特效
                        local damage_fx = SpawnPrefab("impact")
                        if damage_fx then
                            local x, y, z = attacker.Transform:GetWorldPosition()
                            damage_fx.Transform:SetPosition(x, y, z)
                        end
                        
                        if player.components.talker and math.random() < 0.3 then
                            local messages = {
                                "你的攻击对我无效！",
                                "这就是你的攻击的下场！",
                                "感受你自己的力量吧！",
                                "反击！"
                            }
                            player.components.talker:Say(messages[math.random(#messages)])
                        end
                    end
                end
                
                player:ListenForEvent("attacked", on_attacked)
                
                -- 添加防御光环
                local aura = player:DoPeriodicTask(1, function()
                    -- 随机生成防护特效
                    if math.random() < 0.2 then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local radius = 1.5
                        
                        local fx = SpawnPrefab("sparks_fx")
                        if fx then
                            fx.Transform:SetPosition(x + radius * math.cos(angle), y, z + radius * math.sin(angle))
                            fx:DoTaskInTime(1, function() 
                                if fx:IsValid() then fx:Remove() end 
                            end)
                        end
                    end
                end)
                
                -- 视觉标识
                player:AddTag("reflective_shield")
                
                return function()
                    if player.components.health then
                        player.components.health.absorb = player.original_absorb or 0
                        player.original_absorb = nil
                    end
                    
                    player:RemoveEventCallback("attacked", on_attacked)
                    
                    if aura then
                        aura:Cancel()
                    end
                    
                    player:RemoveTag("reflective_shield")
                    
                    DebugLog(3, "清理防御反射效果")
                end
            end
        },
        {
            id = "BUFF_150",
            name = "熔岩行者",
            description = "你可以在熔岩上行走且不受高温影响！",
            fn = function(player)
                -- 免疫火焰伤害
                player:AddTag("fireimmune")
                
                -- 提高热量耐受
                if player.components.temperature then
                    player.original_overheat_temp = player.components.temperature.overheattemp or 70
                    player.components.temperature.overheattemp = 100
                    
                    player.original_current_temp = player.components.temperature.current
                    player.components.temperature.current = 50 -- 设置为温和温度
                    
                    player.original_rate = player.components.temperature.rate
                    player.components.temperature.rate = 0 -- 停止温度变化
                end
                
                -- 脚步特效
                local footstep_task = player:DoPeriodicTask(0.3, function()
                    if player.sg and player.sg:HasStateTag("moving") then
                        local x, y, z = player.Transform:GetWorldPosition()
                        
                        -- 熔岩足迹特效
                        local fx = SpawnPrefab("round_puff_fx")
                        if fx then
                            fx.Transform:SetPosition(x, y, z)
                            fx.Transform:SetScale(0.5, 0.5, 0.5)
                            
                            if fx.AnimState then
                                fx.AnimState:SetMultColour(1, 0.5, 0, 1)
                            end
                            
                            fx:DoTaskInTime(1, function() 
                                if fx:IsValid() then fx:Remove() end 
                            end)
                        end
                        
                        -- 偶尔创建火焰
                        if math.random() < 0.2 then
                            local fire = SpawnPrefab("campfire")
                            if fire then
                                fire.Transform:SetPosition(x, y, z)
                                fire.Transform:SetScale(0.5, 0.5, 0.5)
                                
                                -- 缩短存在时间
                                fire:DoTaskInTime(5, function() 
                                    if fire:IsValid() then 
                                        fire:Remove() 
                                    end 
                                end)
                            end
                        end
                    end
                end)
                
                -- 在火上行走不受伤
                player:AddTag("lavawader")
                
                -- 附近生物受到热伤害
                local heat_aura = player:DoPeriodicTask(1, function()
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ents = TheSim:FindEntities(x, y, z, 4, nil, {"player", "companion", "INLIMBO", "fireimmune"})
                    
                    for _, ent in ipairs(ents) do
                        -- 对生物造成高温伤害
                        if ent.components.health and not ent.components.health:IsDead() and math.random() < 0.3 then
                            ent.components.health:DoDelta(-3)
                            
                            -- 点燃可燃物
                            if ent.components.burnable then
                                ent.components.burnable:Ignite()
                            end
                            
                            -- 热气效果
                            local heat_fx = SpawnPrefab("heatwave_fx")
                            if heat_fx then
                                local ex, ey, ez = ent.Transform:GetWorldPosition()
                                heat_fx.Transform:SetPosition(ex, ey, ez)
                            end
                        end
                    end
                end)
                
                -- 视觉效果
                if player.AnimState then
                    player.AnimState:SetMultColour(1.2, 0.8, 0.8, 1)
                end
                
                return function()
                    player:RemoveTag("fireimmune")
                    player:RemoveTag("lavawader")
                    
                    if player.components.temperature then
                        player.components.temperature.overheattemp = player.original_overheat_temp or 70
                        player.components.temperature.current = player.original_current_temp or 30
                        player.components.temperature.rate = player.original_rate or 1
                        
                        player.original_overheat_temp = nil
                        player.original_current_temp = nil
                        player.original_rate = nil
                    end
                    
                    if footstep_task then
                        footstep_task:Cancel()
                    end
                    
                    if heat_aura then
                        heat_aura:Cancel()
                    end
                    
                    if player.AnimState then
                        player.AnimState:SetMultColour(1, 1, 1, 1)
                    end
                    
                    DebugLog(3, "清理熔岩行者效果")
                end
            end
        },
    }
    -- DEBUFF效果列表定义 (负面效果)
local DEBUFF_LIST = {
    {
        id = "DEBUFF_001",
        name = "蜗牛速度",
        description = "你感觉浑身无力，移动速度降低了50%...",
        fn = function(player)
            player.components.locomotor:SetExternalSpeedMultiplier(player, "speedebuff", 0.5)
            
            return function()
                if player:IsValid() then
                    player.components.locomotor:RemoveExternalSpeedMultiplier(player, "speedebuff")
                end
            end
        end
    },
    {
        id = "DEBUFF_002",
        name = "虚弱无力",
        description = "你的攻击力下降了50%，举起武器都觉得吃力...",
        fn = function(player)
            if player.components.combat then
                local old_damage = player.components.combat.damagemultiplier or 1
                player.components.combat.damagemultiplier = old_damage * 0.5
                
                return function()
                    if player:IsValid() and player.components.combat then
                        player.components.combat.damagemultiplier = old_damage
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_003",
        name = "易碎玻璃",
        description = "你变得异常脆弱，受到的伤害增加了30%...",
        fn = function(player)
            if player.components.health then
                local old_absorb = player.components.health.absorb or 0
                player.components.health.absorb = math.max(0, old_absorb - 0.3)
                
                return function()
                    if player:IsValid() and player.components.health then
                        player.components.health.absorb = old_absorb
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_004",
        name = "噩梦缠身",
        description = "可怕的噩梦折磨着你，每分钟降低10点理智值...",
        fn = function(player)
            if player.components.sanity then
                local task = player:DoPeriodicTask(60, function()
                    if player:IsValid() and player.components.sanity then
                        player.components.sanity:DoDelta(-10)
                        if player.components.talker then
                            player.components.talker:Say("我感觉不太好...")
                        end
                    end
                end)
                
                return function()
                    if task then task:Cancel() end
                end
            end
        end
    },
    {
        id = "DEBUFF_005",
        name = "饥肠辘辘",
        description = "你的饥饿速度增加了3倍，总是感觉饿得快...",
        fn = function(player)
            if player.components.hunger then
                local old_rate = player.components.hunger.hungerrate
                player.components.hunger.hungerrate = old_rate * 3
                
                return function()
                    if player:IsValid() and player.components.hunger then
                        player.components.hunger.hungerrate = old_rate
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_006",
        name = "体温失调",
        description = "你的体温调节系统出现问题，冬天更冷夏天更热...",
        fn = function(player)
            if player.components.temperature then
                local old_GetTemp = player.components.temperature.GetTemp
                player.components.temperature.GetTemp = function(self)
                    local temp = old_GetTemp(self)
                    if _G.TheWorld and _G.TheWorld.state then
                        if _G.TheWorld.state.iswinter then
                            return temp + 10
                        elseif _G.TheWorld.state.issummer then
                            return temp - 10
                        end
                    end
                    return temp
                end
                
                return function()
                    if player:IsValid() and player.components.temperature then
                        player.components.temperature.GetTemp = old_GetTemp
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_007",
        name = "黑暗恐惧",
        description = "黑暗变得更加可怕，夜晚的视野受到了严重影响...",
        fn = function(player)
            if player.components.playervision then
                player.components.playervision:SetCustomCCTable({day = 0, dusk = 0, night = 0.7})
                
                return function()
                    if player:IsValid() and player.components.playervision then
                        player.components.playervision:SetCustomCCTable(nil)
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_008",
        name = "笨手笨脚",
        description = "你变得不太灵活，砍树、挖矿等动作的效率降低了50%...",
        fn = function(player)
            if player.components.workmultiplier then
                player.components.workmultiplier:AddMultiplier(_G.ACTIONS.MINE, 0.5)
                player.components.workmultiplier:AddMultiplier(_G.ACTIONS.CHOP, 0.5)
                player.components.workmultiplier:AddMultiplier(_G.ACTIONS.HAMMER, 0.5)
                
                return function()
                    if player:IsValid() and player.components.workmultiplier then
                        player.components.workmultiplier:RemoveMultiplier(_G.ACTIONS.MINE)
                        player.components.workmultiplier:RemoveMultiplier(_G.ACTIONS.CHOP)
                        player.components.workmultiplier:RemoveMultiplier(_G.ACTIONS.HAMMER)
                    end
                end
            end
        end
    },
    {
        id = "DEBUFF_009",
        name = "倒霉蛋",
        description = "你今天特别倒霉，击杀生物有50%几率不掉落物品...",
        fn = function(player)
            local old_onkilledother = player.OnKilledOther
            player.OnKilledOther = function(inst, data)
                if old_onkilledother then
                    old_onkilledother(inst, data)
                end
                
                if data and data.victim and data.victim.components.lootdropper then
                    if _G.math.random() < 0.5 then
                        data.victim.components.lootdropper.loot = {}
                    end
                end
            end
            
            return function()
                if player:IsValid() then
                    player.OnKilledOther = old_onkilledother
                end
            end
        end
    },
    {
        id = "DEBUFF_010",
        name = "噪音制造者",
        description = "你总是不自觉地发出噪音，会吸引敌对生物靠近...",
        fn = function(player)
            local task = player:DoPeriodicTask(120, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    player.components.talker:Say("我感觉有东西在靠近...")
                    
                    local monsters = {"hound", "spider", "killerbee"}
                    local monster = monsters[_G.math.random(#monsters)]
                    local count = _G.math.random(2, 4)
                    
                    for i = 1, count do
                        local angle = _G.math.random() * 2 * _G.math.pi
                        local dist = _G.math.random(10, 15)
                        local spawn_x = x + dist * _G.math.cos(angle)
                        local spawn_z = z + dist * _G.math.sin(angle)
                        
                        local monster_inst = _G.SpawnPrefab(monster)
                        if monster_inst then
                            monster_inst.Transform:SetPosition(spawn_x, 0, spawn_z)
                            if monster_inst.components.combat then
                                monster_inst.components.combat:SetTarget(player)
                            end
                        end
                    end
                end
            end)
            
            return function()
                if task then task:Cancel() end
            end
        end
    },
    {
        id = "DEBUFF_011",
        name = "方向混乱",
        description = "你的方向感完全紊乱，移动方向会变得相反...",
        fn = function(player)
            if not player.components.locomotor then return end
            
            -- 保存原始控制函数
            local old_GetControlMods = player.components.locomotor.GetControlMods
            player.components.locomotor.GetControlMods = function(self)
                local forward, sideways = old_GetControlMods(self)
                -- 反转移动方向
                return -forward, -sideways
            end
            
            -- 返回清理函数
            return function()
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.GetControlMods = old_GetControlMods
                    DebugLog(3, "清理方向混乱效果")
                end
            end
        end
    },
    {
        id = "DEBUFF_012",
        name = "物品腐蚀",
        description = "你手中的工具会逐渐损坏，耐久度降低得更快...",
        fn = function(player)
            local task = player:DoPeriodicTask(60, function()
                if player:IsValid() and player.components.inventory then
                    local item = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if item and item.components.finiteuses then
                        item.components.finiteuses:Use(10)
                    end
                end
            end)
            
            return function()
                if task then task:Cancel() end
            end
        end
    },
    {
        id = "DEBUFF_013",
        name = "幻影追击",
        description = "可怕的暗影生物会定期出现在你周围...",
        fn = function(player)
            local function SpawnPhantom()
                if not player:IsValid() then return end
                
                local phantom = _G.SpawnPrefab("shadowcreature")
                if phantom then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * _G.PI
                    local spawn_dist = 15
                    phantom.Transform:SetPosition(
                        x + math.cos(angle)*spawn_dist, 
                        0, 
                        z + math.sin(angle)*spawn_dist
                    )
                    if phantom.components.combat then
                        phantom.components.combat:SetTarget(player)
                    end
                end
            end
            
            local task = player:DoPeriodicTask(120, SpawnPhantom)
            
            return function()
                if task then 
                    task:Cancel() 
                    DebugLog(3, "清理幻影追击效果")
                end
            end
        end
    },
    {
        id = "DEBUFF_014",
        name = "感官失调",
        description = "你的生命值和饥饿值会随机互换，非常混乱...",
        fn = function(player)
            local task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    if player.components.health and player.components.hunger then
                        local health = player.components.health.currenthealth
                        local hunger = player.components.hunger.current
                        player.components.health:SetCurrentHealth(hunger)
                        player.components.hunger:SetCurrent(health)
                    end
                end
            end)
            
            return function()
                if task then task:Cancel() end
            end
        end
    },
    {
        id = "DEBUFF_015",
        name = "物品掉落",
        description = "你的物品总是不自觉地从背包中掉落...",
        fn = function(player)
            local drop_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    if #items > 0 then
                        local item = items[math.random(#items)]
                        if item then
                            player.components.inventory:DropItem(item)
                            if TheNet:GetIsServer() then
                                TheNet:SystemMessage("玩家 " .. player.name .. " 的物品突然掉落了！")
                            end
                        end
                    end
                end
            end)
            
            return function()
                if drop_task then
                    drop_task:Cancel()
                    DebugLog(3, "清理物品掉落效果")
                end
            end
        end
    },
    {
        id = "DEBUFF_016",
        name = "幻影追踪",
        description = "可怕的幻影会追踪你",
        fn = function(player)
            local shadow_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local shadow = SpawnPrefab("terrorbeak")
                    
                    if shadow then
                        shadow.Transform:SetPosition(x + 15, 0, z + 15)
                        shadow:DoTaskInTime(15, function() 
                            if shadow and shadow:IsValid() then
                                shadow:Remove() 
                            end
                        end)
                        
                        if shadow.components.combat then
                            shadow.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if shadow_task then
                    shadow_task:Cancel()
                    DebugLog(3, "清理幻影追踪效果")
                end
            end
        end
    },
    {
        id = "DEBUFF_017",
        name = "饥饿幻觉",
        description = "你的饥饿值显示不准确",
        fn = function(player)
            if player.components.hunger then
                local old_GetPercent = player.components.hunger.GetPercent
                player.components.hunger.GetPercent = function(self)
                    return old_GetPercent(self) * 0.5
                end
                
                return function()
                    if player:IsValid() and player.components.hunger then
                        player.components.hunger.GetPercent = old_GetPercent
                        DebugLog(3, "清理饥饿幻觉效果")
                    end
                end
            end
            return function() end
        end
    },
    {
        id = "DEBUFF_018",
        name = "工具易碎",
        description = "你的工具更容易损坏",
        fn = function(player)
            local old_fn = nil
            if player.components.inventory then
                old_fn = player.components.inventory.DropItem
                player.components.inventory.DropItem = function(self, item, ...)
                    if item and item.components.finiteuses then
                        local current = item.components.finiteuses:GetPercent()
                        item.components.finiteuses:SetPercent(current * 0.8)
                    end
                    return old_fn(self, item, ...)
                end
            end
            
            -- 使用工具时额外消耗耐久
            local old_use_item = ACTIONS.CHOP.fn
            ACTIONS.CHOP.fn = function(act)
                local result = old_use_item(act)
                if act.doer == player and act.invobject and act.invobject.components.finiteuses then
                    act.invobject.components.finiteuses:Use(2)
                end
                return result
            end
            
            return function()
                if player:IsValid() and player.components.inventory and old_fn then
                    player.components.inventory.DropItem = old_fn
                end
                ACTIONS.CHOP.fn = old_use_item
                DebugLog(3, "清理工具易碎效果")
            end
        end
    },
    {
        id = "DEBUFF_019",
        name = "幽灵缠身",
        description = "几个幽灵会一直跟随着你，降低你的理智值...",
        fn = function(player)
            -- 定期生成幽灵跟随玩家
            local ghosts = {}
            local max_ghosts = 3
            
            local ghost_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and #ghosts < max_ghosts then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local ghost = SpawnPrefab("ghost")
                    
                    if ghost then
                        -- 设置位置
                        local angle = math.random() * 2 * PI
                        local radius = 5
                        ghost.Transform:SetPosition(
                            x + radius * math.cos(angle),
                            0,
                            z + radius * math.sin(angle)
                        )
                        
                        -- 让幽灵跟随玩家
                        local follow_task = ghost:DoPeriodicTask(1, function()
                            if player:IsValid() and ghost:IsValid() then
                                local px, py, pz = player.Transform:GetWorldPosition()
                                local gx, gy, gz = ghost.Transform:GetWorldPosition()
                                local dist = math.sqrt((px-gx)^2 + (pz-gz)^2)
                                
                                if dist > 15 then
                                    -- 瞬移到玩家附近
                                    local angle = math.random() * 2 * PI
                                    ghost.Transform:SetPosition(
                                        px + 5 * math.cos(angle),
                                        0,
                                        pz + 5 * math.sin(angle)
                                    )
                                elseif dist > 3 then
                                    -- 向玩家移动
                                    if ghost.components.locomotor then
                                        ghost.components.locomotor:GoToPoint(Vector3(px, py, pz))
                                    end
                                end
                            end
                        end)
                        
                        -- 降低玩家理智
                        if player.components.sanity then
                            player.components.sanity:DoDelta(-5)
                        end
                        
                        table.insert(ghosts, {ghost = ghost, follow_task = follow_task})
                    end
                end
            end)
            
            return function()
                for _, ghost_data in ipairs(ghosts) do
                    if ghost_data.follow_task then
                        ghost_data.follow_task:Cancel()
                    end
                    if ghost_data.ghost and ghost_data.ghost:IsValid() then
                        ghost_data.ghost:Remove()
                    end
                end
                if ghost_task then
                    ghost_task:Cancel()
                end
                DebugLog(3, "清理幽灵缠身效果")
            end
        end
    },
    {
        id = "DEBUFF_020",
        name = "时间错乱",
        description = "你周围的时间流速变得不稳定，白天和黑夜的长度会随机变化...",
        fn = function(player)
            -- 玩家周围的时间流速不稳定
            local time_task = player:DoPeriodicTask(30, function()
                if player:IsValid() and _G.TheWorld then
                    -- 随机时间效果
                    local effect = math.random(3)
                    
                    if effect == 1 then
                        -- 时间加速
                        _G.TheWorld:PushEvent("ms_setclocksegs", {day = 8, dusk = 2, night = 2})
                        if player.components.talker then
                            player.components.talker:Say("时间似乎加速了！")
                        end
                    elseif effect == 2 then
                        -- 时间减慢
                        _G.TheWorld:PushEvent("ms_setclocksegs", {day = 4, dusk = 6, night = 6})
                        if player.components.talker then
                            player.components.talker:Say("时间似乎减慢了...")
                        end
                    else
                        -- 恢复正常
                        _G.TheWorld:PushEvent("ms_setclocksegs", {day = 6, dusk = 4, night = 2})
                        if player.components.talker then
                            player.components.talker:Say("时间恢复正常了")
                        end
                    end
                end
            end)
            
            return function()
                if time_task then
                    time_task:Cancel()
                end
                -- 恢复正常时间设置
                if _G.TheWorld then
                    _G.TheWorld:PushEvent("ms_setclocksegs", {day = 6, dusk = 4, night = 2})
                end
                DebugLog(3, "清理时间错乱效果")
            end
        end
    },
    {
        id = "DEBUFF_021",
        name = "噩梦入侵",
        description = "噩梦生物会随机出现在你周围，并试图攻击你...",
        fn = function(player)
            -- 玩家周围会随机出现噩梦生物的幻影
            local nightmare_task = player:DoPeriodicTask(45, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    
                    -- 创建噩梦生物
                    local nightmare_creatures = {"crawlinghorror", "terrorbeak", "nightmarebeak"}
                    local creature = SpawnPrefab(nightmare_creatures[math.random(#nightmare_creatures)])
                    
                    if creature then
                        -- 设置位置
                        local offset = 10
                        creature.Transform:SetPosition(
                            x + math.random(-offset, offset),
                            0,
                            z + math.random(-offset, offset)
                        )
                        
                        -- 设置目标
                        if creature.components.combat then
                            creature.components.combat:SetTarget(player)
                        end
                        
                        -- 一段时间后消失
                        creature:DoTaskInTime(20, function()
                            if creature and creature:IsValid() then
                                local fx = SpawnPrefab("shadow_despawn")
                                if fx then
                                    local cx, cy, cz = creature.Transform:GetWorldPosition()
                                    fx.Transform:SetPosition(cx, cy, cz)
                                end
                                creature:Remove()
                            end
                        end)
                        
                        -- 降低玩家理智
                        if player.components.sanity then
                            player.components.sanity:DoDelta(-10)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("噩梦正在入侵现实！")
                        end
                    end
                end
            end)
            
            return function()
                if nightmare_task then
                    nightmare_task:Cancel()
                end
                DebugLog(3, "清理噩梦入侵效果")
            end
        end
    },                            
    {
        id = "DEBUFF_022",
        name = "失重状态",
        description = "你时不时会失去重力，漂浮在空中，物品也容易掉落...",
        fn = function(player)
            -- 修改玩家的物理属性
            local old_mass = player.Physics:GetMass()
            player.Physics:SetMass(0.1)
            
            -- 随机浮空效果
            local float_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    -- 玩家突然"浮起"
                    if player.components.talker then
                        player.components.talker:Say("我感觉自己要飘起来了！")
                    end
                    
                    -- 创建浮空效果
                    local float_time = 3
                    local start_time = GetTime()
                    local start_y = 0
                    
                    player:StartThread(function()
                        while GetTime() - start_time < float_time do
                            local t = (GetTime() - start_time) / float_time
                            local height = math.sin(t * math.pi) * 3 -- 最高浮到3个单位高
                            
                            local x, _, z = player.Transform:GetWorldPosition()
                            player.Transform:SetPosition(x, height, z)
                            
                            Sleep(FRAMES)
                        end
                        
                        -- 回到地面
                        local x, _, z = player.Transform:GetWorldPosition()
                        player.Transform:SetPosition(x, 0, z)
                    end)
                end
            end)
            
            -- 物品经常从玩家手中掉落
            local drop_task = player:DoPeriodicTask(20, function()
                if player:IsValid() and player.components.inventory then
                    local equipped = player.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    if equipped then
                        player.components.inventory:DropItem(equipped)
                        if player.components.talker then
                            player.components.talker:Say("我抓不住东西了！")
                        end
                    end
                end
            end)
            
            return function()
                if float_task then
                    float_task:Cancel()
                end
                if drop_task then
                    drop_task:Cancel()
                end
                if player:IsValid() and player.Physics then
                    player.Physics:SetMass(old_mass)
                    -- 确保玩家回到地面
                    local x, _, z = player.Transform:GetWorldPosition()
                    player.Transform:SetPosition(x, 0, z)
                end
                DebugLog(3, "清理失重状态效果")
            end
        end
    },
    {
        id = "DEBUFF_023",
        name = "雷电吸引",
        description = "你变成了移动的避雷针，经常会吸引闪电劈向你...",
        fn = function(player)
            -- 有几率在玩家附近落雷
            local lightning_task = player:DoPeriodicTask(30, function()
                if player:IsValid() and math.random() < 0.5 then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local offset = 3
                    local lightning_x = x + math.random(-offset, offset)
                    local lightning_z = z + math.random(-offset, offset)
                    
                    -- 创建闪电
                    local lightning = SpawnPrefab("lightning")
                    if lightning then
                        lightning.Transform:SetPosition(lightning_x, 0, lightning_z)
                        
                        -- 对玩家造成伤害
                        if math.random() < 0.3 and player.components.health then
                            player.components.health:DoDelta(-5)
                            if player.components.talker then
                                player.components.talker:Say("我好像吸引了雷电！")
                            end
                        end
                    end
                end
            end)
            
            return function()
                if lightning_task then
                    lightning_task:Cancel()
                    DebugLog(3, "清理雷电吸引效果")
                end
            end
        end
    },
    {
        id = "DEBUFF_024",
        name = "食物变质",
        description = "你的背包中的食物会加速腐烂，新获得的食物也会部分变质！",
        fn = function(player)
            -- 定期使背包中的食物腐烂
            local spoil_task = player:DoPeriodicTask(30, function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    for _, item in pairs(items) do
                        if item and item.components.perishable then
                            local current = item.components.perishable:GetPercent()
                            item.components.perishable:SetPercent(current * 0.7) -- 加速腐烂30%
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("我的食物好像在加速腐烂...")
                    end
                end
            end)
            
            -- 新获得的食物部分变质
            local old_give = player.components.inventory.GiveItem
            player.components.inventory.GiveItem = function(self, item, ...)
                if item and item.components.perishable then
                    local current = item.components.perishable:GetPercent()
                    item.components.perishable:SetPercent(current * 0.5) -- 新食物直接腐烂一半
                end
                return old_give(self, item, ...)
            end
            
            return function()
                if spoil_task then
                    spoil_task:Cancel()
                end
                if player:IsValid() and player.components.inventory then
                    player.components.inventory.GiveItem = old_give
                end
                DebugLog(3, "清理食物变质效果")
            end
        end
    },
    {
        id = "DEBUFF_025",
        name = "物品闹鬼",
        description = "你的物品会突然移动位置，有时甚至会自己使用！",
        fn = function(player)
            -- 定期随机交换背包中的物品位置
            local swap_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    if #items >= 2 then
                        local idx1 = math.random(#items)
                        local idx2 = idx1
                        while idx2 == idx1 do
                            idx2 = math.random(#items)
                        end
                        
                        local item1 = items[idx1]
                        local item2 = items[idx2]
                        
                        -- 交换位置
                        local slot1 = player.components.inventory:GetItemSlot(item1)
                        local slot2 = player.components.inventory:GetItemSlot(item2)
                        
                        player.components.inventory:RemoveItem(item1)
                        player.components.inventory:RemoveItem(item2)
                        
                        player.components.inventory:GiveItem(item1, slot2)
                        player.components.inventory:GiveItem(item2, slot1)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的物品在自己移动位置！")
                        end
                    end
                end
            end)
            
            -- 随机自动使用物品
            local use_task = player:DoPeriodicTask(120, function()
                if player:IsValid() and player.components.inventory and math.random() < 0.3 then
                    local items = player.components.inventory:GetItems()
                    if #items > 0 then
                        local item = items[math.random(#items)]
                        if item and item.components.useitem then
                            item.components.useitem:StartUsingItem()
                            
                            if player.components.talker then
                                player.components.talker:Say("我的" .. (STRINGS.NAMES[string.upper(item.prefab)] or "物品") .. "自己启动了！")
                            end
                        end
                    end
                end
            end)
            
            return function()
                if swap_task then
                    swap_task:Cancel()
                end
                if use_task then
                    use_task:Cancel()
                end
                DebugLog(3, "清理物品闹鬼效果")
            end
        end
    },
    {
        id = "DEBUFF_026",
        name = "昼夜倒置",
        description = "你的昼夜感知完全倒置，白天变成黑夜，黑夜变成白天！",
        fn = function(player)
            -- 添加噩梦滤镜
            if player.components.playervision then
                player.components.playervision:SetCustomCCTable({
                    day = {brightness = -0.1, contrast = 0.8, saturation = 0.5},
                    dusk = {brightness = 0, contrast = 1, saturation = 0.8},
                    night = {brightness = 0.1, contrast = 1.2, saturation = 1.2}
                })
            end
            
            -- 改变玩家的夜视能力
            local old_nightvision = player.components.vision and player.components.vision.nightvision or 0
            if player.components.vision then
                player.components.vision.nightvision = 1 - old_nightvision
            end
            
            -- 如果是怪物，在白天会被追踪，晚上则安全
            if player.components.sanity then
                local old_night_drain = player.components.sanity.night_drain_mult
                local old_day_gain = player.components.sanity.day_gain_mult
                
                player.components.sanity.night_drain_mult = -old_night_drain
                player.components.sanity.day_gain_mult = -old_day_gain
            end
            
            return function()
                if player:IsValid() then
                    if player.components.playervision then
                        player.components.playervision:SetCustomCCTable(nil)
                    end
                    if player.components.vision then
                        player.components.vision.nightvision = old_nightvision
                    end
                    if player.components.sanity then
                        player.components.sanity.night_drain_mult = old_night_drain
                        player.components.sanity.day_gain_mult = old_day_gain
                    end
                end
                DebugLog(3, "清理昼夜倒置效果")
            end
        end
    },
    {
        id = "DEBUFF_027",
        name = "混乱视觉",
        description = "你的视野突然变得扭曲，看东西都变得很难！",
        fn = function(player)
            -- 添加扭曲滤镜
            if player.components.playervision then
                player.components.playervision:SetDistortionEnabled(true)
                player.components.playervision:SetDistortion(0.5, 0.5)
            end
            
            -- 随机变化扭曲程度
            local distort_task = player:DoPeriodicTask(5, function()
                if player:IsValid() and player.components.playervision then
                    local distort_amount = 0.3 + math.random() * 0.4
                    player.components.playervision:SetDistortion(distort_amount, distort_amount)
                end
            end)
            
            return function()
                if player:IsValid() and player.components.playervision then
                    player.components.playervision:SetDistortionEnabled(false)
                end
                if distort_task then
                    distort_task:Cancel()
                end
                DebugLog(3, "清理混乱视觉效果")
            end
        end
    },
    {
        id = "DEBUFF_028",
        name = "随机传送",
        description = "你会在随机时间被传送到随机位置，这让你感到不安...",
        fn = function(player)
            local teleport_task = player:DoPeriodicTask(math.random(10, 20), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(5, 15)
                    local new_x = x + math.cos(angle) * distance
                    local new_z = z + math.sin(angle) * distance
                    
                    local fx = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx then
                        fx.Transform:SetPosition(x, y, z)
                    end
                    
                    player.Transform:SetPosition(new_x, y, new_z)
                    
                    local fx2 = SpawnPrefab("lavaarena_creature_teleport_small_fx")
                    if fx2 then
                        fx2.Transform:SetPosition(new_x, y, new_z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("我被传送了！")
                    end
                end
            end)
            
            return function()
                if teleport_task then
                    teleport_task:Cancel()
                end
                DebugLog(3, "清理随机传送效果")
            end
        end
    },
    {
        id = "DEBUFF_029",
        name = "随机掉落",
        description = "你会在随机时间掉落随机物品，这让你感到困扰...",
        fn = function(player)
            local drop_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    if #items > 0 then
                        local random_item = items[math.random(#items)]
                        player.components.inventory:DropItem(random_item)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的物品掉了！")
                        end
                    end
                end
            end)
            
            return function()
                if drop_task then
                    drop_task:Cancel()
                end
                DebugLog(3, "清理随机掉落效果")
            end
        end
    },
    {
        id = "DEBUFF_030",
        name = "随机饥饿",
        description = "你会在随机时间感到饥饿，这让你感到不安...",
        fn = function(player)
            local hunger_task = player:DoPeriodicTask(math.random(10, 20), function()
                if player:IsValid() and player.components.hunger then
                    player.components.hunger:DoDelta(-20)
                    
                    if player.components.talker then
                        player.components.talker:Say("我好饿！")
                    end
                end
            end)
            
            return function()
                if hunger_task then
                    hunger_task:Cancel()
                end
                DebugLog(3, "清理随机饥饿效果")
            end
        end
    },
    {
        id = "DEBUFF_031",
        name = "随机理智",
        description = "你会在随机时间失去理智，这让你感到恐惧...",
        fn = function(player)
            local sanity_task = player:DoPeriodicTask(math.random(10, 20), function()
                if player:IsValid() and player.components.sanity then
                    player.components.sanity:DoDelta(-20)
                    
                    if player.components.talker then
                        player.components.talker:Say("我的理智在流失！")
                    end
                end
            end)
            
            return function()
                if sanity_task then
                    sanity_task:Cancel()
                end
                DebugLog(3, "清理随机理智效果")
            end
        end
    },
    {
        id = "DEBUFF_032",
        name = "随机生命",
        description = "你会在随机时间失去生命值，这让你感到痛苦...",
        fn = function(player)
            local health_task = player:DoPeriodicTask(math.random(10, 20), function()
                if player:IsValid() and player.components.health then
                    player.components.health:DoDelta(-10)
                    
                    if player.components.talker then
                        player.components.talker:Say("好痛！")
                    end
                end
            end)
            
            return function()
                if health_task then
                    health_task:Cancel()
                end
                DebugLog(3, "清理随机生命效果")
            end
        end
    },
    {
        id = "DEBUFF_033",
        name = "随机天气",
        description = "你会在随机时间改变天气，这让你感到不适...",
        fn = function(player)
            local weather_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local weathers = {
                        {name = "雨天", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                            end
                        end},
                        {name = "雷暴", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                                _G.TheWorld.components.lightning:StartLightning()
                            end
                        end},
                        {name = "暴风雪", fn = function() 
                            if _G.TheWorld.components.rain then
                                _G.TheWorld.components.rain:StartRain()
                                _G.TheWorld.components.snow:StartSnow()
                            end
                        end}
                    }
                    
                    local weather = weathers[math.random(#weathers)]
                    weather.fn()
                    
                    if player.components.talker then
                        player.components.talker:Say("天气变了！")
                    end
                end
            end)
            
            return function()
                if weather_task then
                    weather_task:Cancel()
                end
                if _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StopRain()
                end
                DebugLog(3, "清理随机天气效果")
            end
        end
    },
    {
        id = "DEBUFF_034",
        name = "随机生物",
        description = "你会在随机时间遇到随机生物，这让你感到恐惧...",
        fn = function(player)
            local creature_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local creatures = {
                        "spider",
                        "bee",
                        "tentacle",
                        "treeguard",
                        "deerclops",
                        "bearger",
                        "dragonfly"
                    }
                    
                    local creature = creatures[math.random(#creatures)]
                    
                    local new_creature = SpawnPrefab(creature)
                    if new_creature then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local distance = math.random(5, 15)
                        local new_x = x + math.cos(angle) * distance
                        local new_z = z + math.sin(angle) * distance
                        
                        new_creature.Transform:SetPosition(new_x, y, new_z)
                        
                        if player.components.talker then
                            player.components.talker:Say("有怪物！")
                        end
                    end
                end
            end)
            
            return function()
                if creature_task then
                    creature_task:Cancel()
                end
                DebugLog(3, "清理随机生物效果")
            end
        end
    },
    {
        id = "DEBUFF_035",
        name = "随机状态",
        description = "你会在随机时间获得随机状态，这让你感到不适...",
        fn = function(player)
            local state_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() then
                    local states = {
                        function() -- 减速
                            if player.components.locomotor then
                                player.components.locomotor.walkspeed = player.components.locomotor.walkspeed * 0.5
                                if player.components.talker then
                                    player.components.talker:Say("我走不动了！")
                                end
                            end
                        end,
                        function() -- 变小
                            if player.components.health then
                                player.components.health:SetMaxHealth(player.components.health.maxhealth * 0.5)
                                player.components.health:DoDelta(player.components.health.maxhealth)
                                player.Transform:SetScale(0.5, 0.5, 0.5)
                                if player.components.talker then
                                    player.components.talker:Say("我变小了！")
                                end
                            end
                        end,
                        function() -- 失明
                            if player.components.playercontroller then
                                player.components.playercontroller:EnableMapControls(false)
                                if player.components.talker then
                                    player.components.talker:Say("我看不见了！")
                                end
                            end
                        end
                    }
                    
                    states[math.random(#states)]()
                    
                    -- 5秒后恢复
                    player:DoTaskInTime(5, function()
                        if player:IsValid() then
                            if player.components.locomotor then
                                player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                            end
                            if player.components.health then
                                player.components.health:SetMaxHealth(TUNING.WILSON_HEALTH)
                                player.components.health:DoDelta(player.components.health.maxhealth)
                                player.Transform:SetScale(1, 1, 1)
                            end
                            if player.components.playercontroller then
                                player.components.playercontroller:EnableMapControls(true)
                            end
                        end
                    end)
                end
            end)
            
            return function()
                if state_task then
                    state_task:Cancel()
                end
                if player:IsValid() then
                    if player.components.locomotor then
                        player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                    end
                    if player.components.health then
                        player.components.health:SetMaxHealth(TUNING.WILSON_HEALTH)
                        player.components.health:DoDelta(player.components.health.maxhealth)
                        player.Transform:SetScale(1, 1, 1)
                    end
                    if player.components.playercontroller then
                        player.components.playercontroller:EnableMapControls(true)
                    end
                end
                DebugLog(3, "清理随机状态效果")
            end
        end
    },
    {
        id = "DEBUFF_036",
        name = "随机技能",
        description = "你会在随机时间失去随机技能，这让你感到无助...",
        fn = function(player)
            local skill_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local skills = {
                        function() -- 失去攻击能力
                            if player.components.combat then
                                local old_damage = player.components.combat.damagemultiplier or 1
                                player.components.combat.damagemultiplier = 0
                                if player.components.talker then
                                    player.components.talker:Say("我无法攻击了！")
                                end
                                
                                -- 5秒后恢复
                                player:DoTaskInTime(5, function()
                                    if player:IsValid() and player.components.combat then
                                        player.components.combat.damagemultiplier = old_damage
                                    end
                                end)
                            end
                        end,
                        function() -- 失去移动能力
                            if player.components.locomotor then
                                local old_speed = player.components.locomotor.walkspeed
                                player.components.locomotor.walkspeed = 0
                                if player.components.talker then
                                    player.components.talker:Say("我无法移动了！")
                                end
                                
                                -- 5秒后恢复
                                player:DoTaskInTime(5, function()
                                    if player:IsValid() and player.components.locomotor then
                                        player.components.locomotor.walkspeed = old_speed
                                    end
                                end)
                            end
                        end,
                        function() -- 失去物品使用能力
                            if player.components.inventory then
                                local old_canuse = player.components.inventory.canuse
                                player.components.inventory.canuse = false
                                if player.components.talker then
                                    player.components.talker:Say("我无法使用物品了！")
                                end
                                
                                -- 5秒后恢复
                                player:DoTaskInTime(5, function()
                                    if player:IsValid() and player.components.inventory then
                                        player.components.inventory.canuse = old_canuse
                                    end
                                end)
                            end
                        end
                    }
                    
                    skills[math.random(#skills)]()
                end
            end)
            
            return function()
                if skill_task then
                    skill_task:Cancel()
                end
                DebugLog(3, "清理随机技能效果")
            end
        end
    },
    {
        id = "DEBUFF_037",
        name = "随机装备",
        description = "你会在随机时间失去随机装备，这让你感到不安...",
        fn = function(player)
            local equip_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    local equips = player.components.inventory:GetEquips()
                    if #equips > 0 then
                        local random_equip = equips[math.random(#equips)]
                        player.components.inventory:DropItem(random_equip)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的装备掉了！")
                        end
                    end
                end
            end)
            
            return function()
                if equip_task then
                    equip_task:Cancel()
                end
                DebugLog(3, "清理随机装备效果")
            end
        end
    },
    {
        id = "DEBUFF_038",
        name = "随机食物",
        description = "你会在随机时间失去随机食物，这让你感到饥饿...",
        fn = function(player)
            local food_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    local foods = player.components.inventory:GetItems()
                    local food_items = {}
                    for _, item in pairs(foods) do
                        if item.components.edible then
                            table.insert(food_items, item)
                        end
                    end
                    
                    if #food_items > 0 then
                        local random_food = food_items[math.random(#food_items)]
                        player.components.inventory:DropItem(random_food)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的食物掉了！")
                        end
                    end
                end
            end)
            
            return function()
                if food_task then
                    food_task:Cancel()
                end
                DebugLog(3, "清理随机食物效果")
            end
        end
    },
    {
        id = "DEBUFF_039",
        name = "随机工具",
        description = "你会在随机时间失去随机工具，这让你感到无助...",
        fn = function(player)
            local tool_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    local tools = player.components.inventory:GetItems()
                    local tool_items = {}
                    for _, item in pairs(tools) do
                        if item.components.tool then
                            table.insert(tool_items, item)
                        end
                    end
                    
                    if #tool_items > 0 then
                        local random_tool = tool_items[math.random(#tool_items)]
                        player.components.inventory:DropItem(random_tool)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的工具掉了！")
                        end
                    end
                end
            end)
            
            return function()
                if tool_task then
                    tool_task:Cancel()
                end
                DebugLog(3, "清理随机工具效果")
            end
        end
    },
    {
        id = "DEBUFF_040",
        name = "随机材料",
        description = "你会在随机时间失去随机材料，这让你感到困扰...",
        fn = function(player)
            local material_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() and player.components.inventory then
                    local materials = player.components.inventory:GetItems()
                    local material_items = {}
                    for _, item in pairs(materials) do
                        if item.components.stackable and not item.components.tool and not item.components.edible then
                            table.insert(material_items, item)
                        end
                    end
                    
                    if #material_items > 0 then
                        local random_material = material_items[math.random(#material_items)]
                        player.components.inventory:DropItem(random_material)
                        
                        if player.components.talker then
                            player.components.talker:Say("我的材料掉了！")
                        end
                    end
                end
            end)
            
            return function()
                if material_task then
                    material_task:Cancel()
                end
                DebugLog(3, "清理随机材料效果")
            end
        end
    },
    {
        id = "DEBUFF_041",
        name = "暗影缠身",
        description = "暗影生物会随机出现并攻击你，让你感到恐惧...",
        fn = function(player)
            local shadow_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() then
                    local shadows = {
                        "shadowcreature",
                        "shadowcreature2",
                        "shadowcreature3"
                    }
                    
                    local shadow = shadows[math.random(#shadows)]
                    local new_shadow = SpawnPrefab(shadow)
                    
                    if new_shadow then
                        local x, y, z = player.Transform:GetWorldPosition()
                        local angle = math.random() * 2 * math.pi
                        local distance = math.random(3, 8)
                        local new_x = x + math.cos(angle) * distance
                        local new_z = z + math.sin(angle) * distance
                        
                        new_shadow.Transform:SetPosition(new_x, y, new_z)
                        
                        if new_shadow.components.combat then
                            new_shadow.components.combat:SetTarget(player)
                        end
                        
                        if player.components.talker then
                            player.components.talker:Say("暗影生物！")
                        end
                    end
                end
            end)
            
            return function()
                if shadow_task then
                    shadow_task:Cancel()
                end
                DebugLog(3, "清理暗影缠身效果")
            end
        end
    },
    {
        id = "DEBUFF_042",
        name = "远古诅咒",
        description = "远古科技会随机失效，让你感到无助...",
        fn = function(player)
            local ancient_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local ancients = {
                        function() -- 失去暗影护甲效果
                            if player.components.health then
                                player.components.health:SetAbsorptionAmount(0)
                                if player.components.talker then
                                    player.components.talker:Say("我的护甲失效了！")
                                end
                            end
                        end,
                        function() -- 失去暗影武器效果
                            if player.components.combat then
                                local old_damage = player.components.combat.damagemultiplier or 1
                                player.components.combat.damagemultiplier = old_damage * 0.5
                                if player.components.talker then
                                    player.components.talker:Say("我的武器变弱了！")
                                end
                            end
                        end,
                        function() -- 失去暗影工具效果
                            if player.components.workmultiplier then
                                player.components.workmultiplier:SetMultiplier(0.5)
                                if player.components.talker then
                                    player.components.talker:Say("我的工具变慢了！")
                                end
                            end
                        end
                    }
                    
                    ancients[math.random(#ancients)]()
                    
                    -- 5秒后恢复
                    player:DoTaskInTime(5, function()
                        if player:IsValid() then
                            if player.components.health then
                                player.components.health:SetAbsorptionAmount(1)
                            end
                            if player.components.combat then
                                player.components.combat.damagemultiplier = 1
                            end
                            if player.components.workmultiplier then
                                player.components.workmultiplier:SetMultiplier(1)
                            end
                        end
                    end)
                end
            end)
            
            return function()
                if ancient_task then
                    ancient_task:Cancel()
                end
                DebugLog(3, "清理远古诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_043",
        name = "月岛之痛",
        description = "月岛的力量会随机反噬你，让你感到痛苦...",
        fn = function(player)
            local moon_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() then
                    local moons = {
                        function() -- 月岛之痛
                            if player.components.health then
                                player.components.health:DoDelta(-15)
                                if player.components.talker then
                                    player.components.talker:Say("月岛之力在伤害我！")
                                end
                            end
                        end,
                        function() -- 月岛之狂
                            if player.components.sanity then
                                player.components.sanity:DoDelta(-30)
                                if player.components.talker then
                                    player.components.talker:Say("月岛之力让我发狂！")
                                end
                            end
                        end,
                        function() -- 月岛之弱
                            if player.components.combat then
                                local old_damage = player.components.combat.damagemultiplier or 1
                                player.components.combat.damagemultiplier = old_damage * 0.3
                                if player.components.talker then
                                    player.components.talker:Say("月岛之力让我变弱了！")
                                end
                            end
                        end
                    }
                    
                    moons[math.random(#moons)]()
                    
                    -- 5秒后恢复
                    player:DoTaskInTime(5, function()
                        if player:IsValid() and player.components.combat then
                            player.components.combat.damagemultiplier = 1
                        end
                    end)
                end
            end)
            
            return function()
                if moon_task then
                    moon_task:Cancel()
                end
                DebugLog(3, "清理月岛之痛效果")
            end
        end
    },
    {
        id = "DEBUFF_044",
        name = "蜂后之怒",
        description = "蜂后会随机召唤蜜蜂攻击你，让你感到恐惧...",
        fn = function(player)
            local bee_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local bees = {
                        "bee",
                        "killerbee"
                    }
                    
                    for i = 1, math.random(3, 8) do
                        local bee = bees[math.random(#bees)]
                        local new_bee = SpawnPrefab(bee)
                        
                        if new_bee then
                            local x, y, z = player.Transform:GetWorldPosition()
                            local angle = math.random() * 2 * math.pi
                            local distance = math.random(5, 15)
                            local new_x = x + math.cos(angle) * distance
                            local new_z = z + math.sin(angle) * distance
                            
                            new_bee.Transform:SetPosition(new_x, y, new_z)
                            
                            if new_bee.components.combat then
                                new_bee.components.combat:SetTarget(player)
                            end
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("蜜蜂！好多蜜蜂！")
                    end
                end
            end)
            
            return function()
                if bee_task then
                    bee_task:Cancel()
                end
                DebugLog(3, "清理蜂后之怒效果")
            end
        end
    },
    {
        id = "DEBUFF_045",
        name = "猪人之敌",
        description = "猪人会随机对你产生敌意，让你感到不安...",
        fn = function(player)
            local pig_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 30, {"pigman"})
                    
                    for _, pig in pairs(pigs) do
                        if pig.components.combat then
                            pig.components.combat:SetTarget(player)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("猪人变得敌对了！")
                    end
                end
            end)
            
            return function()
                if pig_task then
                    pig_task:Cancel()
                end
                DebugLog(3, "清理猪人之敌效果")
            end
        end
    },
    {
        id = "DEBUFF_046",
        name = "鱼人之惧",
        description = "你会在水中感到恐惧，让你无法游泳...",
        fn = function(player)
            local fish_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local tile = TheWorld.Map:GetTileAtPoint(x, y, z)
                    
                    if tile == GLOBAL.GROUND.OCEAN_SWELL or tile == GLOBAL.GROUND.OCEAN_ROUGH or tile == GLOBAL.GROUND.OCEAN_BRINEPOOL then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = 0
                            if player.components.talker then
                                player.components.talker:Say("我不敢下水！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if fish_task then
                    fish_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理鱼人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_047",
        name = "蜘蛛之网",
        description = "蜘蛛会随机在你周围结网，让你感到困扰...",
        fn = function(player)
            local spider_task = player:DoPeriodicTask(math.random(15, 30), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(3, 8)
                    local new_x = x + math.cos(angle) * distance
                    local new_z = z + math.sin(angle) * distance
                    
                    local web = SpawnPrefab("spider_web")
                    if web then
                        web.Transform:SetPosition(new_x, y, new_z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("蜘蛛网！")
                    end
                end
            end)
            
            return function()
                if spider_task then
                    spider_task:Cancel()
                end
                DebugLog(3, "清理蜘蛛之网效果")
            end
        end
    },
    {
        id = "DEBUFF_048",
        name = "树人之怒",
        description = "树人会随机对你产生敌意，让你感到恐惧...",
        fn = function(player)
            local tree_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local trees = TheSim:FindEntities(x, y, z, 30, {"tree"})
                    
                    for _, tree in pairs(trees) do
                        if tree.components.growable and tree.components.growable.stage == 3 then
                            local treeguard = SpawnPrefab("treeguard")
                            if treeguard then
                                treeguard.Transform:SetPosition(tree.Transform:GetWorldPosition())
                                tree:Remove()
                                
                                if treeguard.components.combat then
                                    treeguard.components.combat:SetTarget(player)
                                end
                            end
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("树人！")
                    end
                end
            end)
            
            return function()
                if tree_task then
                    tree_task:Cancel()
                end
                DebugLog(3, "清理树人之怒效果")
            end
        end
    },
    {
        id = "DEBUFF_049",
        name = "触手之惧",
        description = "触手会随机出现在你周围，让你感到恐惧...",
        fn = function(player)
            local tentacle_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(3, 8)
                    local new_x = x + math.cos(angle) * distance
                    local new_z = z + math.sin(angle) * distance
                    
                    local tentacle = SpawnPrefab("tentacle")
                    if tentacle then
                        tentacle.Transform:SetPosition(new_x, y, new_z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("触手！")
                    end
                end
            end)
            
            return function()
                if tentacle_task then
                    tentacle_task:Cancel()
                end
                DebugLog(3, "清理触手之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_050",
        name = "鱼人之敌",
        description = "鱼人会随机对你产生敌意，让你感到不安...",
        fn = function(player)
            local merm_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 30, {"merm"})
                    
                    for _, merm in pairs(merms) do
                        if merm.components.combat then
                            merm.components.combat:SetTarget(player)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("鱼人变得敌对了！")
                    end
                end
            end)
            
            return function()
                if merm_task then
                    merm_task:Cancel()
                end
                DebugLog(3, "清理鱼人之敌效果")
            end
        end
    },
    {
        id = "DEBUFF_051",
        name = "兔人之敌",
        description = "兔人会随机对你产生敌意，让你感到不安...",
        fn = function(player)
            local bunny_task = player:DoPeriodicTask(math.random(20, 40), function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnies = TheSim:FindEntities(x, y, z, 30, {"bunnyman"})
                    
                    for _, bunny in pairs(bunnies) do
                        if bunny.components.combat then
                            bunny.components.combat:SetTarget(player)
                        end
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("兔人变得敌对了！")
                    end
                end
            end)
            
            return function()
                if bunny_task then
                    bunny_task:Cancel()
                end
                DebugLog(3, "清理兔人之敌效果")
            end
        end
    },
    {
        id = "DEBUFF_052",
        name = "猪人之惧",
        description = "你会在猪人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local pig_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 10, {"pigman"})
                    
                    if #pigs > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近猪人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if pig_fear_task then
                    pig_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理猪人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_053",
        name = "鱼人之惧",
        description = "你会在鱼人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local merm_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 10, {"merm"})
                    
                    if #merms > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近鱼人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if merm_fear_task then
                    merm_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理鱼人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_054",
        name = "兔人之惧",
        description = "你会在兔人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local bunny_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnies = TheSim:FindEntities(x, y, z, 10, {"bunnyman"})
                    
                    if #bunnies > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近兔人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if bunny_fear_task then
                    bunny_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理兔人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_055",
        name = "猪人之惧",
        description = "你会在猪人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local pig_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 10, {"pigman"})
                    
                    if #pigs > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近猪人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if pig_fear_task then
                    pig_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理猪人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_056",
        name = "鱼人之惧",
        description = "你会在鱼人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local merm_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 10, {"merm"})
                    
                    if #merms > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近鱼人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if merm_fear_task then
                    merm_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理鱼人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_057",
        name = "兔人之惧",
        description = "你会在兔人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local bunny_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnies = TheSim:FindEntities(x, y, z, 10, {"bunnyman"})
                    
                    if #bunnies > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近兔人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if bunny_fear_task then
                    bunny_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理兔人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_058",
        name = "猪人之惧",
        description = "你会在猪人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local pig_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 10, {"pigman"})
                    
                    if #pigs > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近猪人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if pig_fear_task then
                    pig_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理猪人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_059",
        name = "鱼人之惧",
        description = "你会在鱼人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local merm_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 10, {"merm"})
                    
                    if #merms > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近鱼人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if merm_fear_task then
                    merm_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理鱼人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_060",
        name = "兔人之惧",
        description = "你会在兔人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local bunny_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnies = TheSim:FindEntities(x, y, z, 10, {"bunnyman"})
                    
                    if #bunnies > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近兔人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if bunny_fear_task then
                    bunny_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理兔人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_061",
        name = "猪人之怒",
        description = "猪人会对你产生敌意，主动攻击你...",
        fn = function(player)
            local pig_anger_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 15, {"pig"})
                    
                    for _, pig in ipairs(pigs) do
                        if pig.components.combat and not pig.components.combat:HasTarget() then
                            pig.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if pig_anger_task then
                    pig_anger_task:Cancel()
                end
                DebugLog(3, "清理猪人之怒效果")
            end
        end
    },
    {
        id = "DEBUFF_062",
        name = "蜘蛛之友",
        description = "蜘蛛会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local spider_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local spiders = TheSim:FindEntities(x, y, z, 20, {"spider"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, spider in ipairs(spiders) do
                        if spider.components.combat and spider.components.combat:HasTarget() then
                            spider.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if spider_friend_task then
                    spider_friend_task:Cancel()
                end
                DebugLog(3, "清理蜘蛛之友效果")
            end
        end
    },
    {
        id = "DEBUFF_063",
        name = "鱼人之歌",
        description = "你总是能听到鱼人的歌声，这让你无法集中注意力...",
        fn = function(player)
            local merm_song_task = player:DoPeriodicTask(5, function()
                if player:IsValid() and player.components.sanity then
                    player.components.sanity:DoDelta(-5)
                    if player.components.talker then
                        player.components.talker:Say("我听到了鱼人的歌声...")
                    end
                end
            end)
            
            return function()
                if merm_song_task then
                    merm_song_task:Cancel()
                end
                DebugLog(3, "清理鱼人之歌效果")
            end
        end
    },
    {
        id = "DEBUFF_064",
        name = "触手之舞",
        description = "触手会随机出现在你周围，让你感到不安...",
        fn = function(player)
            local tentacle_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(5, 10)
                    local spawn_x = x + math.cos(angle) * distance
                    local spawn_z = z + math.sin(angle) * distance
                    
                    local tentacle = SpawnPrefab("tentacle")
                    if tentacle then
                        tentacle.Transform:SetPosition(spawn_x, 0, spawn_z)
                        tentacle:DoTaskInTime(10, function()
                            if tentacle and tentacle:IsValid() then
                                tentacle:Remove()
                            end
                        end)
                    end
                end
            end)
            
            return function()
                if tentacle_task then
                    tentacle_task:Cancel()
                end
                DebugLog(3, "清理触手之舞效果")
            end
        end
    },
    {
        id = "DEBUFF_065",
        name = "树人觉醒",
        description = "周围的树木会突然变成树人，对你发起攻击...",
        fn = function(player)
            local treeguard_task = player:DoPeriodicTask(60, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local trees = TheSim:FindEntities(x, y, z, 20, {"tree"})
                    
                    if #trees > 0 then
                        local tree = trees[math.random(#trees)]
                        if tree and not tree:HasTag("burnt") then
                            local treeguard = SpawnPrefab("treeguard")
                            if treeguard then
                                treeguard.Transform:SetPosition(tree.Transform:GetWorldPosition())
                                tree:Remove()
                                if treeguard.components.combat then
                                    treeguard.components.combat:SetTarget(player)
                                end
                            end
                        end
                    end
                end
            end)
            
            return function()
                if treeguard_task then
                    treeguard_task:Cancel()
                end
                DebugLog(3, "清理树人觉醒效果")
            end
        end
    },
    {
        id = "DEBUFF_066",
        name = "蜜蜂之舞",
        description = "蜜蜂会把你当作蜂巢，不断围绕着你转圈...",
        fn = function(player)
            local bee_task = player:DoPeriodicTask(20, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bees = TheSim:FindEntities(x, y, z, 15, {"bee"})
                    
                    for _, bee in ipairs(bees) do
                        if bee.components.locomotor then
                            local angle = math.random() * 2 * math.pi
                            local radius = 3
                            local target_x = x + math.cos(angle) * radius
                            local target_z = z + math.sin(angle) * radius
                            bee.components.locomotor:GoToPoint(Vector3(target_x, 0, target_z))
                        end
                    end
                end
            end)
            
            return function()
                if bee_task then
                    bee_task:Cancel()
                end
                DebugLog(3, "清理蜜蜂之舞效果")
            end
        end
    },
    {
        id = "DEBUFF_067",
        name = "暗影之拥",
        description = "暗影生物会不断出现在你周围，试图拥抱你...",
        fn = function(player)
            local shadow_task = player:DoPeriodicTask(45, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local shadow = SpawnPrefab("shadowcreature")
                    
                    if shadow then
                        local angle = math.random() * 2 * math.pi
                        local distance = math.random(5, 10)
                        local spawn_x = x + math.cos(angle) * distance
                        local spawn_z = z + math.sin(angle) * distance
                        
                        shadow.Transform:SetPosition(spawn_x, 0, spawn_z)
                        if shadow.components.combat then
                            shadow.components.combat:SetTarget(player)
                        end
                        
                        shadow:DoTaskInTime(15, function()
                            if shadow and shadow:IsValid() then
                                shadow:Remove()
                            end
                        end)
                    end
                end
            end)
            
            return function()
                if shadow_task then
                    shadow_task:Cancel()
                end
                DebugLog(3, "清理暗影之拥效果")
            end
        end
    },
    {
        id = "DEBUFF_068",
        name = "鱼人之友",
        description = "鱼人会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local merm_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 20, {"merm"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, merm in ipairs(merms) do
                        if merm.components.combat and merm.components.combat:HasTarget() then
                            merm.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if merm_friend_task then
                    merm_friend_task:Cancel()
                end
                DebugLog(3, "清理鱼人之友效果")
            end
        end
    },
    {
        id = "DEBUFF_069",
        name = "猪人之友",
        description = "猪人会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local pig_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 20, {"pig"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, pig in ipairs(pigs) do
                        if pig.components.combat and pig.components.combat:HasTarget() then
                            pig.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if pig_friend_task then
                    pig_friend_task:Cancel()
                end
                DebugLog(3, "清理猪人之友效果")
            end
        end
    },
    {
        id = "DEBUFF_070",
        name = "兔人之友",
        description = "兔人会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local bunny_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bunnies = TheSim:FindEntities(x, y, z, 20, {"bunnyman"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, bunny in ipairs(bunnies) do
                        if bunny.components.combat and bunny.components.combat:HasTarget() then
                            bunny.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if bunny_friend_task then
                    bunny_friend_task:Cancel()
                end
                DebugLog(3, "清理兔人之友效果")
            end
        end
    },
    {
        id = "DEBUFF_071",
        name = "蜘蛛之惧",
        description = "你会在蜘蛛周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local spider_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local spiders = TheSim:FindEntities(x, y, z, 10, {"spider"})
                    
                    if #spiders > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近蜘蛛！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if spider_fear_task then
                    spider_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理蜘蛛之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_072",
        name = "鱼人之惧",
        description = "你会在鱼人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local merm_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local merms = TheSim:FindEntities(x, y, z, 10, {"merm"})
                    
                    if #merms > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近鱼人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if merm_fear_task then
                    merm_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理鱼人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_073",
        name = "猪人之惧",
        description = "你会在猪人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local pig_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local pigs = TheSim:FindEntities(x, y, z, 10, {"pig"})
                    
                    if #pigs > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近猪人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if pig_fear_task then
                    pig_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理猪人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_074",
        name = "触手之惧",
        description = "你会在触手周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local tentacle_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local tentacles = TheSim:FindEntities(x, y, z, 10, {"tentacle"})
                    
                    if #tentacles > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近触手！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if tentacle_fear_task then
                    tentacle_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理触手之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_075",
        name = "树人之惧",
        description = "你会在树人周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local treeguard_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local treeguards = TheSim:FindEntities(x, y, z, 10, {"treeguard"})
                    
                    if #treeguards > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近树人！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if treeguard_fear_task then
                    treeguard_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理树人之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_076",
        name = "蜜蜂之惧",
        description = "你会在蜜蜂周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local bee_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local bees = TheSim:FindEntities(x, y, z, 10, {"bee"})
                    
                    if #bees > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近蜜蜂！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if bee_fear_task then
                    bee_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理蜜蜂之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_077",
        name = "暗影之惧",
        description = "你会在暗影生物周围感到恐惧，让你无法靠近...",
        fn = function(player)
            local shadow_fear_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local shadows = TheSim:FindEntities(x, y, z, 10, {"shadowcreature"})
                    
                    if #shadows > 0 then
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED * 0.5
                            if player.components.talker then
                                player.components.talker:Say("我不敢靠近暗影生物！")
                            end
                        end
                    else
                        if player.components.locomotor then
                            player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                        end
                    end
                end
            end)
            
            return function()
                if shadow_fear_task then
                    shadow_fear_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor.walkspeed = TUNING.WILSON_WALK_SPEED
                end
                DebugLog(3, "清理暗影之惧效果")
            end
        end
    },
    {
        id = "DEBUFF_078",
        name = "触手之友",
        description = "触手会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local tentacle_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local tentacles = TheSim:FindEntities(x, y, z, 20, {"tentacle"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, tentacle in ipairs(tentacles) do
                        if tentacle.components.combat and tentacle.components.combat:HasTarget() then
                            tentacle.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if tentacle_friend_task then
                    tentacle_friend_task:Cancel()
                end
                DebugLog(3, "清理触手之友效果")
            end
        end
    },
    {
        id = "DEBUFF_079",
        name = "树人之友",
        description = "树人会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local treeguard_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local treeguards = TheSim:FindEntities(x, y, z, 20, {"treeguard"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, treeguard in ipairs(treeguards) do
                        if treeguard.components.combat and treeguard.components.combat:HasTarget() then
                            treeguard.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if treeguard_friend_task then
                    treeguard_friend_task:Cancel()
                end
                DebugLog(3, "清理树人之友效果")
            end
        end
    },
    {
        id = "DEBUFF_080",
        name = "暗影之友",
        description = "暗影生物会把你当作同类，但其他生物会对你产生敌意...",
        fn = function(player)
            local shadow_friend_task = player:DoPeriodicTask(1, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local shadows = TheSim:FindEntities(x, y, z, 20, {"shadowcreature"})
                    local other_mobs = TheSim:FindEntities(x, y, z, 20, {"monster"})
                    
                    for _, shadow in ipairs(shadows) do
                        if shadow.components.combat and shadow.components.combat:HasTarget() then
                            shadow.components.combat:SetTarget(nil)
                        end
                    end
                    
                    for _, mob in ipairs(other_mobs) do
                        if mob.components.combat and not mob.components.combat:HasTarget() then
                            mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if shadow_friend_task then
                    shadow_friend_task:Cancel()
                end
                DebugLog(3, "清理暗影之友效果")
            end
        end
    },
    {
        id = "DEBUFF_081",
        name = "月圆之怒",
        description = "在月圆之夜，你的理智会快速下降，并吸引暗影生物...",
        fn = function(player)
            local moon_task = player:DoPeriodicTask(1, function()
                if player:IsValid() and _G.TheWorld.state.isfullmoon then
                    if player.components.sanity then
                        player.components.sanity:DoDelta(-1)
                    end
                    
                    local x, y, z = player.Transform:GetWorldPosition()
                    local shadows = TheSim:FindEntities(x, y, z, 20, {"shadowcreature"})
                    for _, shadow in ipairs(shadows) do
                        if shadow.components.combat and not shadow.components.combat:HasTarget() then
                            shadow.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if moon_task then
                    moon_task:Cancel()
                end
                DebugLog(3, "清理月圆之怒效果")
            end
        end
    },
    {
        id = "DEBUFF_082",
        name = "暗影侵蚀",
        description = "你的理智值越低，移动速度越慢...",
        fn = function(player)
            local shadow_task = player:DoPeriodicTask(1, function()
                if player:IsValid() and player.components.sanity and player.components.locomotor then
                    local sanity_percent = player.components.sanity:GetPercent()
                    local speed_mult = 0.5 + sanity_percent * 0.5
                    player.components.locomotor:SetExternalSpeedMultiplier(player, "shadow_speed", speed_mult)
                end
            end)
            
            return function()
                if shadow_task then
                    shadow_task:Cancel()
                end
                if player:IsValid() and player.components.locomotor then
                    player.components.locomotor:RemoveExternalSpeedMultiplier(player, "shadow_speed")
                end
                DebugLog(3, "清理暗影侵蚀效果")
            end
        end
    },
    {
        id = "DEBUFF_083",
        name = "寒冷诅咒",
        description = "你总是感到寒冷，即使在夏天...",
        fn = function(player)
            if player.components.temperature then
                local old_GetTemp = player.components.temperature.GetTemp
                player.components.temperature.GetTemp = function(self)
                    local temp = old_GetTemp(self)
                    return temp - 20
                end
            end
            
            return function()
                if player:IsValid() and player.components.temperature then
                    player.components.temperature.GetTemp = old_GetTemp
                end
                DebugLog(3, "清理寒冷诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_084",
        name = "炎热诅咒",
        description = "你总是感到炎热，即使在冬天...",
        fn = function(player)
            if player.components.temperature then
                local old_GetTemp = player.components.temperature.GetTemp
                player.components.temperature.GetTemp = function(self)
                    local temp = old_GetTemp(self)
                    return temp + 20
                end
            end
            
            return function()
                if player:IsValid() and player.components.temperature then
                    player.components.temperature.GetTemp = old_GetTemp
                end
                DebugLog(3, "清理炎热诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_085",
        name = "饥饿诅咒",
        description = "你的饥饿值下降速度加快...",
        fn = function(player)
            if player.components.hunger then
                local old_rate = player.components.hunger.hungerrate
                player.components.hunger.hungerrate = old_rate * 2
            end
            
            return function()
                if player:IsValid() and player.components.hunger then
                    player.components.hunger.hungerrate = old_rate
                end
                DebugLog(3, "清理饥饿诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_086",
        name = "理智诅咒",
        description = "你的理智值下降速度加快...",
        fn = function(player)
            if player.components.sanity then
                local old_rate = player.components.sanity.dapperness
                player.components.sanity.dapperness = old_rate * 2
            end
            
            return function()
                if player:IsValid() and player.components.sanity then
                    player.components.sanity.dapperness = old_rate
                end
                DebugLog(3, "清理理智诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_087",
        name = "生命诅咒",
        description = "你的生命值恢复速度减慢...",
        fn = function(player)
            if player.components.health then
                local old_rate = player.components.health.regentime
                player.components.health.regentime = old_rate * 2
            end
            
            return function()
                if player:IsValid() and player.components.health then
                    player.components.health.regentime = old_rate
                end
                DebugLog(3, "清理生命诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_088",
        name = "工具诅咒",
        description = "你的工具耐久度下降速度加快...",
        fn = function(player)
            local old_use = ACTIONS.CHOP.fn
            ACTIONS.CHOP.fn = function(act)
                local result = old_use(act)
                if act.doer == player and act.invobject and act.invobject.components.finiteuses then
                    act.invobject.components.finiteuses:Use(2)
                end
                return result
            end
            
            return function()
                ACTIONS.CHOP.fn = old_use
                DebugLog(3, "清理工具诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_089",
        name = "食物诅咒",
        description = "你获得的食物会立即腐烂...",
        fn = function(player)
            local old_give = player.components.inventory.GiveItem
            player.components.inventory.GiveItem = function(self, item, ...)
                if item and item.components.perishable then
                    item.components.perishable:SetPercent(0)
                end
                return old_give(self, item, ...)
            end
            
            return function()
                if player:IsValid() and player.components.inventory then
                    player.components.inventory.GiveItem = old_give
                end
                DebugLog(3, "清理食物诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_090",
        name = "物品诅咒",
        description = "你的物品会随机掉落...",
        fn = function(player)
            local drop_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and player.components.inventory then
                    local items = player.components.inventory:GetItems()
                    if #items > 0 then
                        local item = items[math.random(#items)]
                        if item then
                            player.components.inventory:DropItem(item)
                            if player.components.talker then
                                player.components.talker:Say("我的物品掉了！")
                            end
                        end
                    end
                end
            end)
            
            return function()
                if drop_task then
                    drop_task:Cancel()
                end
                DebugLog(3, "清理物品诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_091",
        name = "天气诅咒",
        description = "你周围总是下雨...",
        fn = function(player)
            local rain_task = player:DoPeriodicTask(1, function()
                if player:IsValid() and _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StartRain()
                end
            end)
            
            return function()
                if rain_task then
                    rain_task:Cancel()
                end
                if _G.TheWorld.components.rain then
                    _G.TheWorld.components.rain:StopRain()
                end
                DebugLog(3, "清理天气诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_092",
        name = "生物诅咒",
        description = "你周围会随机出现敌对生物...",
        fn = function(player)
            local mob_task = player:DoPeriodicTask(60, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local mobs = {"spider", "hound", "tentacle"}
                    local mob = mobs[math.random(#mobs)]
                    local new_mob = SpawnPrefab(mob)
                    if new_mob then
                        local angle = math.random() * 2 * math.pi
                        local distance = math.random(5, 10)
                        local spawn_x = x + math.cos(angle) * distance
                        local spawn_z = z + math.sin(angle) * distance
                        new_mob.Transform:SetPosition(spawn_x, 0, spawn_z)
                        if new_mob.components.combat then
                            new_mob.components.combat:SetTarget(player)
                        end
                    end
                end
            end)
            
            return function()
                if mob_task then
                    mob_task:Cancel()
                end
                DebugLog(3, "清理生物诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_093",
        name = "时间诅咒",
        description = "你周围的时间流速变慢...",
        fn = function(player)
            local time_task = player:DoPeriodicTask(1, function()
                if player:IsValid() and _G.TheWorld then
                    _G.TheWorld:PushEvent("ms_setclocksegs", {day = 8, dusk = 4, night = 4})
                end
            end)
            
            return function()
                if time_task then
                    time_task:Cancel()
                end
                if _G.TheWorld then
                    _G.TheWorld:PushEvent("ms_setclocksegs", {day = 6, dusk = 4, night = 2})
                end
                DebugLog(3, "清理时间诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_094",
        name = "空间诅咒",
        description = "你会随机传送到附近...",
        fn = function(player)
            local teleport_task = player:DoPeriodicTask(30, function()
                if player:IsValid() then
                    local x, y, z = player.Transform:GetWorldPosition()
                    local angle = math.random() * 2 * math.pi
                    local distance = math.random(5, 10)
                    local new_x = x + math.cos(angle) * distance
                    local new_z = z + math.sin(angle) * distance
                    player.Transform:SetPosition(new_x, y, new_z)
                    if player.components.talker then
                        player.components.talker:Say("我被传送了！")
                    end
                end
            end)
            
            return function()
                if teleport_task then
                    teleport_task:Cancel()
                end
                DebugLog(3, "清理空间诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_095",
        name = "视觉诅咒",
        description = "你的视野范围变小...",
        fn = function(player)
            if player.components.playervision then
                player.components.playervision:SetCustomCCTable({day = 0.5, dusk = 0.3, night = 0.1})
            end
            
            return function()
                if player:IsValid() and player.components.playervision then
                    player.components.playervision:SetCustomCCTable(nil)
                end
                DebugLog(3, "清理视觉诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_096",
        name = "声音诅咒",
        description = "你听不到周围的声音...",
        fn = function(player)
            if player.components.playervision then
                player.components.playervision:SetCustomCCTable({day = 0.8, dusk = 0.6, night = 0.4})
            end
            
            return function()
                if player:IsValid() and player.components.playervision then
                    player.components.playervision:SetCustomCCTable(nil)
                end
                DebugLog(3, "清理声音诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_097",
        name = "重力诅咒",
        description = "你总是感觉轻飘飘的...",
        fn = function(player)
            if player.Physics then
                local old_mass = player.Physics:GetMass()
                player.Physics:SetMass(old_mass * 0.5)
            end
            
            return function()
                if player:IsValid() and player.Physics then
                    player.Physics:SetMass(old_mass)
                end
                DebugLog(3, "清理重力诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_098",
        name = "火焰诅咒",
        description = "你总是感觉炎热，容易着火...",
        fn = function(player)
            local fire_task = player:DoPeriodicTask(30, function()
                if player:IsValid() and not player:HasTag("onfire") then
                    if math.random() < 0.1 then
                        player:PushEvent("ignite")
                    end
                end
            end)
            
            return function()
                if fire_task then
                    fire_task:Cancel()
                end
                DebugLog(3, "清理火焰诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_099",
        name = "冰冻诅咒",
        description = "你总是感觉寒冷，容易结冰...",
        fn = function(player)
            local freeze_task = player:DoPeriodicTask(30, function()
                if player:IsValid() and not player:HasTag("frozen") then
                    if math.random() < 0.1 then
                        player:PushEvent("freeze")
                    end
                end
            end)
            
            return function()
                if freeze_task then
                    freeze_task:Cancel()
                end
                DebugLog(3, "清理冰冻诅咒效果")
            end
        end
    },
    {
        id = "DEBUFF_100",
        name = "混乱诅咒",
        description = "你的所有属性都会随机变化...",
        fn = function(player)
            local chaos_task = player:DoPeriodicTask(10, function()
                if player:IsValid() then
                    if player.components.health then
                        player.components.health:DoDelta(math.random(-5, 5))
                    end
                    if player.components.hunger then
                        player.components.hunger:DoDelta(math.random(-5, 5))
                    end
                    if player.components.sanity then
                        player.components.sanity:DoDelta(math.random(-5, 5))
                    end
                    if player.components.temperature then
                        player.components.temperature:DoDelta(math.random(-5, 5))
                    end
                end
            end)
            
            return function()
                if chaos_task then
                    chaos_task:Cancel()
                end
                DebugLog(3, "清理混乱诅咒效果")
            end
        end
    }
}

-- 修改世界日期变化监听
AddPrefabPostInit("world", function(inst)
    if not _G.TheWorld.ismastersim then return end
    
    inst:WatchWorldState("cycles", function()
        local currentday = _G.TheWorld.state.cycles
        
        -- 检查是否是新的一天
        if currentday > lastday then
            -- 如果只跳过了1天或者是相邻的天数，则应用BUFF
            if currentday <= lastday + 2 then
                DebugLog(1, "新的一天开始，应用BUFF")
                
                -- 获取所有在线玩家
                local players = {}
                for _, v in ipairs(AllPlayers) do
                    if v:IsValid() then
                        table.insert(players, v)
                    end
                end
                
                DebugLog(1, "在线玩家数量:", #players, "将选择:", math.min(RANDOM_PLAYERS_COUNT, #players), "名玩家")
                
                -- 确定要选择的玩家数量
                local select_count = math.min(RANDOM_PLAYERS_COUNT, #players)
                if RANDOM_PLAYERS_COUNT >= 12 then
                    select_count = #players
                end
                
                -- 随机选择玩家
                local selected_players = {}
                while #selected_players < select_count and #players > 0 do
                    local index = _G.math.random(#players)
                    table.insert(selected_players, players[index])
                    table.remove(players, index)
                end
                
                -- 给选中的玩家应用BUFF
                for _, player in ipairs(selected_players) do
                    DebugLog(1, "正在给玩家", player.name or "未知", "应用BUFF")
                    SafeApplyBuff(player)
                    
                    -- 通知所有玩家谁获得了每日惊喜
                    if TheNet:GetIsServer() then
                        local message = string.format("玩家 %s 获得了每日惊喜！", player.name or "未知")
                        TheNet:SystemMessage(message)
                    end
                end
            else
                -- 如果跳过了2天以上，只更新记录的天数，不应用BUFF
                DebugLog(1, "检测到跳过多天，跳过BUFF应用")
            end
            
            -- 更新记录的天数
            lastday = currentday
            LAST_SAVE_DAY = currentday
        end
    end)
    
    -- 添加存档加载时的处理
    inst:ListenForEvent("ms_worldsave", function()
        LAST_SAVE_DAY = _G.TheWorld.state.cycles
        DebugLog(3, "保存当前天数:", LAST_SAVE_DAY)
    end)
    
    inst:ListenForEvent("ms_worldload", function()
        local currentday = _G.TheWorld.state.cycles
        if LAST_SAVE_DAY > 0 then
            -- 使用保存的天数来更新lastday
            lastday = LAST_SAVE_DAY
            DebugLog(3, "加载存档，使用保存的天数:", LAST_SAVE_DAY)
        else
            -- 首次加载时初始化
            lastday = currentday
            LAST_SAVE_DAY = currentday
            DebugLog(3, "首次加载，初始化天数:", currentday)
        end
    end)
end)

-- 玩家初始化时的处理
AddPlayerPostInit(function(inst)
    if not _G.TheWorld.ismastersim then return end
    
    inst:DoTaskInTime(1, function()
        if not inst:IsValid() then return end
        
        -- 如果玩家是在当天加入的，且已经有玩家获得了BUFF，则不再给该玩家BUFF
        -- 只有在新的一天开始时才会重新随机选择玩家
    end)

    -- 添加玩家离开处理
    inst:ListenForEvent("ms_playerleft", function()
        if BUFF_CLEANUP[inst] then
            DebugLog(2, "玩家离开，清理BUFF:", inst.name)
            for _, cleanup_fn in ipairs(BUFF_CLEANUP[inst]) do
                pcall(cleanup_fn)
            end
            BUFF_CLEANUP[inst] = nil
        end
    end)
end)
-- mod加载完成提示
DebugLog(1, "mod加载完成", "mod加载完成")