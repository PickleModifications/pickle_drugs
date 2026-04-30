-- qb-weathersync bridge
if GetResourceState('qb-weathersync') ~= 'started' then return end

function LockPhotoWeather()
    TriggerEvent('qb-weathersync:client:DisableSync')
    SetWeatherTypeNowPersist('EXTRASUNNY')
    NetworkOverrideClockTime(12, 0, 0)
end

function RestorePhotoWeather()
    NetworkClearClockTimeOverride()
    TriggerEvent('qb-weathersync:client:EnableSync')
end
