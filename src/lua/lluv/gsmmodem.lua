local at    = require "lluv.gsmmodem.at"
local utils = require "lluv.gsmmodem.utils"
local Error = require "lluv.gsmmodem.error".error
local uv    = require "lluv"
local ut    = require "lluv.utils"
local tpdu  = require "tpdu"
local date  = require "date"
uv.rs232    = require "lluv.rs232"

local pack_args = utils.pack_args
local ts2date   = utils.ts2date
local date2ts   = utils.date2ts

local DEFAULT_COMMAND_TIMEOUT = 60000
local DEFAULT_COMMAND_DELAY   = 200

---------------------------------------------------------------
local GsmModem = ut.class() do

local URC_TYPS = {
  [ '+CMT'  ] = 'on_recv_sms';
  [ '+CMTI' ] = 'on_save_sms';
  [ '+CDS'  ] = 'on_recv_status';
  [ '+CDSI' ] = 'on_save_status';
  [ '+CLIP' ] = 'on_call';
}
local URC_TYPS_INVERT = {}
for k, v in pairs(URC_TYPS) do URC_TYPS_INVERT[v] = k end

function GsmModem:__init(...)
  local device
  if type(...) == 'string' then
    device  = uv.rs232(...)
  else
    device = ...
  end

  local stream  = at.Stream(self)
  local command = at.Commander(stream)

  -- Время для ответо от модема
  local cmdTimeout = uv.timer():start(0, DEFAULT_COMMAND_TIMEOUT, function(timer)
    stream:_command_done('TIMEOUT')
  end):stop()

  -- Посылать команды не чаще чем ...
  -- Некоторые модемы могут вести себя неадекватно если посылать команды слишком быстро
  local cmdSendTimer = uv.timer():start(0, DEFAULT_COMMAND_DELAY, function(timer)
    timer:stop()
    stream:next_command()
  end):stop()

  stream:on_command(function(self, cmd, timeout)
    device:write(cmd)
    cmdTimeout:again(timeout or DEFAULT_COMMAND_TIMEOUT)
  end)

  -- Stop timeout timer
  stream:on_done(function() cmdTimeout:stop() end)

  -- Wait before send out command
  stream:on_delay(function() cmdSendTimer:again() end)

  self._device    = device
  self._stream    = stream
  self._command   = command
  self._cmd_timer = cmdTimeout
  self._snd_timer = cmdSendTimer
  self._urc       = {}
  self._reference = 0

  stream:on_message(function(this, typ, msg, info)
    local fn = self._urc['*']
    if fn then fn(this, typ, msg, info) end

    fn = self._urc[typ]
    if fn then fn(this, at.DecodeUrc(typ, msg, info)) end
  end)

  return self
end

function GsmModem:cmd()
  return self._command
end

function GsmModem:configure(cb)
  local command = self:cmd()
  local chain

  local function next_fn()
    local f = table.remove(chain, 1)
    if f then return f() end
    cb(self)
  end

  chain = {
    function() command:raw("\26", function(this, err, data)
      next_fn()
    end) end;

    function() command:ATZ(function(this, err, data)
      if err then return cb(this, err, 'ATZ', data) end
      next_fn()
    end) end;

    function() command:ErrorMode(1, function(this, err, data)
      if err then return cb(this, err, 'ErrorMode', data) end
      next_fn()
    end) end;

    function() command:CMGF(0, function(this, err, data)
      if err then return cb(this, err, 'CMGF', data) end
      next_fn()
    end) end;

    function() command:CNMI(2, 2, nil, 1, nil, function(this, err, data)
      if err then return cb(this, err, 'CNMI', data) end
      next_fn()
    end) end;

    function() command:CLIP(1, function(this, err, data)
      if err then return cb(this, err, 'CLIP', data) end
      next_fn()
    end) end;

    function() command:at('+CSCS="IRA"', function(this, err, data)
      if err then return cb(this, err, 'CSCS', data) end
      next_fn()
    end) end;
  }

  next_fn()

  return self
end

function GsmModem:open(cb)
  return self._device:open(function(dev, err, ...)
    if not err then
      self._device:start_read(function(dev, err, data)
        if err then
          return print('Read from port fail:', err, data)
        end

        if data:sub(-1) == '\255' then
          self._stream:reset('REBOOT')
          self._cmd_timer:stop()
          self._snd_timer:stop()

          if self._on_boot then
            self:_on_boot()
          end

          return
        end

        self._stream:append(data)
        self._stream:execute()
      end)
    end
    return cb(self, err, ...)
  end)
end

function GsmModem:close(cb)
  if self._device then
    self._stream:reset()
    self._cmd_timer:close()
    self._snd_timer:close()
    self._device:close(cb)
    self._device = nil
  end
end

function GsmModem:set_delay(ms)
  ms = ms or DEFAULT_COMMAND_DELAY
  if ms <= 1 then ms = 1 end
  self._snd_timer:set_repeat(ms)
  return self
end

function GsmModem:on_boot(handler)
  self._on_boot = handler
end

function GsmModem:on_urc(handler)
  self._urc['*'] = handler
  return self
end

function GsmModem:on_recv_sms(handler)
  local typ = URC_TYPS_INVERT['on_recv_sms']
  self._urc[typ] = handler
  return self
end

function GsmModem:on_save_sms(handler)
  local typ = URC_TYPS_INVERT['on_save_sms']
  self._urc[typ] = handler
  return self
end

function GsmModem:on_sms(handler)
  return self
    :on_recv_sms(handler)
    :on_save_sms(handler)
end

function GsmModem:on_recv_status(handler)
  local typ = URC_TYPS_INVERT['on_recv_status']
  self._urc[typ] = handler
  return self
end

function GsmModem:on_save_status(handler)
  local typ = URC_TYPS_INVERT['on_save_status']
  self._urc[typ] = handler
  return self
end

function GsmModem:on_status(handler)
  return self
    :on_recv_status(handler)
    :on_save_status(handler)
end

function GsmModem:on_call(handler)
  local typ = URC_TYPS_INVERT['on_call']
  self._urc[typ] = handler
  return true
end

function GsmModem:next_reference()
  self._reference = (self._reference + 1) % 0xFFFF
  if self._reference == 0 then self._reference = 1 end
  return self._reference
end

function GsmModem:send_sms(...)
  local cb, number, text, opt = pack_args(...)
  text = text or ''
  local pdus = utils.EncodeSmsSubmit(number, text, {
    reference           = self:next_reference();
    requestStatusReport = true;
    validity            = opt and opt.validity;
    smsc                = opt and opt.smsc;
    rejectDuplicates    = opt and opt.rejectDuplicates;
    replayPath          = opt and opt.replayPath;
    flash               = opt and opt.flash;
  })
  local cmd  = self:cmd()

  local count, res, send_err = #pdus

  for i, pdu in ipairs(pdus) do
    cmd:CMGS(pdu[2], pdu[1], function(self, err, ref)
      if #pdus == 1 then
        if err then return cb(self, err) end

        return cb(self, nil, ref)
      end

      if err then send_err = err end
      res = res or {}
      res[i] = err or ref

      count = count - 1
      if count == 0 then
        return cb(self, send_err, res)
      end
    end)
  end

  return self
end

function GsmModem:send_ussd(...)
  return self:cmd():CUSD(...)
end

end
---------------------------------------------------------------

local REC_UNREAD    = 0
local REC_READ      = 1
local STORED_UNSENT = 2
local STORED_SENT   = 3

---------------------------------------------------------------
local SMSMessage = ut.class() do

function SMSMessage:__init(address, text, flash)
  self._type   = 'SUBMIT'
  self:set_number(address)
  self:set_text(text)
  self:set_flash(flash)
  return self
end

local function find_udh(udh, ...)
  if not udh then return end

  for i = 1, select('#', ...) do
    local iei = select(i, ...)
    for j = 1, #udh do
      if udh[j].iei == iei then
        return udh[j]
      end
    end
  end
end

function SMSMessage:decode_pdu(pdu, state)
  if type(pdu) == 'string' then
    local err
    pdu, err = tpdu.Decode(pdu,
      (state == REC_UNREAD or state == REC_READ) and 'input' or 'output'
    )
    if not pdu then return nil, err end
  end

  self._smsc              = pdu.sc.number       -- SMS Center
  self._validity          = pdu.vp              -- Validity of SMS messages
  self._reject_duplicates = pdu.tp.rd           -- Whether to reject duplicates
  self._udh               = pdu.udh             -- User Data Header
  self._number            = pdu.addr.number     -- Sender or recipient number
  self._text              = pdu.ud              -- Text for SMS
  self._type              = pdu.tp.mti          -- Type of message
  self._delivery_status   = pdu.status          -- In delivery reports: status
  self._replay_path       = pdu.tp.rp           -- Indicates whether "Reply via same center" is set.
  self._reference         = pdu.mr              -- Message reference.
  if pdu.dcs then
    self._class           = pdu.dcs.class       -- SMS class (0 is flash SMS, 1 is normal one).
    self._codec           = pdu.dcs.codec       -- Type of coding. (pdu.dcs.codec, pdu.dcs.compressed)
  end

  if type(self._validity) == 'table' then
    self._validity = ts2date(self._validity)
  end

  if pdu.dts then
    self._date            = ts2date(pdu.dts)    -- Date and time, when SMS was saved or sent (pdu.dts)
  end

  if pdu.scts then
    self._smsc_date       = ts2date(pdu.scts)    -- Date of SMSC response in DeliveryReport messages (pdu.scts)
  end

  self._memory            = nil                 -- For saved SMS: where exactly it's saved (SIM/phone)
  self._location          = nil                 -- For saved SMS: location of SMS in memory.
  self._state             = nil                 -- Status (read/unread/...) of SMS message.

  local concatUdh = find_udh(pdu.udh, 0x00, 0x80)
  if concatUdh and concatUdh.cnt > 1 then
    self._concat_number    = concatUdh.no
    self._concat_reference = concatUdh.ref
    self._concat_count     = concatUdh.cnt
  end

  return self
end

function SMSMessage:pdu()
  local pdu = {}

  pdu.tp = {
    mti = self._type;
    rd  = self._reject_duplicates;
    rp  = self._replay_path;
  }

  pdu.dcs = {
    class = self._class;
    codec = self._codec;
  }

  if self._smsc then
    pdu.sc = {
      number = self._smsc
    }
  end

  if self._number then
    pdu.addr = {
      number = self._number
    }
  end

  if self._validity then
    local vp = self._validity
    if type(vp) ~= 'number' then
      vp = date2ts(vp)
    end
    pdu.vp = vp
  end

  if self._reference then
    pdu.mr = self._reference % 0xFF
  end

  if self._text then
    pdu.ud = self._text
  end

  return tpdu.Encode(pdu)
end

function SMSMessage:set_memory(mem, loc)
  self._memory   = mem
  self._location = location
  return self
end

function SMSMessage:memory()
  return self._memory, self._location
end

function SMSMessage:set_text(text, encode)
  local codec

  if not encode and utils.IsGsm7Compat(text) then
    text  = utils.EncodeGsm7(text)
    codec = 'BIT7'
  else
    text = utils.EncodeUcs2(text, nil, encode)
    codec = 'UCS2'
  end

  self._text  = text
  self._codec = codec

  return self
end

function SMSMessage:text(encode)
  local text, codec = self._text, self._codec

  if codec == 'BIT7' then
    text  = utils.DecodeGsm7(text, encode)
    codec = encode or 'ASCII'
  elseif codec == 'UCS2' then
    if encode then
      text  = utils.DecodeUcs2(text, encode)
      codec = encode
    end
  end

  return text, codec
end

function SMSMessage:set_number(v)
  self._number = v
  return self
end

function SMSMessage:number()
  return self._number
end

function SMSMessage:set_reject_duplicates(v)
  self._reject_duplicates = not not v
  return self
end

function SMSMessage:reject_duplicates()
  return not not self._reject_duplicates
end

function SMSMessage:set_reference(v)
  self._reference = v
  return self
end

function SMSMessage:reference()
  return self._reference
end

function SMSMessage:delivery_status()
  local state = self._delivery_status
  if not state then return end

  return state.success, state
end

function SMSMessage:flash()
  return self._class == 1
end

function SMSMessage:set_flash(v)
  if v then self._class = 1 else self._class = nil end
  return self
end

end
---------------------------------------------------------------

return {
  new        = GsmModem.new;
  SMSMessage = SMSMessage.new;

  REC_UNREAD    = REC_UNREAD;
  REC_READ      = REC_READ;
  STORED_UNSENT = STORED_UNSENT;
  STORED_SENT   = STORED_SENT;
}