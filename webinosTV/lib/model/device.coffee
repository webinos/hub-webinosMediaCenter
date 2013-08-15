_ = require('underscore')

Bacon = require('baconjs')

DeviceStatusService = require('../service/devicestatus.coffee')
MediaContentService = require('../service/mediacontent.coffee')
MediaService = require('../service/media.coffee')

class DeviceManager extends Bacon.EventStream
  constructor: (interval = 60000, timeout = 60000) ->
    devices = {}
    compound = new Bacon.Bus()
    compound.map('.device').onValue (device) ->
      sink? new Bacon.Next(new Changed(device))
    compound.filter('.isUnavailable').map('.device').onValue (device) ->
      return if _.size(device.services()) > 0
      devices[device.address()].discovery.end()
      delete devices[device.address()]
      sink? new Bacon.Next(new Lost(device))
    services = Bacon.once(Date.now()).concat(Bacon.fromPoll(interval, -> Date.now())).flatMap (now) ->
      Bacon.mergeAll(
        DeviceStatusService.findServices(),
        MediaContentService.findServices(),
        MediaService.findServices())
    services.onValue (service) ->
      discovery = devices[service.address()]?.discovery
      if not discovery?
        discovery = new Bacon.Bus()
        device = new Device(service.address(), discovery, timeout)
        devices[service.address()] = {ref: device, discovery: discovery}
        sink? new Bacon.Next(new Found(device))
        compound.plug(device)
      discovery.push(service)
    sink = undefined
    super (newSink) ->
      sink = (event) ->
        reply = newSink event
        unsub() if reply == Bacon.noMore or event.isEnd()
      unsub = ->
        sink = undefined
    @devices = -> devices

class Device extends Bacon.EventStream
  constructor: (address, discovery, timeout) ->
    services = {}
    compound = new Bacon.Bus()
    compound.filter('.isUnbind').map('.service').onValue (service) =>
      delete services[service.id()]
      sink? new Bacon.Next(new Unavailable(this, service))
    discovery.onValue (service) =>
      if services[service.id()]?
        services[service.id()].seen = Date.now()
      else
        services[service.id()] = {ref: service, seen: Date.now()}
        sink? new Bacon.Next(new Available(this, service))
        compound.plug(service)
    discovery.onEnd ->
      unsubPoll()
      sink? new Bacon.End()
    unsubPoll = Bacon.fromPoll(timeout, -> Date.now()).onValue (now) =>
      for id, {ref, seen} of services
        continue if seen >= (now - timeout)
        delete services[id]
        sink? new Bacon.Next(new Unavailable(this, ref))
    sink = undefined
    super (newSink) ->
      sink = (event) ->
        reply = newSink event
        unsub() if reply == Bacon.noMore or event.isEnd()
      unsub = ->
        sink = undefined
    @address = -> address
    @services = -> services
    @devicestatus = -> _.find(services, ({ref}) -> ref instanceof DeviceStatusService)?.ref
    @mediacontent = -> _.find(services, ({ref}) -> ref instanceof MediaContentService)?.ref
    @media = -> _.find(services, ({ref}) -> ref instanceof MediaService)?.ref
    @isSource = -> @mediacontent()?
    @isTarget = -> @media()?

class Event
  constructor: (device) ->
    @device = -> device
  isFound: -> no
  isChanged: -> no
  isLost: -> no
  isAvailable: -> no
  isUnavailable: -> no

class Found extends Event
  isFound: -> yes

class Changed extends Event
  isChanged: -> yes

class Lost extends Event
  isLost: -> yes

class WithService extends Event
  constructor: (device, service) ->
    super(device)
    @service = -> service

class Available extends WithService
  isAvailable: -> yes

class Unavailable extends WithService
  isUnavailable: -> yes

module.exports = DeviceManager