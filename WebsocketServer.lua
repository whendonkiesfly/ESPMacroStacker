--TODO: Note that this does not currently handle websocket closing correctly. There is a todo below for this.
--TODO: Remove long running file handles. This should allow for multiple file transmissions at once and allow for other processes to open files.
--Note that the onConnect and onClose should not send messages. onConnect can queue up a message for later (I think).

local websocketCallbacks, connTimeout, restrictedFiles, fileTXBufferSize, contentTypeLookup = ...

if websocketCallbacks == nil then
	--No callbacks by default. Callback options are "onConnect", "onReceive", and "onClose".
	websocketCallbacks = {}
end

if fileTXBufferSize == nil then
	--Defines the maximum number of bytes transmitted at a time.
	fileTXBufferSize = 1024
end

if connTimeout == nil then
	--Defines the number of seconds before a connection with no trafic gets disconnected.
	connTimeout = 60
end

--Set up restricted files excluding .lua and .lc files. Those are already restricted.
if restrictedFiles == nil then
	restrictedFiles = {}
end

if contentTypeLookup == nil then
	contentTypeLookup =	{	css = "text/css",
							ico = "image/x-icon",
							html = "text/html; charset=utf-8",
							js = "application/javascript"
						}
end


--FIFO list for sending files.
local filesToSend = {}

--Stores handles to websocket connections.
websocketHandles = {}


function SendWebsocketMessage(conn, message)
	if #message <= 125 then
		message = string.char(129) .. string.char(#message) .. message
	else
		--Assume the return text is not longer than 65535 as we don't have that much memory.
		message = string.char(129) .. string.char(126) .. string.char(bit.band(bit.rshift(#message, 8), 0xFF)) .. string.char(bit.band(#message, 0xFF)) .. message
	end

	conn:send(message)
end






--Set up the server
local srv = net.createServer(net.TCP, connTimeout)

srv:listen(80, function(conn)
	conn:on("receive", function(conn, payload)
		--First see if this is a websocket.
		local i, v
		for i, v in pairs(websocketHandles) do
			if conn == v then
				--This connection is a websocket.
				--We need to decode the message.
				if #payload < 3 then
					return --Invalid payload.
				end

				local opcode = bit.band(string.byte(payload:sub(1,1)), 0xf)
				if opcode == 0x8 then
					--Close control frame
					-----------------------------------TODO: NEED TO SEND CLOSE RESPONSE!
					return
				elseif opcode == 0x1 then
					--Text frame
					--Start by decoding the length of the message.
					local length = bit.band(string.byte(payload:sub(2, 2)), 0x7F)
					local messageStart = 7
					if length == 126 then
						length = bit.bor(string.byte(payload:sub(2, 2)), bit.lshift(string.byte(payload:sub(3, 3)), 8))
						messageStart = 9
					elseif length == 127 then
						--We cannot support messages with lengths longer than two bytes, so we won't try.
						return
					end

					if #payload < length+3 then
						return --Invalid payload.
					end

					local mask = {}
					payload:sub(3, 6):gsub(".", function(c) table.insert(mask, c:byte()) end)
					local counter = 0
					payload = string.gsub(payload:sub(messageStart, length+messageStart-1), ".", function(c) counter = counter+1; return string.char(bit.bxor(c:byte(), mask[((counter-1)%4)+1])) end)
					messageStart = nil
					length = nil

					if websocketCallbacks["onReceive"] then
						websocketCallbacks["onReceive"](conn, payload)
					end

					--Return without handling it as a HTTP request.
					return
				else
					--We got an opcode we don't recognize or cannot handle.
					return
				end
			end
		end

		--Set these up in case we somehow forget to set them later.
		local responsePairs = {}
		responsePairs["Content-Type"] = "text/html"
		responsePairs["Connection"] = "close"

		local responseStatus
		local responsePayload

		local responseIsFile = false

		local requestPath
		local responseSuccess = false
		if payload ~= nil then
			local requestLine = string.match(payload, "^([^\n\r]*)")
			if requestLine ~= nil then
				local requestType = string.match(requestLine, "^([^ ]*)")
				if requestType ~= nil then
					requestPath = string.match(requestLine, requestType .. " /([^? ]*)[^ ]- HTTP/1%.1")
					requestLine = nil
					--Convert root path to index.html
					if requestPath == "" then
						--Need to send index.html.
						requestPath = "index.html"
					end

					if requestPath ~= nil then
						--If we got here, we were able to parse everything just fine.
						--See if the file exists by getting the file size
						local fileSize = file.list()[requestPath]
						if fileSize ~= nil and restrictedFiles[requestPath] == nil and requestType == "GET" then
							--See if this is a websocket request
							local websocketKey = string.match(payload, "Sec%-WebSocket%-Key: (.-)\r\n")
							payload = nil
							if websocketKey then
								--This is a websocket request
								responsePairs["Upgrade"] = "websocket"
								responsePairs["Connection"] = "Upgrade"
								responsePairs["Sec-WebSocket-Accept"] = encoder.toBase64(crypto.hash("sha1", websocketKey .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
								responseStatus = "101 Switching Protocols"
								responsePayload = ""
								table.insert(websocketHandles, conn)

								--Call the onConnect callback if it exists.
								if websocketCallbacks["onConnect"] then
									websocketCallbacks["onConnect"](conn)
								end

								responseSuccess = true

							else
								--This is a standard get request
								--We just need to send the file that requestPath points to.
								responsePairs["Content-Length"] = fileSize
								responseStatus = 200
								responsePayload = ""

								local potentialContentType = contentTypeLookup[string.match(requestPath, ".*%.(.-)$")]
								if potentialContentType ~= nil then
									--If we don't have this file type in our lookup table, try text/html.
									responsePairs["Content-Type"] = potentialContentType
								end
								responseIsFile = true
								responseSuccess = true
							end
						end
					end
				end
			end
		end

		if responseSuccess == false then
			--Something went wrong. It would be nice to give more detailed response codes, but we don't have much memory.
			responseStatus = "404 Not Found"
			responsePayload = responseStatus
		end

		if responsePairs["Content-Length"] == nil then
			responsePairs["Content-Length"] = #responsePayload
		end

		local transmitString = "HTTP/1.1 " .. responseStatus .. "\r\n"
		for k, v in pairs(responsePairs) do
			transmitString = transmitString .. k .. ": " .. v .. "\r\n"
		end
		transmitString = transmitString .. "\r\n" .. responsePayload

		--We will send immediatly if we are not sending a file, or we are sending a file and we are not already busy sending a file.
		local futureFileTransfer = {}
		if (responseIsFile == false or (responseIsFile == true and filesToSend[1] == nil)) then
			--If we are starting to send a file, note that.
			if responseIsFile == true then
				futureFileTransfer["conn"] = conn
				futureFileTransfer["filename"] = requestPath
				table.insert(filesToSend, futureFileTransfer)
			end
			--Send response
			conn:send(transmitString)
		else
			--We need to send a file, and one is already being sent. We need to store this for later.
			futureFileTransfer["filename"] = requestPath
			futureFileTransfer["header"] = transmitString
			futureFileTransfer["conn"] = conn
			table.insert(filesToSend, futureFileTransfer)
		end
	end)



	conn:on("sent", function(conn, payload)
		if filesToSend[1] then
			--We are sending a file
			if filesToSend[1]["header"] then
				--We need to send the header
				filesToSend[1]["conn"]:send(filesToSend[1]["header"])
				--Get rid of things we wont need in the future
				filesToSend[1]["header"] = nil
				return

			elseif conn == filesToSend[1]["conn"] then
				--We need to send a chunk of the file assuming this is the same connection we started with.
				local transmitFinished = false
				if filesToSend[1]["fileStarted"] == nil then
					--We need to open the file handle
					if not file.open(filesToSend[1]["filename"]) then
						--Something went wrong when opening the file. Just close the handle and pop this from the list.
						--The only way this should be able to happen is if the file was removed after we checked for the
						--file's existance and before starting to send it.
						transmitFinished = true
					else
						filesToSend[1]["fileStarted"] = true
					end
				end

				--We will send a chunk of the file assuming something didn't go wrong earlier
				if transmitFinished == false then
					local fileChunk = file.read(fileTXBufferSize)
					if fileChunk == nil then
						--We finished sending the file.
						transmitFinished = true
					else
						conn:send(fileChunk)
					end
				end

				--If the connection is finished for any reason, close it, close the file
				--handle, and remove the transfer entry from filesToSend.
				if transmitFinished then
					--TODO: Do we need to close connection?
					file.close()
					table.remove(filesToSend, 1)
					if filesToSend[1] then
						--We need to start sending the next thing.
						filesToSend[1]["conn"]:send(filesToSend[1]["header"])
						filesToSend[1]["header"] = nil
					end
				end

				return
			end
		end

		--If we got here, there is nothing else to send on this socket.
		--If it is a websocket, keep the socket open. Otherwise, we need to close it.
		local i, v
		for i, v in pairs(websocketHandles) do
			if conn == v then
				--This connection is a websocket. Return without closing the socket.
				return
			end
		end
	end)



	conn:on("disconnection", function(conn)
		local i, v
		--If this is a websocket connection, remove reference to it from the websocketHandles table.
		for i, v in pairs(websocketHandles) do
			if conn == v then
				table.remove(websocketHandles, i)

				--Call the callback.
				if websocketCallbacks["onClose"] then
					websocketCallbacks["onClose"](conn)
				end

				break
			end
		end

		--If we have queued up things to send on this connection, remove them.
		for i, v in pairs(filesToSend) do
			if conn == v["conn"] then
				--We found something queued to be sent on this connection. If we have already opened a file handle for it, close it.
				if i == 1 and v["fileStarted"] then
					file.close()
				end

				--Remove reference to this transmission.
				table.remove(filesToSend, i)
			end
		end
	end)

end)

return srv
