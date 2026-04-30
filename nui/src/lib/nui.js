// Thin wrappers around the FiveM NUI bridge. `fetchNui` POSTs to a NUI
// callback registered with RegisterNUICallback on the Lua side; `useNuiEvent`
// subscribes to messages sent via SendNUIMessage. Resource name is read from
// GetParentResourceName so the same build works under any folder name.
const RESOURCE_NAME = typeof window !== "undefined" && window.GetParentResourceName
    ? window.GetParentResourceName()
    : "pickle_drugs";
export async function fetchNui(name, data = {}) {
    const res = await fetch(`https://${RESOURCE_NAME}/${name}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(data),
    });
    return (await res.json());
}
import { useEffect } from "react";
export function useNuiEvent(action, handler) {
    useEffect(() => {
        const listener = (event) => {
            if (event.data?.action === action)
                handler(event.data.data);
        };
        window.addEventListener("message", listener);
        return () => window.removeEventListener("message", listener);
    }, [action, handler]);
}
