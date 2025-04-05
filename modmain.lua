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
    }
}

-- 将新的BUFF添加到原有列表
for _, buff in ipairs(BUFF_LIST) do
    table.insert(BUFF_LIST, buff)
end

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
        name = "随机传送病",
        description = "你会随机传送到世界各地，没有任何征兆！",
        fn = function(player)
            -- 随机传送
            local teleport_task = player:DoPeriodicTask(60, function()
                if player:IsValid() and math.random() < 0.4 then
                    local curr_x, curr_y, curr_z = player.Transform:GetWorldPosition()
                    
                    -- 传送距离
                    local teleport_dist = 30 + math.random() * 30
                    local teleport_angle = math.random() * 2 * PI
                    
                    local new_x = curr_x + teleport_dist * math.cos(teleport_angle)
                    local new_z = curr_z + teleport_dist * math.sin(teleport_angle)
                    
                    -- 传送前特效
                    local fx1 = SpawnPrefab("collapse_small")
                    if fx1 then
                        fx1.Transform:SetPosition(curr_x, curr_y, curr_z)
                    end
                    
                    -- 执行传送
                    player.Physics:Teleport(new_x, 0, new_z)
                    
                    -- 传送后特效
                    local fx2 = SpawnPrefab("collapse_small")
                    if fx2 then
                        fx2.Transform:SetPosition(new_x, 0, new_z)
                    end
                    
                    if player.components.talker then
                        player.components.talker:Say("我怎么又在这里了？！")
                    end
                end
            end)
            
            return function()
                if teleport_task then
                    teleport_task:Cancel()
                end
                DebugLog(3, "清理随机传送病效果")
            end
        end
    }
}

-- 将新的DEBUFF添加到原有列表
for _, debuff in ipairs(DEBUFF_LIST) do
    table.insert(DEBUFF_LIST, debuff)
end

-- 安全地应用BUFF/DEBUFF效果
local function SafeApplyBuff(player)
    if not player or not player.components then return end
    
    -- 先清理已有效果
    if BUFF_CLEANUP[player] then
        DebugLog(2, "清理玩家之前的BUFF效果:", player.name)
        for _, cleanup_fn in ipairs(BUFF_CLEANUP[player]) do
            pcall(cleanup_fn)
        end
        BUFF_CLEANUP[player] = nil
    end

    -- 根据配置决定是否有几率应用DEBUFF
    local buff_list = BUFF_LIST
    local effect_type = "惊喜"
    
    if ENABLE_DEBUFF and _G.math.random() < DEBUFF_CHANCE then
        buff_list = DEBUFF_LIST
        effect_type = "惊吓"
    end
    
    local buff = buff_list[_G.math.random(#buff_list)]
    if buff and buff.fn then
        local cleanup_actions = {}
        local success, error_msg = pcall(function()
            -- 应用效果并获取清理函数
            local cleanup = buff.fn(player)
            if cleanup then
                table.insert(cleanup_actions, cleanup)
                -- 设置定时器在BUFF持续时间结束后自动清理
                player:DoTaskInTime(BUFF_DURATION * TUNING.TOTAL_DAY_TIME, function()
                    if cleanup_actions[1] then
                        pcall(cleanup_actions[1])
                        BUFF_CLEANUP[player] = nil
                    end
                end)
            end
        end)
        
        if success then
            BUFF_CLEANUP[player] = cleanup_actions
            DebugLog(1, "成功应用" .. effect_type .. ":", buff.name)
            if player.components.talker then
                player.components.talker:Say("获得每日" .. effect_type .. ": " .. buff.name)
                -- 延迟一秒显示描述
                player:DoTaskInTime(1, function()
                    if player.components.talker then
                        player.components.talker:Say(buff.description)
                    end
                end)
            end
            -- 向所有玩家发送系统消息
            if TheNet:GetIsServer() then
                TheNet:SystemMessage(string.format("玩家 %s 获得了每日%s：%s", 
                    player.name or "未知", 
                    effect_type,
                    buff.name))
                if buff.description then
                    TheNet:SystemMessage(buff.description)
                end
            end
        else
            DebugLog(1, "应用" .. effect_type .. "失败:", buff.name, error_msg)
        end
    end
end

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