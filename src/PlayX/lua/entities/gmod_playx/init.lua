-- PlayX
-- Copyright (c) 2009, 2010 sk89q <http://www.sk89q.com>
-- 
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 2 of the License, or
-- (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
-- 
-- $Id$

AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
resource.AddFile("materials/vgui/entities/gmod_playx.vmt")

include("shared.lua")

ENT.Subscribed = {}
ENT.Media = nil

--- Returns play status.
-- @return
function ENT:HasMedia()
    return self.Media ~= nil
end

--- Subscribes a user to this player. A subscribed user will see the
-- videos and media playing on this player. If there is already
-- something playing, then the newly subscribed user will have the media
-- play for him/her. Calling this function for an already subscribed
-- user will have no ill effects, nor will it restart the media for the
-- user.
-- @param ply
function ENT:Subscribe(ply)
    if not self.Subscribed[ply] then
        self.Subscribed[ply] = true
        
        if self:HasMedia() and self.Media.Resumable then
            -- Need to alert the client to the media
            self:SendBeginMessage(ply)
        end
        
        hook.Call("PlayXSubscribe", false, self, ply)
    end
end

--- Unsubscribes a user from this player. The video/media will stop
-- playing for the user if something is currently playing. This can be
-- safely called for an unsubscribed user.
-- @param ply
function ENT:Unsubscribe(ply)
    if self.Subscribed[ply] then
        self.Subscribed[ply] = nil
        
        if self:HasMedia() then
            -- Need to tell the client to stop playing
            self:SendEndMessage(ply)
        end
        
        hook.Call("PlayXUnsubscribe", false, self, ply)
    end
end

--- Gets a list of subscribers. All returned entities will be valid
-- player entities.
-- @return List of subscribers
function ENT:GetSubscribers()
    local players = {}
    
    for ply, _ in pairs(self.Subscribers) do
        if IsValid(ply) then
            table.insert(players, ply)
        else -- Lost a player?
            self.Subscribers[ply] = nil
        end
    end
    
    return players
end

--- Opens a media file to be played, accepting a provider and/or URI.
-- @param provider Name of provider, leave blank to auto-detect
-- @param uri URI to play
-- @param start Time to start the video at, in seconds
-- @param lowFramerate Force the client side players to play at 1 FPS
-- @param useJW True to allow the use of the JW player, false for otherwise, nil to default true
-- @param noTimeout True to not check the length of the video (for auto-close)
-- @return The result generated by a provider, or nil and the error message
function ENT:OpenMedia(provider, uri, start, lowFramerate, useJW, noTimeout)
    local provider = provider or ""
    local uri = uri or Error("Missing required 'uri' argument")
    local start = start or 0
    local lowFramerate = lowFramerate or false
    local useJW = useJW and PlayX.IsUsingJW() or false
    local noTimeout = noTimeout or false
    
    local result, err = PlayX.ResolveProvider(provider, uri, useJW)
    
    if not result then
        return false, err
    end
    
    self:BeginMedia(result.Handler, result.Arguments, start, result.Resumable,
                    lowFramerate or result.LowFramerate)
    
    self:UpdateMetadata({
        Provider = provider,
    })
    
    if result.MetadataFunc then
        local successFunc = function(data)
            MsgN(Format("PlayX: Received metadata for provider %s", provider)) 
            self:UpdateMetadata(data)
        end
        
        local errorFunc = function(err)
            MsgN(Format("PlayX: Metadata failed for provider %s: %s", provider, err))
        end
        
        result.MetadataFunc(successFunc, errorFunc)
    end
    
    return true
end

--- Stops playing.
function ENT:CloseMedia()
    if self.Media then
        self:EndMedia()
    
        return true
    else
        return false, "Nothing is playing"
    end
end

--- Plays something using a handler. This doesn't go through that
-- provider stuff, since you are providing the handler directly. Note
-- that many of the metadata fields must be manually updated if you
-- decide to call this method directly.
-- @param handler
-- @param arguments
-- @param start
-- @param resumable
-- @param lowFramerate
-- @param length Length of the media in seconds, can be nil
function ENT:BeginMedia(handler, arguments, start, resumable,
                        lowFramerate, length)
    local arguments = arguments or {}
    local start = start or 0
    local resumable = resumable or false
    local lowFramerate = lowFramerate or false
    
    self.Media = {
        Handler = handler,
        Arguments = arguments,
        StartAt = start,
        StartTime = CurTime() - start,
        Resumable = resumable,
        LowFramerate = lowFramerate,
        StopTime = nil,
        -- Filled by metadata functions
        Provider = nil,
        -- Filled by metadata functions from provider
        URL = nil,
        Title = nil,
        Description = nil,
        Length = nil,
        Tags = nil,
        DatePublished = nil,
        DateModified = nil,
        Submitter = nil,
        SubmitterURL = nil,
        SubmitterAvatar = nil,
        NumFaves = nil,
        NumViews = nil,
        NumComments = nil,
        RatingNorm = nil,
        NumRatings = nil,
        Thumbnail = nil,
        Width = nil,
        Height = nil,
        IsLive = nil,
        ViewerCount = nil,
    }
    
    self:UpdateMetadata() -- Trigger Wiremod outputs
    
    hook.Call("PlayXMediaBegin", false, self, self.Media)
    
    if length then
        self:SetMediaLength(length)
    end
    
    self:SendBeginMessage()
    
    -- TODO: Admin timeout
end

--- Stops playing. You probably should be calling ENT:CloseMedia()
function ENT:EndMedia()
    self.Media = nil
    
    self:UpdateMetadata() -- Trigger Wiremod outputs
    
    hook.Call("PlayXMediaEnd", false, self)
    
    self:SendEndMessage()
end

--- Sends the PlayX play message to subscribed clients. This is an
-- internal method and there is little reason to call it manually.
-- Calling this without updating the entity server-side will put the
-- client and server out of sync.
-- @param ply Pass a player to filter the message to just that player
function ENT:SendBeginMessage(ply)
    local filter = nil
    
    if ply then
        filter = ply
    else
        filter = RecipientFilter()
        
        for ply, _ in pairs(self.Subscribed) do
            filter:AddPlayer(ply)
        end
    end
    
    datastream.StreamToClients(filter, "PlayXBegin", {
        Entity = self,
        Handler = self.Media.Handler,
        Arguments = self.Media.Arguments,
        PlayAge = CurTime() - self.Media.StartTime,
        Resumable = self.Media.Resumable,
        LowFramerate = self.Media.LowFramerate,
    })
end

function ENT:SetMediaLength(length)
    -- @TODO: ENT:SetMediaLength()
end

--- Sends the end message to subscribed clients. This is an
-- internal method and there is little reason to call it manually.
-- Calling this without updating the entity server-side will put the
-- client and server out of sync.
-- @param ply Pass a player to filter the message to just that player
function ENT:SendEndMessage(ply)
    local filter = RecipientFilter()
    local filter = nil
    
    if ply then
        filter = ply
    else
        filter = RecipientFilter()
        
        for ply, _ in pairs(self.Subscribed) do
            filter:AddPlayer(ply)
        end
    end
    
    umsg.Start("PlayXEnd", filter)
    umsg.Entity(self)
    umsg.End()
end

--- Updates the current media metadata. This can be called even after the media
-- has begun playing. Calling this when there is no player spawned has
-- no effect or there is no media playing has no effect.
-- @param data Metadata structure
function ENT:UpdateMetadata(data)
    --if not PlayX.PlayerExists() or not PlayX.CurrentMedia then
    --    return
    --end
    --
    --table.Merge(PlayX.CurrentMedia, data)
    --PlayX:GetInstance():SetWireMetadata(PlayX.CurrentMedia)
    --
    --hook.Call("PlayXMetadataReceived", false, self, ent.Media, data)
    
    -- TODO: Length handling, expiration
end

function ENT:Initialize()
    self.Entity:PhysicsInit(SOLID_VPHYSICS)
    self.Entity:SetMoveType(MOVETYPE_VPHYSICS)
    self.Entity:SetSolid(SOLID_VPHYSICS)
    self.Entity:DrawShadow(false)
    
    if WireAddon then
        self.Outputs = Wire_CreateOutputs(self.Entity, {
            "Provider [STRING]",
            "Handler [STRING]",
            "Start",
            "ActualStartTime",
            "Length",
            "URL [STRING]",
            "Title [STRING]",
            "Description [STRING]",
            "Tags [ARRAY]",
            "DatePublished",
            "DateModified",
            "Submitter [STRING]",
            "SubmitterURL [STRING]",
            "SubmitterAvatar [STRING]",
            "Faved",
            "Views",
            "Comments",
            "NormalizedRating",
            "RatingCount",
            "Thumbnail [STRING]",
            "Width",
            "Height",
            "IsLive",
            "ViewerCount",
        })
        
        self:ClearWireOutputs()
    end
    
    for _, ply in pairs(PlayX.GetAutoSubscribers(self)) do
        self:Subscribe(ply)
    end
end

function ENT:SpawnFunction(ply, tr)
    PlayX.SendSpawnDialog(ply)
end

function ENT:ClearWireOutputs()
    if WireAddon then
        Wire_TriggerOutput(self.Entity, "Provider", "")
        Wire_TriggerOutput(self.Entity, "Handler", "")
        Wire_TriggerOutput(self.Entity, "URI", "")
        Wire_TriggerOutput(self.Entity, "Start", -1)
        Wire_TriggerOutput(self.Entity, "ActualStartTime", -1)
        Wire_TriggerOutput(self.Entity, "Length", -1)
        Wire_TriggerOutput(self.Entity, "URL", "")
        Wire_TriggerOutput(self.Entity, "Title", "")
        Wire_TriggerOutput(self.Entity, "Description", "")
        Wire_TriggerOutput(self.Entity, "Tags", {})
        Wire_TriggerOutput(self.Entity, "DatePublished", -1)
        Wire_TriggerOutput(self.Entity, "DateModified", -1)
        Wire_TriggerOutput(self.Entity, "Submitter", "")
        Wire_TriggerOutput(self.Entity, "SubmitterURL", "")
        Wire_TriggerOutput(self.Entity, "SubmitterAvatar", "")
        Wire_TriggerOutput(self.Entity, "Faved", -1)
        Wire_TriggerOutput(self.Entity, "Views", -1)
        Wire_TriggerOutput(self.Entity, "Comments", -1)
        Wire_TriggerOutput(self.Entity, "NormalizedRating", -1)
        Wire_TriggerOutput(self.Entity, "RatingCount", -1)
        Wire_TriggerOutput(self.Entity, "Thumbnail", "")
        Wire_TriggerOutput(self.Entity, "Width", -1)
        Wire_TriggerOutput(self.Entity, "Height", -1)
        Wire_TriggerOutput(self.Entity, "IsLive", -1)
        Wire_TriggerOutput(self.Entity, "ViewerCount", -1)
    end
end

function ENT:SetWireMetadata(data)
    if WireAddon then
        Wire_TriggerOutput(self.Entity, "Provider", data.Provider and data.Provider or "")
        Wire_TriggerOutput(self.Entity, "Handler", data.Handler)
        Wire_TriggerOutput(self.Entity, "URI", data.URI)
        Wire_TriggerOutput(self.Entity, "Start", data.StartAt)
        Wire_TriggerOutput(self.Entity, "ActualStartTime", data.StartTime + data.StartAt)
        Wire_TriggerOutput(self.Entity, "Length", data.Length and data.Length or -1)
        Wire_TriggerOutput(self.Entity, "URL", data.URL and data.URL or "")
        Wire_TriggerOutput(self.Entity, "Title", data.Title and data.Title or "")
        Wire_TriggerOutput(self.Entity, "Description", data.Description and data.Description or "")
        Wire_TriggerOutput(self.Entity, "Tags", data.Tags and data.Tags or {})
        Wire_TriggerOutput(self.Entity, "DatePublished", data.DatePublished and data.DatePublished or -1)
        Wire_TriggerOutput(self.Entity, "DateModified", data.DateModified and data.DateModified or -1)
        Wire_TriggerOutput(self.Entity, "Submitter", data.Submitter and data.Submitter or "")
        Wire_TriggerOutput(self.Entity, "SubmitterURL", data.SubmitterURL and data.SubmitterURL or "")
        Wire_TriggerOutput(self.Entity, "SubmitterAvatar", data.SubmitterAvatar and data.SubmitterAvatar or "")
        Wire_TriggerOutput(self.Entity, "Faved", data.NumFaves and data.NumFaves or -1)
        Wire_TriggerOutput(self.Entity, "Views", data.NumViews and data.NumViews or -1)
        Wire_TriggerOutput(self.Entity, "Comments", data.NumComments and data.NumComments or -1)
        Wire_TriggerOutput(self.Entity, "NormalizedRating", data.RatingNorm and data.RatingNorm or -1)
        Wire_TriggerOutput(self.Entity, "RatingCount", data.NumRatings and data.NumRatings or -1)
        Wire_TriggerOutput(self.Entity, "Thumbnail", data.Thumbnail and data.Thumbnail or "")
        Wire_TriggerOutput(self.Entity, "Width", data.Width and data.Width or -1)
        Wire_TriggerOutput(self.Entity, "Height", data.Height and data.Height or -1)
        Wire_TriggerOutput(self.Entity, "IsLive", data.IsLive and data.IsLive or -1)
        Wire_TriggerOutput(self.Entity, "ViewerCount", data.ViewerCount and data.ViewerCount or -1)
    end
end

local function PlayXEntityDuplicator(ply, model, pos, ang)
    if PlayX.PlayerExists() then
        return nil
    end
    
    if not PlayX.IsPermitted(ply) then
        return nil
    end
    
    local ent = ents.Create("gmod_playx")
    ent:SetModel(model)
    ent:SetPos(pos)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    
    ply:AddCleanup("gmod_playx", ent)

    return ent
end

duplicator.RegisterEntityClass("gmod_playx", PlayXEntityDuplicator, "Model", "Pos", "Ang")