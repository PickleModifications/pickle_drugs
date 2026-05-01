-- cd_easytime bridge
if GetResourceState('cd_easytime') ~= 'started' then return end

function LockPhotoWeather()
    TriggerEvent('cd_easytime:PauseSync', true)
    SetWeatherTypeNowPersist('EXTRASUNNY')
    NetworkOverrideClockTime(12, 0, 0)
end

function RestorePhotoWeather()
    NetworkClearClockTimeOverride()
    TriggerEvent('cd_easytime:PauseSync', false)
end
