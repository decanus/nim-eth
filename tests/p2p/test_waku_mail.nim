import
  unittest, chronos, tables, sequtils, times,
  eth/[p2p, async_utils], eth/p2p/peer_pool,
  eth/p2p/rlpx_protocols/[waku_protocol, waku_mail],
  ./p2p_test_helper

const
  transmissionTimeout = chronos.milliseconds(100)

proc waitForConnected(node: EthereumNode) {.async.} =
  while node.peerPool.connectedNodes.len == 0:
    await sleepAsync(chronos.milliseconds(1))

procSuite "Waku Mail Client":
  var client = setupTestNode(Waku)
  var simpleServer = setupTestNode(Waku)

  simpleServer.startListening()
  let simpleServerNode = newNode(initENode(simpleServer.keys.pubKey,
    simpleServer.address))
  let clientNode = newNode(initENode(client.keys.pubKey, client.address))
  waitFor client.peerPool.connectToNode(simpleServerNode)
  require:
    waitFor simpleServer.waitForConnected().withTimeout(transmissionTimeout)

  asyncTest "Two peers connected":
    check:
      client.peerPool.connectedNodes.len() == 1
      simpleServer.peerPool.connectedNodes.len() == 1

  asyncTest "Mail Request and Request Complete":
    let
      topic = [byte 0, 0, 0, 0]
      bloom = toBloom(@[topic])
      lower = 0'u32
      upper = epochTime().uint32
      limit = 100'u32
      request = MailRequest(lower: lower, upper: upper, bloom: @bloom,
        limit: limit)

    var symKey: SymKey
    check client.setPeerTrusted(simpleServerNode.id)
    var cursorFut = client.requestMail(simpleServerNode.id, request, symKey, 1)

    # Simple mailserver part
    let peer = simpleServer.peerPool.connectedNodes[clientNode]
    var f = peer.nextMsg(Waku.p2pRequest)
    require await f.withTimeout(transmissionTimeout)
    let response = f.read()
    let decoded = decode(response.envelope.data, symKey = some(symKey))
    require decoded.isSome()

    var rlp = rlpFromBytes(decoded.get().payload.toRange)
    let output = rlp.read(MailRequest)
    check:
      output.lower == lower
      output.upper == upper
      output.bloom == bloom
      output.limit == limit

    var dummy: Hash
    await peer.p2pRequestComplete(dummy, dummy, @[])

    check await cursorFut.withTimeout(transmissionTimeout)

  asyncTest "Mail Send":
    let topic = [byte 0x12, 0x34, 0x56, 0x78]
    let payload = repeat(byte 0, 10)
    var f = newFuture[int]()

    proc handler(msg: ReceivedMessage) =
      check msg.decoded.payload == payload
      f.complete(1)

    let filter = subscribeFilter(client,
      initFilter(topics = @[topic], allowP2P = true), handler)

    check:
      client.setPeerTrusted(simpleServerNode.id)
      # ttl 0 to show that ttl should be ignored
      # TODO: perhaps not the best way to test this, means no PoW calculation
      # may be done, and not sure if that is OK?
      simpleServer.postMessage(ttl = 0, topic = topic, payload = payload,
        targetPeer = some(clientNode.id))

      await f.withTimeout(transmissionTimeout)

      client.unsubscribeFilter(filter)

  asyncTest "Multiple Client Request and Complete":
    var count = 5
    proc customHandler(peer: Peer, envelope: Envelope)=
      var envelopes: seq[Envelope]
      traceAsyncErrors peer.p2pMessage(envelopes)

      var cursor: Bytes
      count = count - 1
      if count == 0:
        cursor = @[]
      else:
        cursor = @[byte count]

      var dummy: Hash
      traceAsyncErrors peer.p2pRequestComplete(dummy, dummy, cursor)

    simpleServer.enableMailServer(customHandler)
    check client.setPeerTrusted(simpleServerNode.id)
    var request: MailRequest
    var symKey: SymKey
    let cursor =
      await client.requestMail(simpleServerNode.id, request, symKey, 5)
    require cursor.isSome()
    check:
      cursor.get().len == 0
      count == 0

    # TODO: Also check for received envelopes.
