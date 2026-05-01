-- FiveMerr screenshot bridge
-- https://fivemerr.com
if GetResourceState('fivemerr') ~= 'started' then return end

function CaptureScreenshot(cb)
    exports.fivemerr:requestScreenshot(function(data)
        cb(data)
    end)
end
