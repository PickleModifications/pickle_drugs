fx_version "cerulean"
game "gta5"
author "Pickle Mods"
description "The best player-owned dealership system for FiveM."
version "v1.1.1"

ui_page "nui/index.html"

files {
    "nui/index.html",
    "nui/assets/**/*.*",
    "nui/fonts/**/*.*",
    "vehicle_images/**/*.*",
    "vanilla_stock.sql",
}

shared_scripts {
    "@ox_lib/init.lua",
    "config.lua",
    "config_sv.lua",
    "locales/locale.lua",
    "locales/translations/*.lua",
    "core/shared.lua",
}

client_scripts {
    "bridge/**/**/client.lua",
    "core/client.lua",
    "modules/**/client.lua",
}

server_scripts {
    "@oxmysql/lib/MySQL.lua",
    "bridge/**/**/server.lua",
    "core/server.lua",
    "modules/**/server.lua",
}

lua54 'yes'

escrow_ignore {
    "config.lua",
    "config_sv.lua",
    "core/*.*",
    "bridge/**/**/*.*",
    "bridge/**/*.*",
    "locales/locale.lua",
    "locales/translations/*.lua",
}
