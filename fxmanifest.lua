fx_version "cerulean"
game "gta5"
author "Pickle Mods"
description "Player-grown drug cultivation system for FiveM."
version "v0.1.0"

shared_scripts {
    "@ox_lib/init.lua",
    "config.lua",
    "core/shared.lua",
    "modules/**/shared.lua",
}

client_scripts {
    "bridge/**/client.lua",
    "core/client.lua",
    "modules/plant_creator/gizmo.lua",
    "modules/**/client.lua",
}

server_scripts {
    "@oxmysql/lib/MySQL.lua",
    "bridge/**/server.lua",
    "core/server.lua",
    "modules/**/server.lua",
}

ui_page "nui/dist/index.html"

files {
    "stream/weed/pickle_weed.ytyp",
    "nui/dist/index.html",
    "nui/dist/assets/*.js",
    "nui/dist/assets/*.css",
}

data_file "DLC_ITYP_REQUEST" "stream/weed/pickle_weed.ytyp"

lua54 'yes'

escrow_ignore {
    "config.lua",
    "config_sv.lua",
    "core/*.*",
    "bridge/**/*.*",
    "modules/**/*.*",
    "nui/**/*.*",
}
