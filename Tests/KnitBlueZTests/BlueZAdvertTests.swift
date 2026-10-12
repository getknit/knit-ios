#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// The advert and the GATT application, as BlueZ reads them back from the radio.
    @Suite(.timeLimit(.minutes(1))) struct BlueZAdvertTests {
        @Test func theAndroidProfileAdvertisesThePayloadAsServiceDataAlone() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let path = try #require(rig.fake.registered.first)
            let properties = try #require(rig.fake.advertisements[path])
            #expect(properties["Type"]?.text == "peripheral")
            #expect(properties["Discoverable"]?.bool == true)
            #expect(properties["ServiceData"]?["FE30"]?.byteArray == LoopRig.ours.bytes)
            #expect(properties["ServiceUUIDs"] == nil)
            #expect(properties["LocalName"] == nil)
            #expect(properties["Includes"] == nil)
            #expect(rig.fake.applicationRoot == nil, "no GATT application")
        }

        @Test func theIOSProfileAdvertisesTheUUIDAndServesThePayloadOverGATT() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            let properties = try #require(rig.fake.registered.first.flatMap { rig.fake.advertisements[$0] })
            #expect(properties["ServiceUUIDs"]?.textArray == ["FE30"])
            #expect(properties["ServiceData"] == nil)
            let application = try #require(rig.fake.application)
            let objects = BlueZ.objects(from: application)
            let characteristic = try #require(objects.first { $0.path.hasSuffix("/char0") })
            let gatt = try #require(characteristic.interfaces.first { $0.name == BlueZ.gattCharacteristic })
            #expect(gatt.properties["UUID"]?.text == AdvertPayload.characteristicUUID)
            #expect(gatt.properties["Flags"]?.textArray == ["read"])
            let service = try #require(objects.first { $0.path.hasSuffix("/service0") }?.interfaces.first)
            #expect(service.properties["UUID"]?.text == AdvertPayload.serviceUUID)
            #expect(service.properties["Primary"]?.bool == true)
        }

        @Test func aRotatingAdvertIsRegisteredAfreshOnItsDeadlineAndTheOldOneWithdrawn() throws {
            let rig = try LoopRig(profile: .ios, rotateAdvert: 50)
            rig.startAdvertising()
            let first = try #require(rig.fake.registered.first)
            let registrations = { rig.fake.calls.filter { $0 == "\(BlueZ.advertisingManager).RegisterAdvertisement" }.count }
            rig.settle("never registered afresh") { registrations() >= 3 }
            rig.settle("the old advert was never withdrawn") { rig.fake.registered.count == 1 }
            #expect(rig.fake.registered != [first], "each registration is a new instance")
            #expect(rig.log.all.contains { $0.contains("registered afresh in 50 ms") })
        }

        /// BlueZ keeps the advert and the application through a power cycle, so going down withdraws them. Forgotten
        /// instead, each power-on registered more, until the application answered AlreadyExists and the fourth
        /// advert was refused (2026-10-12).
        @Test func aPowerCycleWithdrawsWhatWasRegisteredAndRegistersItOnceAgain() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            for cycle in 1...5 {
                try rig.fake.setPowered(false)
                rig.settle("cycle \(cycle): never withdrawn") { rig.fake.registered.isEmpty && rig.fake.applicationRoot == nil }
                try rig.fake.setPowered(true)
                rig.settle("cycle \(cycle): never back on") {
                    rig.events.filter { $0 == .listening(psm: UnixSockets.psm) }.count == cycle + 1
                }
                rig.post(.advertise(LoopRig.ours))
                rig.settle("cycle \(cycle): never advertised again") { rig.fake.registered.count == 1 && rig.fake.applicationRoot != nil }
            }
            #expect(!rig.log.all.contains { $0.contains("failed") }, "nothing refused: \(rig.log.all.filter { $0.contains("failed") })")
        }

        @Test func anAdvertIsRegisteredOnceUnlessItRotates() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            rig.turn(100)
            #expect(rig.fake.calls.filter { $0 == "\(BlueZ.advertisingManager).RegisterAdvertisement" }.count == 1)
        }

        @Test func withoutThePayloadTheServiceHoldsTheDoorbellAlone() throws {
            let rig = try LoopRig(profile: .ios, servesGattPayload: false)
            rig.startAdvertising()
            let properties = try #require(rig.fake.registered.first.flatMap { rig.fake.advertisements[$0] })
            #expect(properties["ServiceUUIDs"]?.textArray == ["FE30"], "the advert is unchanged")
            let application = try #require(rig.fake.application)
            let uuids = BlueZ.objects(from: application).flatMap(\.interfaces).compactMap { $0.properties["UUID"]?.text }
            #expect(uuids == [AdvertPayload.serviceUUID, AdvertPayload.doorbellUUID])
            try rig.fake.read(characteristic: rig.loop.application.characteristicPath)
            rig.settle { rig.fake.readResult != nil }
            #expect(throws: (any Error).self, "nothing answers at the payload's path") { try rig.fake.readResult?.get() }
        }

        @Test func theCharacteristicServesTheValueFromTheOffsetAsked() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            let path = rig.loop.application.characteristicPath
            try rig.fake.read(characteristic: path)
            rig.settle { rig.fake.readResult != nil }
            #expect(try rig.fake.readResult?.get() == LoopRig.ours.gattValue)
            try rig.fake.read(characteristic: path, offset: 22)
            rig.settle { rig.fake.readResult != nil }
            #expect(try rig.fake.readResult?.get() == Array(LoopRig.ours.gattValue.suffix(2)))
            try rig.fake.read(characteristic: path, offset: 25)
            rig.settle { rig.fake.readResult != nil }
            #expect(throws: BusError.remote(name: "org.bluez.Error.InvalidOffset", message: "offset past the value")) {
                try rig.fake.readResult?.get()
            }
        }

        @Test func theApplicationAnswersOnlyWhatItHas() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            var answers: [Result<BusMessage, BusError>] = []
            let gatt = rig.loop.application
            try rig.fake.call(gatt.root, interface: BlueZ.properties, member: "GetAll", [.string("x.y")]) { answers.append($0) }
            try rig.fake.call(gatt.characteristicPath, interface: BlueZ.gattCharacteristic, member: "WriteValue") { answers.append($0) }
            rig.settle { answers.count == 2 }
            for answer in answers {
                guard case .failure(.remote(let name, _)) = answer else {
                    Issue.record("expected an error, got \(answer)")
                    continue
                }
                #expect(name == "org.freedesktop.DBus.Error.UnknownMethod")
            }
        }

        @Test func aNewPayloadIsRegisteredBeforeTheOldOneIsWithdrawn() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let first = try #require(rig.fake.registered.first)
            var changed = LoopRig.ours
            changed.digestCue = 99
            rig.post(.advertise(changed))
            rig.settle { rig.fake.registered.count == 1 && rig.fake.registered.first != first }
            let second = try #require(rig.fake.registered.first)
            #expect(rig.fake.advertisements[second]?["ServiceData"]?["FE30"]?.byteArray == changed.bytes)
            let register = try #require(rig.fake.calls.lastIndex(of: "org.bluez.LEAdvertisingManager1.RegisterAdvertisement"))
            let withdraw = try #require(rig.fake.calls.lastIndex(of: "org.bluez.LEAdvertisingManager1.UnregisterAdvertisement"))
            #expect(register < withdraw, "make before break")
        }

        @Test func theSamePayloadAgainRegistersNothing() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            rig.post(.advertise(LoopRig.ours))
            rig.turn()
            #expect(rig.fake.calls.filter { $0.hasSuffix("RegisterAdvertisement") }.count == 1)
        }

        @Test func aNewCueMovesNothingInTheIOSProfileButANewPSMDoes() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            let first = try #require(rig.fake.registered.first)
            var changed = LoopRig.ours
            changed.digestCue = 99
            rig.post(.advertise(changed))
            rig.turn()
            #expect(rig.fake.calls.filter { $0.hasSuffix("RegisterAdvertisement") }.count == 1, "the GATT value zeroes the cue")
            changed.psm += 1
            rig.post(.advertise(changed))
            rig.settle { rig.fake.registered.count == 1 && rig.fake.registered.first != first }
            try rig.fake.read(characteristic: rig.loop.application.characteristicPath)
            rig.settle { rig.fake.readResult != nil }
            #expect(try rig.fake.readResult?.get() == changed.gattValue)
        }

        @Test func aPayloadWhileTheRadioIsDownWaitsForTheNextStart() throws {
            let rig = try LoopRig()
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.advertise(LoopRig.ours))
            rig.turn()
            #expect(rig.fake.registered.isEmpty)
        }

        @Test func aPeerDialingUsBringsTheAdvertBack() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let first = try #require(rig.fake.registered.first)
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            rig.settle("the advert never came back") { rig.fake.registered.first.map { $0 != first } ?? false }
            let second = try #require(rig.fake.registered.first)
            #expect(rig.fake.advertisements[second] == rig.fake.advertisements[first], "the same payload, on a fresh instance")
            _ = remote
        }

        @Test func aRefusedRegistrationIsTriedAgain() throws {
            let rig = try LoopRig()
            rig.fake.refuseNextRegistration = true
            rig.start()
            rig.post(.advertise(LoopRig.ours))
            rig.settle("never retried") { rig.fake.registered.count == 1 }
            #expect(rig.fake.calls.filter { $0.hasSuffix(".RegisterAdvertisement") }.count == 2)
        }

        @Test func anAdvertBlueZReleasedIsRegisteredAgain() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let first = try #require(rig.fake.registered.first)
            var released = false
            try rig.fake.call(first, interface: BlueZ.advertisementInterface, member: "Release") { _ in released = true }
            rig.settle { released }
            rig.settle { rig.fake.registered.contains { $0 != first } }
        }

        @Test func theAdvertAnswersPropertiesOneAtATime() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let path = try #require(rig.fake.registered.first)
            var answers: [String: Result<BusMessage, BusError>] = [:]
            let interface = DBusValue.string(BlueZ.advertisementInterface)
            try rig.fake.call(path, interface: BlueZ.properties, member: "Get", [interface, .string("Type")]) { answers["Type"] = $0 }
            try rig.fake.call(path, interface: BlueZ.properties, member: "Get", [interface, .string("Nope")]) { answers["Nope"] = $0 }
            try rig.fake.call(path, interface: BlueZ.properties, member: "GetAll", [.string("org.example.Other")]) { answers["Other"] = $0 }
            try rig.fake.call(path, interface: BlueZ.advertisementInterface, member: "Frobnicate") { answers["Frobnicate"] = $0 }
            rig.settle { answers.count == 4 }
            let type = try #require(try answers["Type"]?.get().arguments().first)
            #expect(type == .variant(.string("peripheral")))
            #expect(throws: BusError.self) { try answers["Nope"]?.get() }
            #expect(throws: BusError.self) { try answers["Other"]?.get() }
            #expect(throws: BusError.self) { try answers["Frobnicate"]?.get() }
        }

        @Test func aWithdrawnAdvertAnswersNothing() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            let path = try #require(rig.fake.registered.first)
            rig.post(.stop)
            rig.settle { rig.fake.registered.isEmpty }
            rig.turn()
            var answer: Result<BusMessage, BusError>?
            try rig.fake.call(path, interface: BlueZ.properties, member: "GetAll", [.string(BlueZ.advertisementInterface)]) { answer = $0 }
            rig.settle { answer != nil }
            #expect(throws: BusError.self) { try answer?.get() }
        }
    }
#endif
