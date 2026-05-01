-- Fallback weather bridge — used when no managed weather sync is running.
-- Managed bridges (cd_easytime, qb_weathersync, renewed_weathersync) load
-- alphabetically before 'standalone' and set these globals if their resource
-- is running. This file only defines them if none of them did.
if LockPhotoWeather and RestorePhotoWeather then return end

function LockPhotoWeather()
    SetWeatherTypeNowPersist('EXTRASUNNY')
    SetWeatherTypeNow('EXTRASUNNY')
    NetworkOverrideClockTime(12, 0, 0)
end

function RestorePhotoWeather()
    ClearWeatherTypePersist()
    ClearOverrideWeather()
    NetworkClearClockTimeOverride()
end
