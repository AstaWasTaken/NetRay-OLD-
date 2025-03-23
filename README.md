# NetRay 2.0 - Advanced Roblox Networking Library

## Overview
NetRay is a **powerful, optimized networking library** for Roblox that enhances RemoteEvents and RemoteFunctions with advanced features such as **batched events, event prioritization, automatic compression, and circuit breaker protection**.

## Features
- **Intuitive API** with a design similar to Roblox RemoteEvents
- **Promise-based request/response pattern** for clean and structured networking
- **Typed event support** for Luau
- **Automatic compression** to optimize network performance
- **Circuit breaker protection** against cascading failures
- **Event prioritization** for managing critical network operations
- **Batched events** to reduce network overhead
- **Security enhancements** including server-side verification
- **Network metrics and analytics** for performance monitoring
- **Middleware** 
---

# Getting Started

## Installation
To include NetRay in your project:
1. Copy `NetRay.lua` into your game.
2. Place it in **ReplicatedStorage**.
3. Require the module in your scripts:

```lua
local NetRay = require(game:GetService("ReplicatedStorage").NetRay)
```

---

# Usage

## Server -> Client Communication
### Firing an Event to a Single Client
```lua
NetRay:FireClient("EventName", player, arg1, arg2)
```
### Firing an Event to All Clients
```lua
NetRay:FireAllClients("EventName", arg1, arg2)
```
### Firing an Event to a Group of Clients
```lua
NetRay:FireClients("EventName", {player1, player2}, arg1, arg2)
```
### Example
```lua
NetRay:RegisterEvent("ShowNotification")
NetRay:FireClient("ShowNotification", player, "Hello, World!")
```

---

## Client -> Server Communication
### Sending an Event from Client to Server
```lua
NetRay:FireServer("EventName", arg1, arg2)
```
### Example
```lua
-- Server
NetRay:RegisterEvent("PlayerJumped")
NetRay:RegisterRequestHandler("PlayerJumped", function(player, height)
    print(player.Name .. " jumped " .. height .. " studs!")
end)

-- Client
NetRay:FireServer("PlayerJumped", 10)
```

---

## Request/Response (Advanced Networking)
### Client Requesting Data from Server
```lua
NetRay:RequestFromServer("GetPlayerStats"):andThen(function(data)
    print("Received stats:", data)
end):catch(function(error)
    print("Request failed:", error)
end)
```
### Server Handling the Request
```lua
NetRay:RegisterRequestHandler("GetPlayerStats", function(player)
    return {
        health = 100,
        level = 5
    }
end)
```

---

## Batched Events (Optimizing Network Traffic)
NetRay can **batch multiple events** together to reduce the number of RemoteEvent calls.
### Enabling Batching
```lua
NetRay:RegisterEvent("DamagePlayer", {batchable = true})
NetRay:FireServer("DamagePlayer", player, 10)
```
### How it Works:
- **NetRay automatically batches small, frequent events**.
- **Batches are processed at a set interval** (default **0.2 seconds**).
- **Compression is applied if the batch exceeds a threshold**.

---

## Security Features
### Server-Side Validation
**Preventing Exploits by Verifying Data:**
```lua
NetRay:RegisterSecurityHandler("GiveGold", function(player, amount)
    return amount >= 0 and amount <= 1000
end)
```
### Circuit Breaker Protection
NetRay automatically **disables problematic events** if they repeatedly fail.
```lua
if NetRay:_isCircuitOpen("PlayerJumped") then
    warn("Skipping event due to circuit breaker")
else
    NetRay:FireServer("PlayerJumped", 10)
end
```

---

# Performance Comparison: NetRay vs. Default RemoteEvents
| Feature | Default RemoteEvents | NetRay 2.0 |
|---------|----------------------|------------|
| **Compression** | ❌ No | ✅ Yes (RLE, LZW) |
| **Batching** | ❌ No | ✅ Yes |
| **Event Prioritization** | ❌ No | ✅ Yes (High, Medium, Low) |
| **Request/Response** | ❌ No | ✅ Yes (Promise-based) |
| **Security Handlers** | ❌ No | ✅ Yes (Server-side) |

---

## Screenshots & Comparisons

The screenshots are from testing, firing an event every 0.01 seconds with a payload size of 8 KB payload

Roblox Default

![image](https://github.com/user-attachments/assets/fe7b59f6-153d-400e-83a0-17f56e1519e4)
![image](https://github.com/user-attachments/assets/23602cf2-023f-4347-a86c-7f78611a3bff)

NetRay

![image](https://github.com/user-attachments/assets/aab607b8-d995-4b08-89e7-0e63484198ba)
![image](https://github.com/user-attachments/assets/c728375c-c6c6-4142-8e8f-4874b237c380)


---

# Conclusion
NetRay provides a **more efficient, secure, and scalable** way to handle networking in Roblox games. It is ideal for **reducing lag, securing communications, and optimizing data transfer**.

## Links
- **GitHub:** *https://github.com/AstaWasTaken/NetRay*
- **Roblox:** *https://create.roblox.com/store/asset/73402828830476/NetRay*
