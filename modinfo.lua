name = "每日惊喜"
description = "每天给玩家一个随机的惊喜效果"
author = "凌(Va6gn)"
version = "1.2.5"

-- 游戏兼容性
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false

-- 客户端/服务器兼容性
client_only_mod = false
all_clients_require_mod = true

-- mod图标
icon_atlas = "modicon.xml"
icon = "modicon.tex"

server_filter_tags = {
    "va6gn",
    "daily_surprise",
    "每日惊喜",
    "凌"
}

-- mod配置选项
configuration_options = {
    {
        name = "buff_duration",
        label = "BUFF持续时间",
        hover = "BUFF效果持续多少天",
        options = {
            {description = "半天", data = 0.5},
            {description = "1天", data = 1},
            {description = "2天", data = 2}
        },
        default = 1
    },
    {
        name = "random_players_count",
        label = "随机选择玩家数量",
        options = {
            {description = "1人", data = 1},
            {description = "2人", data = 2},
            {description = "3人", data = 3},
            {description = "4人", data = 4},
            {description = "5人", data = 5},
            {description = "6人", data = 6},
            {description = "7人", data = 7},
            {description = "8人", data = 8},
            {description = "9人", data = 9},
            {description = "10人", data = 10},
            {description = "11人", data = 11},
            {description = "12人", data = 12},
            {description = "所有人", data = 100}
        },
        default = 1
    },
    {
        name = "enable_debuff",
        label = "启用每日惊吓",
        hover = "是否有几率获得负面效果",
        options = {
            {description = "启用", data = true},
            {description = "禁用", data = false}
        },
        default = true
    },
    {
        name = "debuff_chance",
        label = "每日惊吓几率",
        hover = "获得负面效果的几率",
        options = {
            {description = "10%", data = 0.1},
            {description = "20%", data = 0.2},
            {description = "30%", data = 0.3},
            {description = "40%", data = 0.4},
            {description = "50%", data = 0.5},
            {description = "60%", data = 0.6},
            {description = "70%", data = 0.7},
            {description = "80%", data = 0.8},
            {description = "90%", data = 0.9},
            {description = "100%", data = 1}
        },
        default = 0.3
    },
    {
        name = "log_level",
        label = "日志级别",
        hover = "控制服务器消息的显示级别",        
        options = {
            {description = "详细", data = 3},
            {description = "仅重要", data = 2}, 
            {description = "仅警告", data = 1},
            {description = "无日志", data = 0}
        },
        default = 1
    }
}