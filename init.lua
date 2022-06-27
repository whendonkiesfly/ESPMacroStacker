-------TODO: BE ABLE TO DISABLE STEPPER



tmr.delay(3000000)
print("starting")

--Output Pins
LED_PIN = 8
DIRECTION_PIN = 2
STEP_PIN = 1
STEPPER_ENABLE_PIN = 3
CAMERA_CAPTURE_PIN = 0


DIRECTION_FORWARD = 0
DIRECTION_BACKWARD = 1


CAPTURE_PIN_ON_TIME_MS = 200

current_direction = 0
current_steps_remaining = 0

current_position = 0
movement_conn = nil  -- Stores connection to client that command movement.




gpio.write(LED_PIN, 1)
gpio.write(DIRECTION_PIN, 0)
gpio.write(STEP_PIN, 0)
gpio.write(STEPPER_ENABLE_PIN, 1)
gpio.write(CAMERA_CAPTURE_PIN, 0)


gpio.mode(LED_PIN, gpio.OUTPUT)
gpio.mode(DIRECTION_PIN, gpio.OUTPUT)
gpio.mode(STEP_PIN, gpio.OUTPUT)
gpio.mode(STEPPER_ENABLE_PIN, gpio.OUTPUT)
gpio.mode(CAMERA_CAPTURE_PIN, gpio.OUTPUT)

--gpio.mode(FRONT_ENDSTOP_PIN, gpio.INPUT)
--gpio.mode(REAR_ENDSTOP_PIN, gpio.INPUT)







--Setup WiFi.
wifi.setmode(wifi.SOFTAP)
wifi.ap.config({
  ssid="MacroStacker"
})











stepper_timer = tmr.create()
if stepper_timer then
  stepper_timer:alarm(10, tmr.ALARM_AUTO, function()

    if current_steps_remaining <= 0 then
      return
    end

    gpio.write(DIRECTION_PIN, current_direction)
    gpio.write(STEP_PIN, 1)
    tmr.delay(1)
    gpio.write(STEP_PIN, 0)



    current_steps_remaining = current_steps_remaining - 1

    if current_direction == DIRECTION_BACKWARD then
      current_position = current_position + 1
    else
      current_position = current_position - 1
    end

    if current_steps_remaining == 0 and movement_conn ~= nil then
      local success, msg = pcall(SendWebsocketMessage, movement_conn, "done")
      if success == false then
        print("error sending done message: "..msg)
      end
    end



  end)
else
  --Something went wrong.
  return
end










function websocketOnRxCallback(conn, message)
  local success, msg = pcall(rxCallback, conn, message)
  if success == false then
    print(msg)
    SendWebsocketMessage(conn, "ERROR: processing error:"..msg)
  end
end

function rxCallback(conn, message)
  print("Got message")
  print(message)

  if current_steps_remaining > 0 then
    return
  end


  msg = sjson.decode(message)

  cmd_success = false
  if msg.cmd == "move" then
    gpio.write(STEPPER_ENABLE_PIN, 1)
    if msg.dist and msg.direction then
      --print("move")
      current_direction = tonumber(msg.direction)
      current_steps_remaining = tonumber(msg.dist)
      movement_conn = conn
      cmd_success = true
    end

  elseif msg.cmd == "snap" then
    gpio.write(CAMERA_CAPTURE_PIN, 1)
    print("camera on")
    cmd_success = true
    tmr.create():alarm(CAPTURE_PIN_ON_TIME_MS, tmr.ALARM_SINGLE, function()
      print("camera off")
      gpio.write(CAMERA_CAPTURE_PIN, 0)
    end)

  elseif msg.cmd == "stepper_off" then
    gpio.write(STEPPER_ENABLE_PIN, 0)
    cmd_success = true

  elseif msg.cmd == "set_home" then
    current_position = 0
    cmd_success = true

  elseif msg.cmd == "go_home" then
    gpio.write(STEPPER_ENABLE_PIN, 1)
    if current_position > 0 then
      current_direction = DIRECTION_FORWARD
    else
      current_direction = DIRECTION_BACKWARD
    end
    current_steps_remaining = math.abs(current_position)
    cmd_success = true
  end

  if cmd_success == false then
    --Error
    SendWebsocketMessage(conn, "ERROR: Invalid command")
  else
    SendWebsocketMessage(conn, "ack")
  end
end

function websocketOnConnectCallback(conn)
	print("Connect")
end

function websocketOnCloseCallback(conn)
	print("Close")
end

local websocketCallbacks = {onConnect=websocketOnConnectCallback, onReceive=websocketOnRxCallback, onClose=websocketOnCloseCallback}
loadfile("WebsocketServer.lua")(websocketCallbacks)
